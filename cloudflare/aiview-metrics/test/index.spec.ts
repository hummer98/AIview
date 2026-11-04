import type { D1Migration } from "@cloudflare/vitest-pool-workers";
import {
  applyD1Migrations,
  createScheduledController,
  env,
  SELF,
} from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import worker, {
  type Env,
  handleRequest,
  purgeExpiredInstalls,
  type RateLimiter,
} from "../src/index";

const INSTALL_ID = "550e8400-e29b-41d4-a716-446655440000";
const OTHER_INSTALL_ID = "90b950a0-1c2d-4f51-9d79-b031df70e2de";
const STATS_KEY = "integration-test-stats-key";
const TEST_NOW = new Date("2026-08-11T12:00:00.000Z");

const validPing = {
  install_id: INSTALL_ID,
  app_version: "0.10.0",
  os_version: "15.6.0",
  arch: "arm64",
  locale: "ja_JP",
};

class RecordingLimiter implements RateLimiter {
  readonly keys: string[] = [];

  constructor(private readonly success = true) {}

  async limit({ key }: { key: string }): Promise<{ success: boolean }> {
    this.keys.push(key);
    return { success: this.success };
  }
}

beforeEach(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS as D1Migration[]);
  await env.DB.prepare("DELETE FROM installs").run();
});

describe("POST /v1/ping", () => {
  it("validates, inserts, and upserts one D1 row per install", async () => {
    const first = await SELF.fetch("https://example.test/v1/ping", {
      method: "POST",
      headers: {
        "content-type": "application/json; charset=utf-8",
        "cf-connecting-ip": "203.0.113.8",
        "cf-ipcountry": "jp",
      },
      body: JSON.stringify(validPing),
    });

    expect(first.status).toBe(204);
    expectNoStoreAndNoCORS(first);

    const second = await SELF.fetch("https://example.test/v1/ping", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ ...validPing, app_version: "0.10.1" }),
    });
    expect(second.status).toBe(204);

    const rows = await env.DB.prepare(
      "SELECT install_id, app_version, country, active_days FROM installs",
    ).all<{
      install_id: string;
      app_version: string;
      country: string;
      active_days: number;
    }>();
    expect(rows.results).toEqual([
      {
        install_id: INSTALL_ID,
        app_version: "0.10.1",
        country: "",
        active_days: 1,
      },
    ]);
  });

  it("increments active_days only when the UTC day changes", async () => {
    const testEnv = createEnv();
    const request = () => pingRequest(validPing);

    expect((await handleRequest(request(), testEnv, () => TEST_NOW)).status).toBe(204);
    expect(
      (
        await handleRequest(
          request(),
          testEnv,
          () => new Date("2026-08-11T23:59:59.000Z"),
        )
      ).status,
    ).toBe(204);
    expect(
      (
        await handleRequest(
          request(),
          testEnv,
          () => new Date("2026-08-12T00:00:00.000Z"),
        )
      ).status,
    ).toBe(204);

    const row = await env.DB.prepare(
      "SELECT active_days, last_day FROM installs WHERE install_id = ?1",
    )
      .bind(INSTALL_ID)
      .first<{ active_days: number; last_day: string }>();
    expect(row).toEqual({ active_days: 2, last_day: "2026-08-12" });
  });

  it("rejects wrong methods, media types, invalid JSON, oversized bodies, and extra fields", async () => {
    const get = await SELF.fetch("https://example.test/v1/ping");
    expect(get.status).toBe(405);
    expect(get.headers.get("allow")).toBe("POST");

    const text = await SELF.fetch("https://example.test/v1/ping", {
      method: "POST",
      headers: { "content-type": "text/plain" },
      body: JSON.stringify(validPing),
    });
    expect(text.status).toBe(415);

    const invalidJSON = await SELF.fetch("https://example.test/v1/ping", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{",
    });
    expect(invalidJSON.status).toBe(400);

    const oversized = await SELF.fetch("https://example.test/v1/ping", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ ...validPing, padding: "x".repeat(4096) }),
    });
    expect(oversized.status).toBe(413);

    const extraField = await SELF.fetch("https://example.test/v1/ping", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ ...validPing, extra: true }),
    });
    expect(extraField.status).toBe(400);

    for (const response of [get, text, invalidJSON, oversized, extraField]) {
      expectNoStoreAndNoCORS(response);
    }
  });

  it("accepts an exactly 4096-byte JSON body", async () => {
    const json = JSON.stringify(validPing);
    const byteLength = new TextEncoder().encode(json).byteLength;
    const exactBody = `${json}${" ".repeat(4096 - byteLength)}`;
    expect(new TextEncoder().encode(exactBody)).toHaveLength(4096);

    const response = await handleRequest(
      new Request("https://example.test/v1/ping", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: exactBody,
      }),
      createEnv(),
      () => TEST_NOW,
    );
    expect(response.status).toBe(204);
    expectNoStoreAndNoCORS(response);
  });

  it("rejects a chunked 4097-byte body without Content-Length", async () => {
    const body = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new Uint8Array(2048).fill(0x20));
        controller.enqueue(new Uint8Array(2049).fill(0x20));
        controller.close();
      },
    });
    const request = new Request("https://example.test/v1/ping", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body,
    });
    expect(request.headers.get("content-length")).toBeNull();

    const response = await handleRequest(request, createEnv(), () => TEST_NOW);
    expect(response.status).toBe(413);
    expectNoStoreAndNoCORS(response);
  });

  it.each([
    ["install_id", "not-a-uuid"],
    ["install_id", "550e8400-e29b-11d4-a716-446655440000"],
    ["app_version", "01.2.3"],
    ["app_version", "1.2.3-01"],
    ["app_version", "unknown"],
    ["os_version", "macOS 15.6"],
    ["arch", "i386"],
    ["locale", "../../private"],
  ])("rejects invalid %s values", async (field, value) => {
    const response = await SELF.fetch("https://example.test/v1/ping", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ ...validPing, [field]: value }),
    });
    expect(response.status).toBe(400);
    expectNoStoreAndNoCORS(response);
  });

  it("accepts SemVer prerelease and build metadata", async () => {
    const response = await handleRequest(
      pingRequest({ ...validPing, app_version: "1.2.3-alpha.1+build.5" }),
      createEnv(),
      () => TEST_NOW,
    );
    expect(response.status).toBe(204);
    expectNoStoreAndNoCORS(response);
  });
});

