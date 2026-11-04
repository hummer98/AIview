-- aiview-metrics D1 schema
-- One row per pseudonymous install UUID; no event log is retained.

CREATE TABLE IF NOT EXISTS installs (
  install_id   TEXT PRIMARY KEY,
  first_seen   TEXT NOT NULL,
  last_seen    TEXT NOT NULL,
  last_day     TEXT NOT NULL,
  app_version  TEXT,
  os_version   TEXT,
  arch         TEXT,
  locale       TEXT,
  country      TEXT,
  active_days  INTEGER NOT NULL DEFAULT 1
);

CREATE INDEX IF NOT EXISTS idx_installs_last_seen ON installs (last_seen);
