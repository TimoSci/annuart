// Dev-only bundle: dev wallet, dev signer, mock FHE. Referenced by the root
// layout only when :dev_wallet is on (dev and test); never part of app.js.
import {initSDK} from "@zama-fhe/relayer-sdk/web"
import {createDevSigner, accounts} from "./chain/signer/dev.js"
import {createMockFhe} from "./chain/fhe/mock.js"

// The mock's generateKeypair() needs the relayer SDK's TKMS WASM. The bundle is
// not an ES module, so the WASM URLs (copied by the assets postinstall) are explicit.
const WASM = "/vendor/relayer-sdk/"
let wasm = null
const initWasm = () => (wasm ??= initSDK({tfheParams: `${WASM}tfhe_bg.wasm`, kmsParams: `${WASM}kms_lib_bg.wasm`}))

window.__annuartDev = {
  createSigner: createDevSigner,
  accounts,
  createFhe: session => createMockFhe(session, {initWasm}),
}