describe("rate limiting", () => {
  it("uses hashed route+IP and route+install keys and returns a deterministic 429", async () => {
    const ipLimiter = new RecordingLimiter();
    const installLimiter = new RecordingLimiter(false);
    const testEnv = createEnv({
      PING_IP_RATE_LIMIT: ipLimiter,
      PING_INSTALL_RATE_LIMIT: installLimiter,
    });
    const response = await handleRequest(
      pingRequest(validPing, { "cf-connecting-ip": "198.51.100.77" }),
      testEnv,
      () => TEST_NOW,
    );

    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("60");
    expectNoStoreAndNoCORS(response);
    expect(ipLimiter.keys).toHaveLength(1);
    expect(ipLimiter.keys[0]).toMatch(/^v1-ping-ip:[0-9a-f]{64}$/);
    expect(ipLimiter.keys[0]).not.toContain("198.51.100.77");
    expect(installLimiter.keys).toHaveLength(1);
    expect(installLimiter.keys[0]).toMatch(/^v1-ping-install:[0-9a-f]{64}$/);
    expect(installLimiter.keys[0]).not.toContain(INSTALL_ID);
  });

  it.each([
    ["delete", "/v1/delete", "POST", { install_id: INSTALL_ID }, "DELETE_IP_RATE_LIMIT"],
    ["stats", "/stats", "GET", undefined, "STATS_IP_RATE_LIMIT"],
    [
      "legacy",
      `/ping?id=${INSTALL_ID}&v=0.9.0&os=15.6.0&arch=arm64&lang=en_US`,
      "GET",
      undefined,
      "LEGACY_PING_IP_RATE_LIMIT",
    ],
  ] as const)("enforces the %s route limiter", async (_name, path, method, body, binding) => {
    const rejecting = new RecordingLimiter(false);
    const testEnv = createEnv({ [binding]: rejecting });
    const response = await handleRequest(
      new Request(`https://example.test${path}`, {
        method,
        headers: body ? { "content-type": "application/json" } : undefined,
        body: body ? JSON.stringify(body) : undefined,
      }),
      testEnv,
      () => TEST_NOW,
    );
    expect(response.status).toBe(429);
    expect(rejecting.keys).toHaveLength(1);
    expectNoStoreAndNoCORS(response);
  });
});

describe("GET /stats", () => {
  it("requires an Authorization Bearer token and never accepts query authentication", async () => {
    const queryOnly = await SELF.fetch(`https://example.test/stats?key=${STATS_KEY}`);
    expect(queryOnly.status).toBe(401);
    expect(queryOnly.headers.get("www-authenticate")).toContain("Bearer");

    const wrong = await SELF.fetch("https://example.test/stats", {
      headers: { authorization: "Bearer wrong-key" },
    });
    expect(wrong.status).toBe(401);

    const testEnv = createEnv();
    await handleRequest(pingRequest(validPing), testEnv, () => TEST_NOW);
    const authorized = await handleRequest(
      new Request("https://example.test/stats", {
        headers: { authorization: `Bearer ${STATS_KEY}` },
      }),
      testEnv,
      () => TEST_NOW,
    );
    expect(authorized.status).toBe(200);
    expectNoStoreAndNoCORS(authorized);
    await expect(authorized.json()).resolves.toMatchObject({
      total_installs: 1,
      new_today: 1,
      active: { dau: 1, wau: 1, mau: 1 },
    });

    for (const response of [queryOnly, wrong]) expectNoStoreAndNoCORS(response);
  });
});

