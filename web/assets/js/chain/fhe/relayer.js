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

// The SDK reads the chain through `network`: the configured URL when the server
// gave one (the local chain), else the connected wallet's own provider.
export function createRelayerFhe(session) {
  const chainId = session.chainId;
  const url = chainInfo().rpcUrl;
  const network = url || session.ethereum;
  if (!network) return Promise.reject(new Error("Encryption needs a connected wallet."));
  const key = `${chainId}:${url || "wallet"}`;
  let client = clients.get(key);
  if (!client) {
    client = (async () => {
      const lib = await loadSdk();
      const config = [lib.SepoliaConfig, lib.MainnetConfig].find(c => c?.chainId === chainId);
      if (!config) throw new Error(`Encryption is not available on chain ${chainId}.`);
      return fheFromInstance(await lib.createInstance({...config, network}));
    })();
    clients.set(key, client);
    client.catch(() => { if (clients.get(key) === client) clients.delete(key); });
  }
  return client;
}
