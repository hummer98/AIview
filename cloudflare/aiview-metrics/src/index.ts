/**
 * AIview anonymous usage telemetry API v2.
 *
 * The database stores one row per pseudonymous install UUID. Request bodies,
 * IP addresses, authorization credentials, and install identifiers are never
 * logged by this Worker.
 */

export interface RateLimiter {
  limit(options: { key: string }): Promise<{ success: boolean }>;
}

export interface Env {
  DB: D1Database;
  STATS_KEY: string;
  LEGACY_PING_SUNSET: string;
  PING_IP_RATE_LIMIT: RateLimiter;
  PING_INSTALL_RATE_LIMIT: RateLimiter;
  DELETE_IP_RATE_LIMIT: RateLimiter;
  STATS_IP_RATE_LIMIT: RateLimiter;
  LEGACY_PING_IP_RATE_LIMIT: RateLimiter;
}

interface PingPayload {
  install_id: string;
  app_version: string;
  os_version: string;
  arch: "arm64" | "x86_64";
  locale: string;
}

interface DeletePayload {
  install_id: string;
}

type Clock = () => Date;

const MAX_JSON_BODY_BYTES = 4 * 1024;
const RETENTION_DAYS = 400;
const DAY_MILLISECONDS = 86_400_000;
const JSON_CONTENT_TYPE = "application/json; charset=utf-8";
const NO_STORE_HEADERS: Readonly<Record<string, string>> = {
  "cache-control": "no-store",
  "x-content-type-options": "nosniff",
};

const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const SEMVER = /^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/;
const OS_VERSION = /^(?:0|[1-9]\d{0,2})(?:\.(?:0|[1-9]\d{0,2})){1,2}$/;
const LOCALE = /^[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{2,8}){0,3}$/;

class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    readonly headers: HeadersInit = {},
  ) {
    super(code);
  }
}

class BodyTooLargeError extends Error {}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    return handleRequest(request, env);
  },

  async scheduled(controller: ScheduledController, env: Env): Promise<void> {
    await purgeExpiredInstalls(env.DB, new Date(controller.scheduledTime));
  },
} satisfies ExportedHandler<Env>;

export async function handleRequest(
  request: Request,
  env: Env,
  clock: Clock = () => new Date(),
): Promise<Response> {
  try {
    const url = new URL(request.url);

    switch (url.pathname) {
      case "/v1/ping":
        requireMethod(request, "POST");
        return await handleV2Ping(request, env, clock());
      case "/v1/delete":
        requireMethod(request, "POST");
        return await handleDelete(request, env);
      case "/stats":
        requireMethod(request, "GET");
        return await handleStats(request, env, clock());
      case "/ping":
        requireMethod(request, "GET");
        return await handleLegacyPing(request, url, env, clock());
      case "/":
        requireMethod(request, "GET");
        return jsonResponse({ status: "ok" });
      default:
        throw new ApiError(404, "not_found");
    }
  } catch (error) {
    if (error instanceof ApiError) {
      return errorResponse(error.status, error.code, error.headers);
    }
    return errorResponse(500, "internal_error");
  }
}

async function handleV2Ping(request: Request, env: Env, now: Date): Promise<Response> {
  await enforceRateLimit(
    env.PING_IP_RATE_LIMIT,
    await rateLimitKey("v1-ping-ip", clientIP(request)),
  );

  const payload = validatePingPayload(await readJSONObject(request));

  await enforceRateLimit(
    env.PING_INSTALL_RATE_LIMIT,
    await rateLimitKey("v1-ping-install", payload.install_id),
  );
  await upsertInstall(env.DB, payload, countryCode(request), now);

  return emptyResponse(204);
}

async function handleLegacyPing(
  request: Request,
  url: URL,
  env: Env,
  now: Date,
): Promise<Response> {
  const sunset = parseSunset(env.LEGACY_PING_SUNSET);
  if (now.getTime() >= sunset.getTime()) {
    throw new ApiError(410, "legacy_route_retired");
  }

  await enforceRateLimit(
    env.LEGACY_PING_IP_RATE_LIMIT,
    await rateLimitKey("legacy-ping-ip", clientIP(request)),
  );

  const payload = validatePingPayload({
    install_id: url.searchParams.get("id"),
    app_version: url.searchParams.get("v"),
    os_version: url.searchParams.get("os"),
    arch: url.searchParams.get("arch"),
    locale: url.searchParams.get("lang"),
  });

  await enforceRateLimit(
    env.PING_INSTALL_RATE_LIMIT,
    await rateLimitKey("legacy-ping-install", payload.install_id),
  );
  await upsertInstall(env.DB, payload, countryCode(request), now);

  return emptyResponse(204, {
    deprecation: "true",
    sunset: sunset.toUTCString(),
    link: '</v1/ping>; rel="successor-version"',
  });
}

