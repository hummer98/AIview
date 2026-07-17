-- aiview-metrics D1 スキーマ
-- install ごとに 1 行のみ保持（イベントログは持たない）

CREATE TABLE IF NOT EXISTS installs (
  install_id   TEXT PRIMARY KEY,   -- アプリ生成の匿名 UUID
  first_seen   TEXT NOT NULL,      -- 初回 ping の ISO8601 タイムスタンプ
  last_seen    TEXT NOT NULL,      -- 直近 ping の ISO8601 タイムスタンプ
  last_day     TEXT NOT NULL,      -- 直近 ping の日付(YYYY-MM-DD)。active_days の二重加算防止用
  app_version  TEXT,
  os_version   TEXT,
  arch         TEXT,               -- arm64 / x86_64
  locale       TEXT,
  country      TEXT,               -- CF の cf-ipcountry（国コードのみ）
  active_days  INTEGER NOT NULL DEFAULT 1  -- ping した延べ日数
);

-- 期間アクティブ集計（DAU/WAU/MAU）を last_seen 範囲で引くための索引
CREATE INDEX IF NOT EXISTS idx_installs_last_seen ON installs (last_seen);
