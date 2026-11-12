import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    testTimeout: 300000, // 5 minutes - ICRC85 tests advance time by months
    hookTimeout: 120000, // 2 minutes for hooks - some tests have complex setup
    // Run tests sequentially in a single worker to avoid PocketIC conflicts.
    // vitest 4 removed `poolOptions.forks.singleFork`: the replacement is
    // `maxWorkers: 1` (https://v4.vitest.dev/guide/migration#pool-rework).
    pool: 'forks',
    maxWorkers: 1,
    // Run test files sequentially
    fileParallelism: false,
  },
});
