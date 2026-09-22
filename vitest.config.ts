import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    include: ['tests/**/*.test.ts'],
    coverage: { reporter: ['text', 'html'] },
    // Expansion policies are one row per expansion in a single shared
    // development database, and several suites rotate them to test what
    // rotation does. Run files one at a time so a policy set by one suite is
    // not read by another mid-flight; the alternative — a database per worker —
    // costs more than this suite's runtime saves.
    fileParallelism: false,
  },
});
