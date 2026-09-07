import { defineConfig } from "vitest/config";
import {
  cloudflareTest,
  readD1Migrations,
} from "@cloudflare/vitest-pool-workers";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
      miniflare: {
        bindings: {
          TEST_MIGRATIONS: await readD1Migrations("./worker/migrations"),
        },
      },
    }),
  ],
  test: {
    include: ["worker/tests/**/*.test.ts"],
    setupFiles: ["./worker/tests/setup.ts"],
    fileParallelism: false,
  },
});