async function handleDelete(request: Request, env: Env): Promise<Response> {
  await enforceRateLimit(
    env.DELETE_IP_RATE_LIMIT,
    await rateLimitKey("v1-delete-ip", clientIP(request)),
  );

  const payload = validateDeletePayload(await readJSONObject(request));
  await env.DB.prepare("DELETE FROM installs WHERE install_id = ?1").bind(payload.install_id).run();

  // Deleting an absent UUID is intentionally indistinguishable from deleting an
  // existing UUID, making this endpoint idempotent and avoiding an ID oracle.
  return emptyResponse(204);
}

async function handleStats(request: Request, env: Env, now: Date): Promise<Response> {
  await enforceRateLimit(
    env.STATS_IP_RATE_LIMIT,
    await rateLimitKey("stats-ip", clientIP(request)),
  );

  if (!(await hasValidBearerToken(request, env.STATS_KEY))) {
    throw new ApiError(401, "unauthorized", {
      "www-authenticate": 'Bearer realm="aiview-metrics"',
    });
  }

  const today = now.toISOString().slice(0, 10);
  const total =
    (await env.DB.prepare("SELECT count(*) AS c FROM installs").first<{ c: number }>())?.c ?? 0;
  const newToday =
    (
      await env.DB.prepare(
        "SELECT count(*) AS c FROM installs WHERE substr(first_seen, 1, 10) = ?1",
      )
        .bind(today)
        .first<{ c: number }>()
    )?.c ?? 0;

  const [dau, wau, mau] = await Promise.all([
    countActiveSince(env.DB, now, 1),
    countActiveSince(env.DB, now, 7),
    countActiveSince(env.DB, now, 30),
  ]);

  const [byVersion, byOS, byArch, byCountry] = await Promise.all([
    env.DB.prepare(
      "SELECT app_version AS name, count(*) AS count FROM installs GROUP BY app_version ORDER BY count DESC",
    ).all(),
    env.DB.prepare(
      "SELECT os_version AS name, count(*) AS count FROM installs GROUP BY os_version ORDER BY count DESC",
    ).all(),
    env.DB.prepare(
      "SELECT arch AS name, count(*) AS count FROM installs GROUP BY arch ORDER BY count DESC",
    ).all(),
    env.DB.prepare(
      "SELECT country AS name, count(*) AS count FROM installs GROUP BY country ORDER BY count DESC",
    ).all(),
  ]);

  return jsonResponse({
    generated_at: now.toISOString(),
    total_installs: total,
    new_today: newToday,
    active: { dau, wau, mau },
    by_version: byVersion.results,
    by_os: byOS.results,
    by_arch: byArch.results,
    by_country: byCountry.results,
  });
}

async function upsertInstall(
  database: D1Database,
  payload: PingPayload,
  country: string,
  now: Date,
): Promise<void> {
  const timestamp = now.toISOString();
  const day = timestamp.slice(0, 10);

  await database
    .prepare(
      `INSERT INTO installs
         (install_id, first_seen, last_seen, last_day, app_version, os_version, arch, locale, country, active_days)
       VALUES (?1, ?2, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 1)
       ON CONFLICT(install_id) DO UPDATE SET
         last_seen   = ?2,
         app_version = ?4,
         os_version  = ?5,
         arch        = ?6,
         locale      = ?7,
         country     = ?8,
         active_days = active_days + (CASE WHEN last_day <> ?3 THEN 1 ELSE 0 END),
         last_day    = ?3`,
    )
    .bind(
      payload.install_id,
      timestamp,
      day,
      payload.app_version,
      payload.os_version,
      payload.arch,
      payload.locale,
      country,
    )
    .run();
}

async function countActiveSince(
  database: D1Database,
  now: Date,
  days: number,
): Promise<number> {
  const cutoff = new Date(now.getTime() - days * DAY_MILLISECONDS).toISOString();
  const row = await database
    .prepare("SELECT count(*) AS c FROM installs WHERE last_seen >= ?1")
    .bind(cutoff)
    .first<{ c: number }>();
  return row?.c ?? 0;
}

export async function purgeExpiredInstalls(
  database: D1Database,
  now: Date,
): Promise<number> {
  const cutoff = new Date(now.getTime() - RETENTION_DAYS * DAY_MILLISECONDS).toISOString();
  const result = await database
    .prepare("DELETE FROM installs WHERE last_seen < ?1")
    .bind(cutoff)
    .run();
  return result.meta.changes ?? 0;
}

async function readJSONObject(request: Request): Promise<Record<string, unknown>> {
  requireJSONContentType(request);

  const contentLength = request.headers.get("content-length");
  if (contentLength !== null && /^\d+$/.test(contentLength)) {
    const declaredLength = Number(contentLength);
    if (!Number.isSafeInteger(declaredLength) || declaredLength > MAX_JSON_BODY_BYTES) {
      throw new ApiError(413, "body_too_large");
    }
  }

  let bytes: Uint8Array;
  try {
    bytes = await readBoundedBody(request, MAX_JSON_BODY_BYTES);
  } catch (error) {
    if (error instanceof BodyTooLargeError) {
      throw new ApiError(413, "body_too_large");
    }
    throw error;
  }

  if (bytes.byteLength === 0) {
    throw new ApiError(400, "invalid_json");
  }

  let value: unknown;
  try {
    const text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    value = JSON.parse(text);
  } catch {
    throw new ApiError(400, "invalid_json");
  }

  if (!isPlainObject(value)) {
    throw new ApiError(400, "invalid_payload");
  }
  return value;
}

