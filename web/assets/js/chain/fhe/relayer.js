// The real FHE client: Zama's relayer SDK. Its prebuilt browser bundle is
// served from /vendor/relayer-sdk/ (copied there by the assets postinstall) and
// loaded with a <script> tag on first use; it sets window.relayerSDK. The WASM
// URLs are passed explicitly, since the bundle's defaults are origin-absolute.
import {chainInfo} from "../signer.js";
import {fheFromInstance} from "../fhe.js";

const BASE = "/vendor/relayer-sdk/";

let sdk = null;

function loadScript(src) {
  return new Promise((resolve, reject) => {
    const el = document.createElement("script");
    el.src = src;
    el.onload = () => resolve();
    el.onerror = () => reject(new Error("Could not load the encryption library."));
    document.head.appendChild(el);
  });
}

function loadSdk() {
  if (!sdk) {
    const loading = (async () => {
      if (!window.relayerSDK) await loadScript(`${BASE}relayer-sdk-js.umd.js`);
      const lib = window.relayerSDK;
      if (!lib?.initSDK) throw new Error("Could not load the encryption library.");
      await lib.initSDK({tfheParams: `${BASE}tfhe_bg.wasm`, kmsParams: `${BASE}kms_lib_bg.wasm`});
      return lib;
    })();
    sdk = loading;
    loading.catch(() => { if (sdk === loading) sdk = null; });
  }
  return sdk;
}

const clients = new Map();

export function createRelayerFhe(session) {
  const chainId = session.chainId;
  let client = clients.get(chainId);
  if (!client) {
    client = (async () => {
      const lib = await loadSdk();
      const config = [lib.SepoliaConfig, lib.MainnetConfig].find(c => c?.chainId === chainId);
      if (!config) throw new Error(`Encryption is not available on chain ${chainId}.`);
      return fheFromInstance(await lib.createInstance({...config, network: chainInfo().rpcUrl}));
    })();
    clients.set(chainId, client);
    client.catch(() => { if (clients.get(chainId) === client) clients.delete(chainId); });
  }
  return client;
}