describe("POST /v1/delete", () => {
  it("deletes by UUID and is idempotent without exposing existence", async () => {
    await SELF.fetch("https://example.test/v1/ping", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(validPing),
    });

    for (let attempt = 0; attempt < 2; attempt += 1) {
      const response = await SELF.fetch("https://example.test/v1/delete", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ install_id: INSTALL_ID }),
      });
      expect(response.status).toBe(204);
      expectNoStoreAndNoCORS(response);
    }

    const count = await env.DB.prepare("SELECT count(*) AS c FROM installs").first<{
      c: number;
    }>();
    expect(count?.c).toBe(0);
  });
});

describe("retention", () => {
  it("removes rows older than 400 days and retains the 399/400-day boundary", async () => {
    await insertAt(INSTALL_ID, daysBefore(TEST_NOW, 401));
    await insertAt(OTHER_INSTALL_ID, daysBefore(TEST_NOW, 400));
    await insertAt("2c0ea828-515d-43b1-a3e8-ae7d63434c6c", daysBefore(TEST_NOW, 399));

    const removed = await purgeExpiredInstalls(env.DB, TEST_NOW);
    expect(removed).toBe(1);

    const remaining = await env.DB.prepare(
      "SELECT install_id FROM installs ORDER BY install_id",
    ).all<{ install_id: string }>();
    expect(remaining.results.map((row) => row.install_id)).toEqual(
      [OTHER_INSTALL_ID, "2c0ea828-515d-43b1-a3e8-ae7d63434c6c"].sort(),
    );
  });

  it("runs retention from the UTC scheduled handler", async () => {
    await insertAt(INSTALL_ID, daysBefore(TEST_NOW, 401));
    const controller = createScheduledController({
      cron: "0 3 * * *",
      scheduledTime: TEST_NOW.getTime(),
    });
    await worker.scheduled(controller, env as unknown as Env);
    const row = await env.DB.prepare("SELECT install_id FROM installs").first();
    expect(row).toBeNull();
  });
});

describe("legacy GET /ping", () => {
  it("keeps the v0.9 query route for the documented window without CORS", async () => {
    const response = await handleRequest(
      new Request(
        `https://example.test/ping?id=${INSTALL_ID}&v=0.9.0&os=15.6.0&arch=x86_64&lang=en_US`,
        { headers: { "cf-ipcountry": "US" } },
      ),
      createEnv(),
      () => TEST_NOW,
    );
    expect(response.status).toBe(204);
    expect(response.headers.get("deprecation")).toBe("true");
    expect(response.headers.get("sunset")).toBe("Mon, 09 Nov 2026 00:00:00 GMT");
    expect(response.headers.get("link")).toContain("/v1/ping");
    expectNoStoreAndNoCORS(response);
  });

  it("retires the route at the configured 90-day sunset", async () => {
    const response = await handleRequest(
      new Request(
        `https://example.test/ping?id=${INSTALL_ID}&v=0.9.0&os=15.6.0&arch=arm64&lang=ja_JP`,
      ),
      createEnv(),
      () => new Date("2026-11-09T00:00:00.000Z"),
    );
    expect(response.status).toBe(410);
    expectNoStoreAndNoCORS(response);
  });
});

describe("response policy", () => {
  it("applies no-store and no wildcard CORS to health, 404, and error responses", async () => {
    const responses = await Promise.all([
      SELF.fetch("https://example.test/"),
      SELF.fetch("https://example.test/not-found"),
      SELF.fetch("https://example.test/v1/delete", { method: "POST" }),
    ]);
    expect(responses.map((response) => response.status)).toEqual([200, 404, 415]);
    for (const response of responses) expectNoStoreAndNoCORS(response);
  });
});

function pingRequest(
  payload: Record<string, unknown>,
  headers: Record<string, string> = {},
): Request {
  return new Request("https://example.test/v1/ping", {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify(payload),
  });
}

function createEnv(overrides: Partial<Env> = {}): Env {
  const allowing = () => new RecordingLimiter();
  return {
    DB: env.DB,
    STATS_KEY,
    LEGACY_PING_SUNSET: "2026-11-09T00:00:00Z",
    PING_IP_RATE_LIMIT: allowing(),
    PING_INSTALL_RATE_LIMIT: allowing(),
    DELETE_IP_RATE_LIMIT: allowing(),
    STATS_IP_RATE_LIMIT: allowing(),
    LEGACY_PING_IP_RATE_LIMIT: allowing(),
    ...overrides,
  };
}

function expectNoStoreAndNoCORS(response: Response): void {
  expect(response.headers.get("cache-control")).toBe("no-store");
  expect(response.headers.get("access-control-allow-origin")).toBeNull();
}

function daysBefore(date: Date, days: number): Date {
  return new Date(date.getTime() - days * 86_400_000);
}

async function insertAt(installID: string, date: Date): Promise<void> {
  const timestamp = date.toISOString();
  await env.DB.prepare(
    `INSERT INTO installs
       (install_id, first_seen, last_seen, last_day, app_version, os_version, arch, locale, country, active_days)
     VALUES (?1, ?2, ?2, ?3, '0.10.0', '15.6.0', 'arm64', 'en_US', 'US', 1)`,
  )
    .bind(installID, timestamp, timestamp.slice(0, 10))
    .run();
}
