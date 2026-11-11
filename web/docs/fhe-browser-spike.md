# FHE in the browser: spike findings

Task 1 spike, code in `spike/fhe-browser/`. Both checks ran in headless Chromium (Playwright 1.65,
Chrome Headless Shell 158) against a fresh `npx hardhat node` (chain id 31337) with the
`@fhevm/hardhat-plugin` mock, after `scripts/deploy.ts`. Versions: `@fhevm/mock-utils` 0.4.2,
`@zama-fhe/relayer-sdk` 0.4.1, `ethers` 6.17.0, `esbuild` 0.28.2.

Run it with: `cd spike/fhe-browser && npm install && npx playwright install chromium && npx playwright test`.

Observed result: `{"done":true,"mintedTokenId":"1","decryptedDistribution":"100","expectedDistribution":"100"}`
for the mock, `{"done":true,"sdkInitialised":true}` for the relayer SDK. 2 of 2 tests pass.

## Mock in browser: WORKS

The complete flow ran in the page, with no Node helper: a wallet for Hardhat account 0 (from the
mnemonic), mock-mint 500, `setOperator`, encrypt 500 with `MockFhevmInstance`, `mint` with
`[{duration: 1000, ratePerSec: 1}]`, `evm_increaseTime 100`, `accrue(1)`, then EIP-712 user
decryption of `distributionHandle(1)`, signed by the wallet. The decrypted value equals
`min(500, accrueBlockTimestamp - scheduleStartOf(1))`.

What "encryption" means here: with the mock nothing is encrypted with real FHE. `encrypt()`
sends the cleartext to the Hardhat node (`fhevm_relayer_v1_input_proof`), and the node keeps
the clear values. `userDecrypt` gets clear values back from the node (`fhevm_relayer_v1_user_decrypt`),
after the mock checks the ACL and the EIP-712 signature. That is how the mock works, not a
problem with the browser, but plaintext amounts do reach the local Hardhat node (never the
Phoenix server).

Every RPC call the page made went to `http://127.0.0.1:8545`. The Hardhat node answers
cross-origin requests from `http://127.0.0.1:8611` without any extra setup.

## Mock: how to construct the instance

All config comes from the chain. Nothing is hard-coded and the deployment file is not needed.
From `spike/fhe-browser/spike-mock.js` (`createMockInstance`):

```js
import { JsonRpcProvider } from "ethers";
import { MockFhevmInstance, contracts, relayer } from "@fhevm/mock-utils";

const provider = new JsonRpcProvider("http://127.0.0.1:8545", undefined, { pollingInterval: 100, cacheTimeout: -1 });

const metadata = await relayer.requestRelayerMetadata(provider); // RPC "fhevm_relayer_metadata", params []
const inputVerifier = await contracts.InputVerifier.create(provider, metadata.InputVerifierAddress);
const kmsVerifier = await contracts.KMSVerifier.create(provider, metadata.KMSVerifierAddress);

const instance = await MockFhevmInstance.create(
  provider, // relayerProvider: the Hardhat node answers the fhevm_relayer_* RPCs
  provider, // readonlyEthersProvider: ACL checks and contract reads
  {
    verifyingContractAddressDecryption: kmsVerifier.gatewayDecryptionAddress,
    verifyingContractAddressInputVerification: inputVerifier.gatewayInputVerificationAddress,
    kmsContractAddress: metadata.KMSVerifierAddress,
    inputVerifierContractAddress: metadata.InputVerifierAddress,
    aclContractAddress: metadata.ACLAddress,
    chainId: metadata.chainId,
    gatewayChainId: Number(kmsVerifier.gatewayChainId),
  },
  {
    inputVerifierProperties: inputVerifier.inputVerifierProperties,
    kmsVerifierProperties: kmsVerifier.kmsVerifierProperties,
  },
);
```

Where each value comes from:

- `fhevm_relayer_metadata` (handled by `FhevmProviderExtender` in the hardhat plugin) returns
  `{ version, chainId, gatewayChainId, ACLAddress, CoprocessorAddress, KMSVerifierAddress, InputVerifierAddress, relayerSignerAddress }`.
  The spike takes `chainId` (31337), `ACLAddress`, `KMSVerifierAddress` and `InputVerifierAddress`
  from it. The `requestRelayerMetadata` helper checks the shape of the response.
- The metadata does **not** include the gateway verifying contracts. They come from the host
  contracts' EIP-712 domains, `eip712Domain()`, which `contracts.InputVerifier.create` and
  `contracts.KMSVerifier.create` read on-chain: `gatewayInputVerificationAddress`,
  `gatewayDecryptionAddress` and `gatewayChainId` (the domain chain id). The same `create` calls
  also read the signer lists and thresholds, and their `*Properties` getters give the fourth
  argument. `MockFhevmInstance.create` would read these again if passed `{}`. Passing them avoids
  a second round of calls. This is the same thing the plugin's `FhevmEnvironment.createInstance()`
  does with its contracts repository.
- `metadata.gatewayChainId` comes from the same KMS verifier domain on the node side (the plugin's
  `getGatewayChainId()`). The spike uses the value it read on-chain, because the mock's EIP-712
  checks compare against that value. The spike did not compare the two.

User decryption is the same API as the relayer SDK:
`generateKeypair()`, `createEIP712(publicKey, [contract], startTimestamp, durationDays)`,
`wallet.signTypedData(domain, { [primaryType]: types[primaryType] }, message)`, then
`userDecrypt([{ handle, contractAddress }], privateKey, publicKey, signature, [contract], user, startTimestamp, durationDays)`.
The result is keyed by handle and holds a `bigint`.

