import {defineConfig, devices} from "@playwright/test";

// Starts, in order:
//   1. a fresh Hardhat node with the FHEVM mock (repo root, port 8545);
//   2. global-setup.js run as a script, which deploys the mock, wrapped and
//      auto variants (writing deployments/localhost.json), and then the Phoenix dev
//      server (web/, port 4000). Phoenix reads the deployment file when it
//      starts, so the deploys must finish first. Playwright starts webServers
//      before it runs globalSetup, which is why the deploy is part of this
//      command; globalSetup only checks that it worked.
// reuseExistingServer is false so a stale chain or server fails loudly rather
// than being tested by accident. E2E_REUSE=1 reuses running ones while
// iterating on the flows.
const reuse = process.env.E2E_REUSE === "1";

export default defineConfig({
  testDir: ".",
  testMatch: "flows.spec.js",
  globalSetup: "./global-setup.js",
  timeout: 240_000,
  expect: {timeout: 30_000},
  workers: 1,
  fullyParallel: false,
  reporter: "list",
  use: {
    baseURL: "http://localhost:4000",
    actionTimeout: 30_000,
    navigationTimeout: 60_000,
    trace: "retain-on-failure",
  },
  projects: [{name: "chromium", use: {...devices["Desktop Chrome"]}}],
  webServer: [
    {
      command: "npx hardhat node",
      cwd: "../..",
      url: "http://127.0.0.1:8545",
      timeout: 180_000,
      reuseExistingServer: reuse,
      stdout: "ignore",
    },
    {
      command: "node e2e/global-setup.js && mix phx.server",
      cwd: "..",
      // No live reload: a late watcher rebuild would reload a page mid-flow.
      env: {MIX_ENV: "dev", ANNUART_LIVE_RELOAD: "false"},
      url: "http://127.0.0.1:4000",
      timeout: 300_000,
      reuseExistingServer: reuse,
      stdout: "ignore",
    },
  ],
});
