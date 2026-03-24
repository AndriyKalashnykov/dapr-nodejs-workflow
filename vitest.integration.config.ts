import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["src/__tests__/**/*.integration.test.ts"],
    testTimeout: 30000,
    hookTimeout: 15000,
    fileParallelism: false,
    maxConcurrency: 1,
  },
});
