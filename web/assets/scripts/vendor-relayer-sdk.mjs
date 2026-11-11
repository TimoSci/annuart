// Copies the relayer SDK's prebuilt browser bundle and its WASM into
// priv/static/vendor/relayer-sdk/ (git-ignored), where chain/fhe/relayer.js
// loads them and dev.js points the mock's WASM. Run by `npm install` (postinstall).
import {copyFileSync, mkdirSync} from "node:fs";
import {fileURLToPath} from "node:url";

const src = new URL("../node_modules/@zama-fhe/relayer-sdk/bundle/", import.meta.url);
const dest = new URL("../../priv/static/vendor/relayer-sdk/", import.meta.url);

mkdirSync(dest, {recursive: true});
for (const [from, to] of [
  ["relayer-sdk-js.umd.cjs", "relayer-sdk-js.umd.js"],
  ["tfhe_bg.wasm", "tfhe_bg.wasm"],
  ["kms_lib_bg.wasm", "kms_lib_bg.wasm"],
]) {
  copyFileSync(new URL(from, src), new URL(to, dest));
}
console.log(`relayer SDK copied to ${fileURLToPath(dest)}`);
