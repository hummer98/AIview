import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

const migrations = await readD1Migrations("./migrations");

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.toml" },
      miniflare: {
        bindings: {
          STATS_KEY: "integration-test-stats-key",
          TEST_MIGRATIONS: migrations,
        },
      },
    }),
  ],
  test: {
    globals: true,
  },
});