async function readBoundedBody(request: Request, maximumBytes: number): Promise<Uint8Array> {
  if (request.body === null) return new Uint8Array();

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maximumBytes) {
        await reader.cancel("body_too_large");
        throw new BodyTooLargeError();
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }

  const result = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    result.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return result;
}

function validatePingPayload(value: Record<string, unknown>): PingPayload {
  requireExactKeys(value, ["install_id", "app_version", "os_version", "arch", "locale"]);

  const installID = requireString(value.install_id);
  const appVersion = requireString(value.app_version);
  const osVersion = requireString(value.os_version);
  const arch = requireString(value.arch);
  const locale = requireString(value.locale);

  if (!UUID_V4.test(installID)) throw new ApiError(400, "invalid_install_id");
  if (appVersion.length > 64 || !SEMVER.test(appVersion)) {
    throw new ApiError(400, "invalid_app_version");
  }
  if (osVersion.length > 16 || !OS_VERSION.test(osVersion)) {
    throw new ApiError(400, "invalid_os_version");
  }
  if (arch !== "arm64" && arch !== "x86_64") {
    throw new ApiError(400, "invalid_arch");
  }
  if (locale.length > 35 || !LOCALE.test(locale)) {
    throw new ApiError(400, "invalid_locale");
  }

  return {
    install_id: installID,
    app_version: appVersion,
    os_version: osVersion,
    arch,
    locale,
  };
}

function validateDeletePayload(value: Record<string, unknown>): DeletePayload {
  requireExactKeys(value, ["install_id"]);
  const installID = requireString(value.install_id);
  if (!UUID_V4.test(installID)) throw new ApiError(400, "invalid_install_id");
  return { install_id: installID };
}

function requireExactKeys(value: Record<string, unknown>, expected: readonly string[]): void {
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (actual.length !== wanted.length || actual.some((key, index) => key !== wanted[index])) {
    throw new ApiError(400, "invalid_payload");
  }
}

function requireString(value: unknown): string {
  if (typeof value !== "string") throw new ApiError(400, "invalid_payload");
  return value;
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function requireJSONContentType(request: Request): void {
  const contentType = request.headers.get("content-type");
  const mediaType = contentType?.split(";", 1)[0]?.trim().toLowerCase();
  if (mediaType !== "application/json") {
    throw new ApiError(415, "unsupported_media_type");
  }
}

function requireMethod(request: Request, expected: string): void {
  if (request.method !== expected) {
    throw new ApiError(405, "method_not_allowed", { allow: expected });
  }
}

async function enforceRateLimit(limiter: RateLimiter, key: string): Promise<void> {
  const result = await limiter.limit({ key });
  if (!result.success) {
    throw new ApiError(429, "rate_limited", { "retry-after": "60" });
  }
}

export async function rateLimitKey(route: string, actor: string): Promise<string> {
  const bytes = new TextEncoder().encode(`${route}\u0000${actor}`);
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return `${route}:${Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("")}`;
}

async function hasValidBearerToken(request: Request, expectedToken: string): Promise<boolean> {
  const authorization = request.headers.get("authorization");
  const match = authorization?.match(/^Bearer ([^\s]+)$/);
  if (!match || expectedToken.length === 0) return false;

  const encoder = new TextEncoder();
  const [candidateDigest, expectedDigest] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(match[1])),
    crypto.subtle.digest("SHA-256", encoder.encode(expectedToken)),
  ]);
  const subtle = crypto.subtle as SubtleCrypto & {
    timingSafeEqual(a: ArrayBuffer | ArrayBufferView, b: ArrayBuffer | ArrayBufferView): boolean;
  };
  return subtle.timingSafeEqual(candidateDigest, expectedDigest);
}

function clientIP(request: Request): string {
  return request.headers.get("cf-connecting-ip") ?? "unknown";
}

function countryCode(request: Request): string {
  const country = request.headers.get("cf-ipcountry")?.toUpperCase() ?? "";
  return /^[A-Z]{2}$/.test(country) ? country : "";
}

function parseSunset(value: string): Date {
  const sunset = new Date(value);
  if (!Number.isFinite(sunset.getTime())) {
    throw new ApiError(500, "invalid_server_configuration");
  }
  return sunset;
}

function jsonResponse(value: unknown, status = 200, headers: HeadersInit = {}): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: mergeHeaders(headers, { "content-type": JSON_CONTENT_TYPE }),
  });
}

function errorResponse(status: number, code: string, headers: HeadersInit = {}): Response {
  return jsonResponse({ error: code }, status, headers);
}

function emptyResponse(status: number, headers: HeadersInit = {}): Response {
  return new Response(null, { status, headers: mergeHeaders(headers) });
}

function mergeHeaders(...sources: HeadersInit[]): Headers {
  const headers = new Headers(NO_STORE_HEADERS);
  for (const source of sources) {
    const additions = new Headers(source);
    additions.forEach((value, key) => headers.set(key, value));
  }
  return headers;
}
