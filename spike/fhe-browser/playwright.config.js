import { defineConfig, devices } from "@playwright/test";

// Starts, in order: a fresh Hardhat node with the FHEVM mock (repo root, port 8545); then the
// deploy script (writes deployments/localhost.json) followed by the esbuild static server for
// this directory (port 8611), which inlines that deployment file into dist/spike-mock.js.
// reuseExistingServer is false so a stale chain (where the minted token id is not 1) fails loudly.
export default defineConfig({
  testDir: ".",
  testMatch: "run.spec.js",
  timeout: 180_000,
  workers: 1,
  reporter: "list",
  use: { baseURL: "http://127.0.0.1:8611" },
  projects: [{ name: "chromium", use: { ...devices["Desktop Chrome"] } }],
  webServer: [
    {
      command: "npx hardhat node",
      cwd: "../..",
      url: "http://127.0.0.1:8545",
      timeout: 180_000,
      reuseExistingServer: false,
    },
    {
      command:
        "npm run assets && (cd ../.. && npx hardhat run scripts/deploy.ts --network localhost) && npm run serve",
      url: "http://127.0.0.1:8611/index.html",
      timeout: 180_000,
      reuseExistingServer: false,
    },
  ],
});
