/**
 * aiview-metrics — AIview の匿名利用計測エンドポイント（Cloudflare Worker + D1）
 *
 * 設計方針:
 * - 個人情報は一切保存しない。アプリが生成する匿名 install UUID と、
 *   アプリ版 / macOS版 / アーキ / ロケール / 国コード(CFヘッダ) のみ。
 * - install ごとに 1 行だけ保持する（イベントログは持たない）。
 *   → 保存量が最小で、ユニーク install 数・DAU/WAU/MAU・版/OS分布が取れる。
 * - 集計は Worker 自身の /stats（STATS_KEY 保護）が返す。CF ダッシュボード不要。
 *
 * ルート:
 *   GET /ping?id=&v=&os=&arch=&lang=   → install 行を upsert し 204
 *   GET /stats?key=STATS_KEY           → 集計 JSON
 *   GET /                              → ヘルスチェック
 */

export interface Env {
  DB: D1Database;
  STATS_KEY: string;
}

const CORS: Record<string, string> = { "access-control-allow-origin": "*" };

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    switch (url.pathname) {
      case "/ping":
        return handlePing(req, url, env);
      case "/stats":
        return handleStats(url, env);
      case "/":
        return new Response("aiview-metrics ok", { status: 200 });
      default:
        return new Response("not found", { status: 404 });
    }
  },
};

function clamp(value: string | null, max: number): string {
  return (value ?? "").slice(0, max);
}

async function handlePing(req: Request, url: URL, env: Env): Promise<Response> {
  const p = url.searchParams;
  const id = clamp(p.get("id"), 64);
  if (!id) return new Response(null, { status: 400, headers: CORS });

  const appVersion = clamp(p.get("v"), 32);
  const osVersion = clamp(p.get("os"), 32);
  const arch = clamp(p.get("arch"), 16);
  const locale = clamp(p.get("lang"), 16);
  const country = clamp(req.headers.get("cf-ipcountry"), 8);
  const now = new Date().toISOString();
  const day = now.slice(0, 10);

  // install ごとに 1 行。同日の重複 ping では active-day を二重カウントしない。
  await env.DB.prepare(
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
       last_day    = ?3`
  )
    .bind(id, now, day, appVersion, osVersion, arch, locale, country)
    .run();

  return new Response(null, { status: 204, headers: CORS });
}

async function countActiveSince(env: Env, days: number): Promise<number> {
  const cutoff = new Date(Date.now() - days * 86_400_000).toISOString();
  const row = await env.DB.prepare(
    `SELECT count(*) AS c FROM installs WHERE last_seen >= ?1`
  )
    .bind(cutoff)
    .first<{ c: number }>();
  return row?.c ?? 0;
}

async function handleStats(url: URL, env: Env): Promise<Response> {
  if (url.searchParams.get("key") !== env.STATS_KEY) {
    return new Response("unauthorized", { status: 401 });
  }

  const today = new Date().toISOString().slice(0, 10);

  const total =
    (await env.DB.prepare(`SELECT count(*) AS c FROM installs`).first<{ c: number }>())?.c ?? 0;
  const newToday =
    (
      await env.DB.prepare(
        `SELECT count(*) AS c FROM installs WHERE substr(first_seen, 1, 10) = ?1`
      )
        .bind(today)
        .first<{ c: number }>()
    )?.c ?? 0;

  const [dau, wau, mau] = await Promise.all([
    countActiveSince(env, 1),
    countActiveSince(env, 7),
    countActiveSince(env, 30),
  ]);

  const byVersion = await env.DB.prepare(
    `SELECT app_version AS name, count(*) AS count FROM installs GROUP BY app_version ORDER BY count DESC`
  ).all();
  const byOS = await env.DB.prepare(
    `SELECT os_version AS name, count(*) AS count FROM installs GROUP BY os_version ORDER BY count DESC`
  ).all();
  const byArch = await env.DB.prepare(
    `SELECT arch AS name, count(*) AS count FROM installs GROUP BY arch ORDER BY count DESC`
  ).all();
  const byCountry = await env.DB.prepare(
    `SELECT country AS name, count(*) AS count FROM installs GROUP BY country ORDER BY count DESC`
  ).all();

  return Response.json({
    generated_at: new Date().toISOString(),
    total_installs: total,
    new_today: newToday,
    active: { dau, wau, mau },
    by_version: byVersion.results,
    by_os: byOS.results,
    by_arch: byArch.results,
    by_country: byCountry.results,
  });
}