ethers detail found during the spike (it applies to any in-page signer on the automining node):
an ethers v6 provider caches identical RPC results for 250 ms by default. Back-to-back
transactions then reuse a stale `eth_getTransactionCount` and fail with
`NONCE_EXPIRED: Nonce too low. Expected nonce to be 3 but got 2`. `cacheTimeout: -1` fixes it.
`pollingInterval: 100` makes `tx.wait()` fast. The default is 4 s.

## Mock: bundling notes

- esbuild, `--bundle --format=esm --platform=browser --target=esnext`. The mock entry bundles to
  2.0 MB, unminified.
- **Required alias:** `--alias:@zama-fhe/relayer-sdk/node=@zama-fhe/relayer-sdk/web`.
  `@fhevm/mock-utils` (`fhevm/MockFhevmInstance.js`) imports `KmsEIP712` and `TKMSPkeKeypair` from
  `@zama-fhe/relayer-sdk/node`. The web entry exports the same names. No other import in
  mock-utils is Node-only. Its only external imports are `ethers` and that one.
- **WASM is needed even for the mock:** `MockFhevmInstance.generateKeypair()` calls
  `TKMSPkeKeypair.generate()`, which needs the TKMS WASM. Call `initSDK()` (imported from
  `@zama-fhe/relayer-sdk/web`, which is the same module instance as the aliased import) before
  `generateKeypair()`. `initSDK()` always loads both `tfhe_bg.wasm` (4.7 MB) and
  `kms_lib_bg.wasm` (0.65 MB). Encryption and `createEIP712` work without it. Only keypair
  generation needs it.
- `lib/web.js` finds its WASM with `new URL('tfhe_bg.wasm', import.meta.url)` and
  `new URL('kms_lib_bg.wasm', import.meta.url)`. esbuild leaves `import.meta.url` alone in ESM
  output, so both files must sit **next to the bundle**. The spike copies
  `node_modules/@zama-fhe/relayer-sdk/lib/{tfhe_bg,kms_lib_bg}.wasm` into `dist/` (`npm run assets`).
  `initSDK({ tfheParams: url, kmsParams: url })` can also point elsewhere.
- Target: `--target=es2022` **fails**:
  `Source phase imports are not available in the configured target environment ("es2022")`, from
  `wasm-feature-detect/dist/esm/index.js`, a dependency of the relayer SDK. `esnext` builds. The
  `import.source` code is tree-shaken out of the output, so the bundle runs in current Chromium.
- The deployment file can be inlined by importing the JSON (`import d from ".../localhost.json"`).
  esbuild bundles JSON.
- Without `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp`
  the SDK logs `This browser does not support threads...` and runs single-threaded. That was fine
  here. The thread pool would also need `workerHelpers.js` served next to the bundle. The spike
  did not test threads.

## Relayer SDK in browser: LOADS

`initSDK()` from the prebuilt bundle resolved to `true` in Chromium, after fetching and
instantiating `tfhe_bg.wasm` and `kms_lib_bg.wasm` from the static server. No other network
request was made. `createInstance` (which contacts a relayer and fetches the network key) was
**not** called, so Sepolia encryption and decryption in the browser are still unproven. That
check needs the network.

## Relayer SDK: how to load it

- Served file: `node_modules/@zama-fhe/relayer-sdk/bundle/relayer-sdk-js.umd.cjs`, copied as
  `relayer-sdk/relayer-sdk-js.umd.js` and loaded with a classic `<script src>`. It sets
  `window.relayerSDK` (`initSDK`, `createInstance`, `SepoliaConfig`, ...).
  `@zama-fhe/relayer-sdk/bundle` (`bundle.js`) is only `export const initSDK = window.relayerSDK.initSDK; ...`
  plus `export * from './lib/web'`, so it needs the UMD script to run first. Bundling it would also
  pull in all of `lib/web.js`. The spike therefore reads `window.relayerSDK` directly. The bundle
  directory also has an ESM build (`relayer-sdk-js.js`, with the same exports) that could be loaded
  with `<script type="module">` or a dynamic `import()`. The spike did not test it.
- How the WASM is found: by default the bundle uses origin-absolute URLs,
  `new URL("/tfhe_bg.wasm", scriptSrc)` and `new URL("/kms_lib_bg.wasm", scriptSrc)` (read from
  the bundle source), so the WASM would have to be served at the site root. The spike serves
  `bundle/{tfhe_bg,kms_lib_bg}.wasm` under `/relayer-sdk/` and passes them explicitly:
  `window.relayerSDK.initSDK({ tfheParams: "/relayer-sdk/tfhe_bg.wasm", kmsParams: "/relayer-sdk/kms_lib_bg.wasm" })`.
  Use the WASM files from `bundle/` with the bundle and those from `lib/` with `lib/web.js`.
  The spike always paired each with its own copies.
- In a Phoenix app this means: copy the UMD file and both WASM files into `priv/static/...` and
  pass the two URLs to `initSDK`. No bundler step is needed for the relayer side.

## Fallback needed: no

The mock runs fully in the browser. The dev-only Hardhat HTTP helper is not needed. Task 9 can
build `chain/fhe/mock.js` on `MockFhevmInstance` as above (esbuild alias, WASM next to the
bundle, `initSDK()` before `generateKeypair()`), and `chain/fhe/relayer.js` on the UMD bundle
with explicit WASM URLs.
