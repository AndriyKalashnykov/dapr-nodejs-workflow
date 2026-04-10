import { defineConfig } from "vitest/config";

// Integration tests share live infrastructure: a single Dapr sidecar, one
// PostgreSQL database, and one Redis. Running them in parallel causes
// workflow ID collisions, lock contention on the postgres bindings, and
// non-deterministic Redis state. fileParallelism + maxConcurrency = 1
// keeps execution serial — slower, but the tests are reliable.
export default defineConfig({
  test: {
    include: ["src/__tests__/**/*.integration.test.ts"],
    testTimeout: 30000,
    hookTimeout: 15000,
    fileParallelism: false,
    maxConcurrency: 1,
  },
});
