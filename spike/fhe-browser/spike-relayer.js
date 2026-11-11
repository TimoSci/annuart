// Spike: the relayer SDK's prebuilt browser bundle initialising in a browser.
// Throwaway code; see web/docs/fhe-browser-spike.md.
//
// index.html loads /relayer-sdk/relayer-sdk-js.umd.js (a copy of
// @zama-fhe/relayer-sdk/bundle/relayer-sdk-js.umd.cjs) with a classic <script> tag, which sets
// window.relayerSDK. That global is exactly what `@zama-fhe/relayer-sdk/bundle` re-exports
// (bundle.js is `export const initSDK = window.relayerSDK.initSDK; ...`). It is read directly
// here because bundling bundle.js would also pull in its `export * from './lib/web'`.
//
// Nothing here contacts Sepolia or a relayer: initSDK() only fetches and instantiates WASM.
const WASM_BASE = "/relayer-sdk/";

async function run() {
  const sdk = window.relayerSDK;
  if (!sdk?.initSDK) throw new Error("window.relayerSDK is not set: the UMD bundle did not load");
  // The bundle's default WASM URLs are origin-absolute ("/tfhe_bg.wasm", "/kms_lib_bg.wasm"),
  // so pass explicit URLs to serve them from a sub-directory.
  const sdkInitialised = await sdk.initSDK({
    tfheParams: `${WASM_BASE}tfhe_bg.wasm`,
    kmsParams: `${WASM_BASE}kms_lib_bg.wasm`,
  });
  return { sdkInitialised };
}

run().then(
  (r) => {
    window.__spike = { done: true, ...r };
  },
  (e) => {
    console.error(e);
    window.__spike = { done: true, error: String(e?.stack || e) };
  },
);
