import { test, expect } from "@playwright/test";

test("mock FHE round-trip in a browser against Hardhat", async ({ page }) => {
  await page.goto("/index.html?spike=mock");
  await page.waitForFunction(() => window.__spike?.done, null, { timeout: 120_000 });
  const r = await page.evaluate(() => window.__spike);
  expect(r.error).toBeUndefined();
  expect(r.mintedTokenId).toBe("1");
  expect(r.decryptedDistribution).toBe(r.expectedDistribution); // strings of a bigint
});

test("relayer SDK initialises in a browser", async ({ page }) => {
  await page.goto("/index.html?spike=relayer");
  await page.waitForFunction(() => window.__spike?.done, null, { timeout: 120_000 });
  const r = await page.evaluate(() => window.__spike);
  expect(r.error).toBeUndefined();
  expect(r.sdkInitialised).toBe(true); // initSDK() resolved: WASM loaded
});
