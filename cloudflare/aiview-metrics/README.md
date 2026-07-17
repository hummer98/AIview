# aiview-metrics

AIview の匿名利用計測エンドポイント（Cloudflare Worker + D1）。設計判断は [ADR 002](../../docs/adr/002-anonymous-usage-telemetry.html)。

- 本番 URL: `https://aiview-metrics.rr-yamamoto.workers.dev`
- クライアント: アプリの `TelemetryService`（`AIview/Sources/Data/TelemetryService.swift`）が起動時に日次 1 回 ping。

## ルート

| ルート | 用途 |
|--------|------|
| `GET /ping?id=&v=&os=&arch=&lang=` | install 行を upsert し `204` を返す |
| `GET /stats?key=STATS_KEY` | 集計 JSON（total / new_today / dau,wau,mau / 版・OS・アーキ・国分布） |
| `GET /` | ヘルスチェック |

保存するのは install 単位 1 行のみ（イベントログは持たない）。個人情報は保存しない。スキーマは [`schema.sql`](schema.sql)。

## 集計を見る

```bash
STATS_KEY=$(cat .stats-key)
curl -s "https://aiview-metrics.rr-yamamoto.workers.dev/stats?key=$STATS_KEY" | python3 -m json.tool
```

`.stats-key` は gitignore 済み（Worker の secret と同じ値）。

## デプロイ / 運用

Cloudflare 認証情報を環境に読み込んでから wrangler を叩く（このリポジトリでは `~/git/*/.envrc` の
`CLOUDFLARE_ACCOUNT_ID` / `CLOUDFLARE_API_TOKEN` を流用）。

```bash
export CLOUDFLARE_ACCOUNT_ID=... CLOUDFLARE_API_TOKEN=...

# 初回のみ: D1 作成（database_id を wrangler.toml に記入）
npx wrangler d1 create aiview-metrics

# スキーマ適用（リモート）
npx wrangler d1 execute aiview-metrics --remote --file schema.sql

# STATS_KEY を secret に設定（値は .stats-key にも保存しておく）
openssl rand -hex 24 | tee .stats-key | npx wrangler secret put STATS_KEY

# デプロイ
npx wrangler deploy

# ログ監視
npx wrangler tail
```

### メンテナンス用クエリ

```bash
# テストデータ全消去
npx wrangler d1 execute aiview-metrics --remote --command "DELETE FROM installs;"

# 生データ確認
npx wrangler d1 execute aiview-metrics --remote --command "SELECT * FROM installs ORDER BY last_seen DESC LIMIT 20;"
```

## 無料枠

Cloudflare Workers（10万 req/日）と D1（5GB / 500万行読み・10万行書き/日）の無料枠で十分。
クライアントは install あたり 1 日 1 回しか送らないため、書き込みは install 数/日 に等しい。
