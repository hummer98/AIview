# aiview-metrics

AIview の匿名利用計測エンドポイント（Cloudflare Worker + D1）。設計判断は [ADR 002](../../docs/adr/002-anonymous-usage-telemetry.html)。

- 本番 URL: `https://aiview-metrics.rr-yamamoto.workers.dev`
- 保存単位: pseudonymous install UUID ごとに1行（イベントログは保存しない）
- 保存項目: install UUID、アプリ版、macOS版、CPUアーキ、ロケール、Cloudflare付与の国コード、初回/最終送信時刻、active day数
- 保持期間: 最終送信から400日。UTC 03:00の日次scheduled handlerが、400日を超えた行を削除する
- 応答: APIの成功・失敗を問わず`Cache-Control: no-store`。CORSは提供しない

## API v2

### `POST /v1/ping`

`Content-Type: application/json`必須。bodyはUTF-8 JSONで最大4 KiB、未知のfieldを許可しない。

```json
{
  "install_id": "550e8400-e29b-41d4-a716-446655440000",
  "app_version": "0.10.0",
  "os_version": "15.6.0",
  "arch": "arm64",
  "locale": "ja_JP"
}
```

`install_id`はRFC 4122 UUID v4、`app_version`はSemVer、`os_version`は数字と`.`、`arch`は`arm64`/`x86_64`、`locale`は限定した英数字・`-`・`_`だけを受理する。正常時は`204`。同じUTC日の再送は`active_days`を増やさずupsertする。

IP+routeとinstall UUID+routeの二段Rate Limiting bindingを適用する。キーはSHA-256化され、IP/UUID自体をログへ出さない。超過時は`429`と`Retry-After: 60`を返す。

### `POST /v1/delete`

```json
{ "install_id": "550e8400-e29b-41d4-a716-446655440000" }
```

同じJSON/body制限とUUID v4検証を行い、IP+route rate limit後に対象行を削除する。存在したかどうかにかかわらず`204`を返すidempotent endpointで、IDの存在を応答から推測できない。

### `GET /stats`

`STATS_KEY`をWorker secretとして設定し、`Authorization: Bearer` headerだけで認証する。query parameterによる`?key=`認証は廃止済み。

```bash
read -r STATS_KEY < .stats-key
printf 'header = "Authorization: Bearer %s"\n' "${STATS_KEY}" \
  | curl --config - --fail-with-body --silent --show-error \
  "https://aiview-metrics.rr-yamamoto.workers.dev/stats" \
  | python3 -m json.tool
unset STATS_KEY
```

tokenはSHA-256の固定長digestにしてからconstant-time比較する。応答はtotal / new_today / DAU・WAU・MAU / 版・OS・アーキ・国分布。

### その他

| method / route | 用途 |
|---|---|
| `GET /` | health check |
| `GET /ping?id=&v=&os=&arch=&lang=` | v0.9.x互換（deprecated） |

legacy `GET /ping`はv0.10.0のserver-first rolloutから90日間だけ維持し、`wrangler.toml`の`LEGACY_PING_SUNSET=2026-11-09T00:00:00Z`以後は自動的に`410`となる。互換期間中もIP/install rate limit、入力検証、`no-store`を適用し、wildcard CORSは返さない。`Deprecation`、`Sunset`、successor `Link` headerを返す。

## ローカル品質ゲート

Node.js 22以上を使う。lockfileを変更せず再現可能にinstallする。

```bash
npm ci
npm run check
```

`npm run check`はTypeScript typecheck、Cloudflare Workers Vitest integration、Wrangler dry-run bundleを順に実行する。testは`readD1Migrations`/`applyD1Migrations`で実際のD1 bindingへ`migrations/0001_initial.sql`を適用する。

Rate Limiting bindingはlocal実行ではenforcementされないため、testでは次の二層を使う。

- `SELF.fetch` + D1/実bindingによるWorker integration
- 注入したdeterministic fake bindingによるkey・二段判定・`429`検証

rootからは`task worker:test`またはmacOS appを含む`task ci`で同じgateを実行できる。

## migration / deploy runbook

このrunbookは操作手順であり、通常のcode review/CIではremote commandを実行しない。

1. Local: `npm ci && npm run check`、`npx wrangler d1 migrations apply aiview-metrics --local`。
2. Staging: D1 backup/export、pending migration list、`migrations/0001_initial.sql`適用、Worker deploy。
3. Staging smoke: v2 ping/delete/stats、legacy 204、body制限、Bearer拒否、`429`、全応答`no-store`、CORSなしを確認。Rate Limitingはここで実enforcementを確認する。
4. Production: D1 exportを取得後、migration list→apply→Worker deployの順でserver first rollout。
5. Production smoke: old GETとnew POSTの両方が`204`、statsのheader auth、query auth拒否、delete idempotency、rate limit/no-storeを確認してからv0.10.0 clientをrelease。
6. Retention: 初回cron前に`last_seen < now-400 days`の対象件数をread-only queryで確認し、exportが復元可能であることを確かめる。CronはUTC `0 3 * * *`。
7. Legacy retirement: 2026-11-09以後のtrafficを確認して、`GET /ping`と`LEGACY_PING_IP_RATE_LIMIT` bindingを削除する。

`STATS_KEY`はDashboardまたは`npx wrangler secret put STATS_KEY`で設定し、config・ログ・request URLへ書かない。`.stats-key`はignored local secretとして扱う。Rate Limitingの`namespace_id`はaccount内で一意な正整数文字列であることをstaging deploy前に確認する。

## 運用上の注意

- request body、Authorization、IP、install UUIDをproduction logへ出さない
- schema変更は`migrations/`へ追加し、`wrangler d1 execute --file schema.sql`へ戻さない
- remote migration/deploy前に必ずbackupとstaging smokeを完了する
- retention deleteは不可逆なので、初回cron前のexportと対象件数確認を省略しない
