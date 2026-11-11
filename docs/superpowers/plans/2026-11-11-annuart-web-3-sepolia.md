# Annuart Web 3: Sepolia Readiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the app and the deploy tooling safe and correct on a public chain, so the owner can deploy both ENFT contracts to Sepolia and run the real-wallet pass.

**Architecture:** No new components. The server stops publishing its RPC URL, the indexer follows the chain a few blocks behind the head, the browser reaches the chain through the wallet, and the deploy script gains safeguards and a no-cost pre-flight check. The owner runs the deploys by following `guides/sepolia-deployment.md`; tasks 1 to 4 need no key and no network, task 5 runs after the owner's deploy.

**Tech Stack:** as plans 1 and 2 (Hardhat 2 + `@fhevm/hardhat-plugin`, Phoenix 1.8 / LiveView, `req`, ethers 6.17, `@zama-fhe/relayer-sdk` 0.4.1, `node --test`, Playwright 1.65).

**Spec:** `docs/superpowers/specs/2026-11-11-annuart-web-design.md` (sections 3.7, 4.2, 4.3, 4.4, 7; step 4 of section 8).

## Global Constraints

- **Claude sends no transaction to Sepolia and never handles the owner's private key.** Every Sepolia transaction is the owner's step (spec 3.7). Tasks 1 to 4 must be completable with no key, no RPC URL and no network access beyond package installs.
- No plaintext amount reaches the server, its logs, or the LiveView socket.
- The server never holds a private key.
- The dev login is unusable in production and on any chain other than 31337.
- The UI never implies the remaining endowment is visible.
- **New in this plan:** the server's RPC URL (`ANNUART_RPC_URL`) never reaches a browser unless the chain id is 31337. It usually carries a provider API key.
- Sepolia gets two deployments: label `mock` (`MockConfidentialToken`) and label `wrapped` (`ConfidentialWETH` over Sepolia WETH `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14`). Sepolia chain id is `11155111`.
- No public hosting, no release build: the Sepolia instance is the app run locally with `mix phx.server`, pointed at Sepolia (spec non-goal). The relative `ANNUART_DEPLOYMENTS` path in a release stays out of scope.
- Local behaviour must not change: all four suites stay green (`forge test`; `mix test` in `web/`; `node --test "assets/test/**/*.test.js"` in `web/` with a Hardhat node and both variants deployed; `npx playwright test` in `web/e2e/`).
- Commit trailer: `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`.

## Review Focus

1. **An RPC provider that refuses wide log queries** (range or result limits, HTTP 429). Expected: the indexer logs a warning, keeps its cursor, retries on the next poll, and never crashes or skips blocks; the chunk size is configurable. Pinned in Task 1.
2. **A deployment file that fails to load at start.** Expected: the stored index is left alone, not deleted. Pinned in Task 1.
3. **A wallet connected to the wrong network, or one that does not know Sepolia** (error 4902). Expected: the app offers to add and switch, and a refusal reads `Switch your wallet to the right network.` Pinned in Task 2.
4. **A page opened in dev mode against Sepolia.** Expected: `Connect wallet` is offered and the dev login is not. Pinned in Task 2.
5. **Re-running the deploy script on Sepolia.** Expected: it never silently overwrites a recorded address and never sends anything without `CONFIRM_DEPLOY`. Pinned in Task 3.

---

### Task 1: Server on a public chain

Covers final-review items P1, P2, P4, the parked "clean-up deletes everything" item, and the deferred `Rpc` tests.

**Files:**
- Modify: `web/lib/annuart/chain/config.ex`, `web/lib/annuart/chain/reader.ex`, `web/lib/annuart/chain/rpc.ex`, `web/lib/annuart/indexer.ex`, `web/lib/annuart_web/live/create_live.ex`, `web/config/runtime.exs`, `web/config/test.exs`
- Test: `web/test/annuart/chain/config_test.exs`, `web/test/annuart/chain/reader_test.exs`, `web/test/annuart/indexer_test.exs`, create `web/test/annuart/chain/rpc_test.exs`

**Interfaces:**
- Produces (Elixir):
  - `Annuart.Chain.Config.public/0` — `rpcUrl` is `Config.public_rpc_url()` when set; else the server URL **only if** `chain_id() == 31337`; else `nil`.
  - `Config.public_rpc_url/0 :: String.t() | nil` (app env `:public_rpc_url`, from `ANNUART_PUBLIC_RPC_URL`; blank counts as unset).
  - `Config.confirmations/0 :: non_neg_integer` — app env `:indexer_confirmations` when it is an integer; else `0` on chain 31337 and chain 0, `2` otherwise.
  - `Config.log_chunk/0 :: pos_integer` — app env `:indexer_chunk`, default `2_000`.
  - `Config.index_wait_ms/0` — `20_000 + confirmations() * 15_000`.
  - `Reader.token_meta/1` — unchanged signature; successes are cached per `{chain_id, token}`.
- Produces (env): `ANNUART_PUBLIC_RPC_URL`, `ANNUART_CONFIRMATIONS`, `ANNUART_LOG_CHUNK`. Non-integer or negative values for the last two are ignored with a logged warning (chunk must be ≥ 1).
- Consumes: `Annuart.RpcStub`, `Enfts.delete_unconfigured/1`, `Enfts.cursor/1`.

- [ ] **Step 1: Failing tests for what the page publishes** (`config_test.exs`)

```elixir
test "public/0 hides the server RPC URL off the local chain" do
  put_chain(chain_id: 11_155_111, rpc_url: "https://rpc.example/v3/SECRET", contracts: [])
  assert Config.public().rpcUrl == nil
  refute Jason.encode!(Config.public()) =~ "SECRET"
end

test "public/0 publishes the RPC URL on chain 31337" do
  put_chain(chain_id: 31_337, rpc_url: "http://127.0.0.1:8545", contracts: [])
  assert Config.public().rpcUrl == "http://127.0.0.1:8545"
end

test "public/0 prefers an explicit public RPC URL" do
  put_chain(chain_id: 11_155_111, rpc_url: "https://rpc.example/v3/SECRET", contracts: [])
  Application.put_env(:annuart, :public_rpc_url, "https://public.example")
  assert Config.public().rpcUrl == "https://public.example"
end

test "confirmations default to 0 locally and 2 elsewhere, and can be set" do
  put_chain(chain_id: 31_337, contracts: []);      assert Config.confirmations() == 0
  put_chain(chain_id: 11_155_111, contracts: []);  assert Config.confirmations() == 2
  Application.put_env(:annuart, :indexer_confirmations, 5)
  assert Config.confirmations() == 5
  assert Config.index_wait_ms() == 95_000
end
```

`put_chain/1` is a test helper that sets the `:chain` app env and restores it, and the three new app env keys, in `on_exit`. Also add a LiveView test that the rendered root layout of `/` on chain `11_155_111` does not contain the server RPC URL.

- [ ] **Step 2: Run `mix test test/annuart/chain/config_test.exs`** — expect the new tests to fail.

- [ ] **Step 3: Implement the `Config` functions and read the three variables in `runtime.exs`.** `create_live.ex`'s `wait_ms/0` becomes `Application.get_env(:annuart, :create_wait_ms) || Config.index_wait_ms()`.

- [ ] **Step 4: Failing indexer tests** (`indexer_test.exs`)

  - `"stays confirmations blocks behind the head"`: head 100, deploy block 90, `:indexer_confirmations` 2 → `get_logs` is asked for nothing above block 98 and the cursor ends at 98; a mint in block 99 is not stored; after the head moves to 101 it is.
  - `"does nothing while the head is within the confirmation depth of the deploy block"`: head 91, deploy 90, depth 2 → no `get_logs` call, no cursor, no warning.
  - `"reads logs in chunks of the configured size"`: `:indexer_chunk` 10, range 90..115 → `get_logs` ranges are exactly `90..99`, `100..109`, `110..115`.
  - `"a refused log query keeps the cursor and is retried"`: the stub returns `{:error, {:http, 429}}` for the second chunk → the cursor is the first chunk's last block, `sync_once/0` returns `:ok`; a second pass with the stub healthy completes.
  - `"with no contracts configured the stored rows are left alone"`: seed one ENFT, set contracts to `[]`, `sync_once/0` → the ENFT is still there and no `:enfts_reset` is broadcast.

- [ ] **Step 5: Run them, expect failures; implement.** The sync target is `head - Config.confirmations()`. The reset checks keep using the real head. `delete_unconfigured/1` is skipped when `contracts == []`.

- [ ] **Step 6: Failing tests for the token metadata cache** (`reader_test.exs`): with `:cache_token_meta` set to `true`, two `token_meta/1` calls for one token make the stub's `symbol`/`decimals` calls once each; an `{:error, _}` result is not cached; a different chain id does not share the entry. `config/test.exs` sets `:cache_token_meta` to `false` so existing tests are unaffected; the default is `true`. Store in `:persistent_term`.

- [ ] **Step 7: Run, implement, run.**

- [ ] **Step 8: `Rpc` tests** (`rpc_test.exs`). Make `Rpc` pass `Application.get_env(:annuart, :rpc_req_options, [])` into `Req.post` so the test can supply `plug: {Req.Test, Annuart.Chain.Rpc}`. Cases, each asserting the exact return:
  - JSON-RPC error with revert data → `{:error, {:revert, data}}`
  - HTTP 429 → `{:error, {:http, 429}}`
  - HTTP 200 with a non-map body → `{:error, {:http, 200}}`
  - `eth_getBlockByNumber` returning `null` → `{:error, :not_found}`
  - hex quantities decode to integers for `block_number/0` and a block's `timestamp`
  - a transport error → `{:error, _}` without raising

  Fix whatever these show.

- [ ] **Step 9: `mix test`** — all green. **Commit:** `feat(web): keep the RPC URL on the server; indexer confirmation depth and chunk size; cache token metadata`

---

### Task 2: Browser with a real wallet

Covers P3, the relayer's network source, `wallet_addEthereumChain`, unbounded log reads, and the two parked messaging items.

**Files:**
- Modify: `web/assets/js/chain/signer.js`, `web/assets/js/chain/signer/wallet.js`, `web/assets/js/chain/fhe/relayer.js`, `web/assets/js/chain/actions.js`, `web/assets/js/hooks/wallet.js`, `web/assets/js/hooks/tx_action.js`, `web/assets/js/hooks/tokens.js`
- Create: `web/assets/js/chain/chains.js`, `web/assets/js/chain/logs.js`
- Test: `web/assets/test/signer.test.js`, `fhe.test.js`, `tx_action.test.js`, `tokens.test.js`, create `web/assets/test/logs.test.js`

**Interfaces:**
- Consumes: Task 1's meta tag (`rpcUrl` may be `null`; `chainInfo().rpcUrl` is then `""`).
- Produces:
  - `chains.js`: `export const DEV_CHAIN = 31337` and `export function addChainParams(chainId)` → the `wallet_addEthereumChain` parameter object, or `null` for an unknown chain. For `11155111`: `{chainId: "0xaa36a7", chainName: "Sepolia", nativeCurrency: {name: "Sepolia Ether", symbol: "ETH", decimals: 18}, rpcUrls: ["https://ethereum-sepolia-rpc.publicnode.com"], blockExplorerUrls: ["https://sepolia.etherscan.io"]}`.
  - A wallet session gains `ethereum` (the EIP-1193 provider it was made from).
  - `logs.js`: `export const LOG_LOOKBACK = 50_000`, `export const LOG_CHUNK = 2_000`, and `export async function recentLogs(contract, filter, deployBlock)` → logs from `max(deployBlock, head - LOG_LOOKBACK)` to head, oldest first. One `queryFilter` call; if it throws, the same range again in consecutive `LOG_CHUNK` slices; a slice that throws rethrows.
  - `operatorStatus` → `{authorised, until}` unchanged; `until` is `null` when no `OperatorSet` log is inside the look-back.
  - `pendingUnwraps` → unchanged shape; sources are the look-back logs plus requests remembered in `localStorage` under `annuart:unwraps:<chainId>:<token>:<address>` (lowercased), written by `unwrap` as soon as the request transaction is mined (`{requestId, amountHandle}` as strings), de-duplicated by `requestId`, and dropped from storage once `unwrapRequester(id)` is zero. Storage failures are ignored.

- [ ] **Step 1: Failing signer tests** (`signer.test.js`)

```js
test("the dev login is not offered off the local chain", () => {
  setChainMeta({chainId: 11155111, rpcUrl: null, contracts: []});
  window.__annuartDev = {createSigner: async () => ({}), accounts: []};
  assert.deepEqual(availableSigners().map(s => s.id), ["wallet"]);
});

test("connect('dev') is refused off the local chain", async () => {
  setChainMeta({chainId: 11155111, rpcUrl: null, contracts: []});
  window.__annuartDev = {createSigner: async () => ({kind: "dev"}), accounts: []};
  await assert.rejects(connect("dev", {index: 0}), /dev login is not available/);
});

test("an unknown chain is added, then switched to", async () => {
  const calls = [];
  const ethereum = fakeWallet({request: async ({method, params}) => {
    calls.push(method);
    if (method === "wallet_switchEthereumChain" && calls.filter(m => m === method).length === 1) {
      throw Object.assign(new Error("unknown chain"), {code: 4902});
    }
    return null;
  }});
  await createWalletSigner(ethereum).switchChain(11155111);
  assert.deepEqual(calls, ["wallet_switchEthereumChain", "wallet_addEthereumChain", "wallet_switchEthereumChain"]);
});

test("a chain the app has no parameters for is not added", async () => {
  const ethereum = fakeWallet({request: async () => { throw Object.assign(new Error("x"), {code: 4902}); }});
  await assert.rejects(createWalletSigner(ethereum).switchChain(424242));
});
```

Also: on chain 31337 with the dev bundle present, the `Wallet` hook renders **both** a `Connect wallet` button and the dev `<select>` when nobody is connected (today the select hides the button); with no injected wallet the button's click shows `No wallet found`.

- [ ] **Step 2: Run `node --test "assets/test/signer.test.js"`**, expect failures; implement; re-run.

- [ ] **Step 3: Failing relayer test** (`fhe.test.js`): with a fake `window.relayerSDK` whose `createInstance` records its argument, `createRelayerFhe(session)` passes `network: session.ethereum` when `chainInfo().rpcUrl` is `""`, and the URL string when it is set; a session with neither (`ethereum` undefined and no URL) rejects with `Encryption needs a connected wallet.` Implement.

- [ ] **Step 4: Failing log tests** (`logs.test.js`) against a fake contract whose `queryFilter(filter, from, to)` is recorded and whose `runner.provider.getBlockNumber()` returns a fixed head:
  - head 1_000_000, deploy block 10 → one call with range `950_000..1_000_000`
  - head 3_000, deploy block 2_500 → one call with range `2_500..3_000`
  - first call throws → follow-up calls cover `950_000..1_000_000` in 2_000-block slices with no gap or overlap, results concatenated oldest first
  - a slice that throws → `recentLogs` rejects with that error

  And in `tokens.test.js` / `actions` unit level: an unwrap request remembered in storage but older than the look-back is still returned by `pendingUnwraps` while `unwrapRequester` is non-zero, and is removed from storage once it is zero.

- [ ] **Step 5: Implement `logs.js`; switch `operatorStatus` and `pendingUnwraps` to it; remember unwrap requests.** The Tokens page shows `Authorised` without a date when `until` is `null`.

- [ ] **Step 6: Failing step-list tests** (`tx_action.test.js`)
  - When the failure carries a replacement (`err.replacement?.hash`, set by `actions.js` from ethers' `TRANSACTION_REPLACED` error for reasons `cancelled` and `replaced`), the text names the replacement's short hash, not the original's.
  - A step in state `in-progress` with a transaction hash for more than `STILL_WAITING_MS = 180_000` gains the note `Still waiting. If your wallet shows this transaction as dropped, reload the page and check your balance before trying again.` The timer is injected (`opts.setTimeout`) so the test does not wait; the note goes when the step leaves `in-progress`; no button is added.

- [ ] **Step 7: Implement; run the whole JS suite** with a Hardhat node and both variants deployed (`npx hardhat node`, then the two `scripts/deploy.ts --network localhost` runs): expect no failures and none skipped.

- [ ] **Step 8: `npx playwright test`** in `web/e2e/` — 9 passed. The flows select the dev account through the `<select>`, which must still work with the button beside it.

- [ ] **Step 9: Commit:** `feat(web): real-wallet readiness: dev login local only, relayer through the wallet, bounded log reads`

---

### Task 3: Deploy safeguards and pre-flight check

**Files:**
- Create: `tasks/deployGuard.ts`, `tasks/preflight.ts`, `scripts/preflight.ts`, `test/deployGuard.hh.ts`, `test/preflight.hh.ts`, `.env.example` (root; replace if one exists only under `client/`, leave that one alone)
- Modify: `scripts/deploy.ts`, `.gitignore`

**Interfaces:**
- Produces:
  - `tasks/deployGuard.ts`:
    ```ts
    export type GuardInput = {
      network: string; isLocal: boolean; chainId: number; expectedChainId: number | undefined;
      confirm: string | undefined; label: string; existingLabels: string[]; replace: boolean;
    };
    export function deployRefusal(i: GuardInput): string | null;   // null = go ahead
    ```
  - `tasks/preflight.ts`:
    ```ts
    export const SEPOLIA_FHEVM = {
      acl: "0xf0Ffdc93b7E186bC2f8CB3dAA75D86d1930A433D",
      coprocessor: "0x92C920834Ec8941d2C77D188936E1f7A6f49c127",
      kmsVerifier: "0xbE0E383937d564D7FF0BC3b46c51f0bF8d5C311A",
    };
    export const MIN_BALANCE_WEI = 50_000_000_000_000_000n;   // 0.05 ETH
    export type Facts = {
      chainId: number; deployer: string | null; balanceWei: bigint;
      codeAt: Record<string, boolean>;                 // lowercased address -> has code
      sdk: { acl: string; kmsVerifier: string } | null; // from the relayer SDK's SepoliaConfig
      relayerEncryptOk: boolean | null;                // null = not attempted
      weth: { address: string; symbol: string | null; decimals: number | null } | null;
    };
    export function problems(f: Facts): string[];      // empty = passed
    export function warnings(f: Facts): string[];
    ```
  - Env for `scripts/deploy.ts`: `CONFIRM_DEPLOY`, `REPLACE` (`"1"`), and `TOKEN_ADDRESS` now also accepted for `mock` and `wrapped` (reuse that token instead of deploying one).
- Consumes: `tasks/deployments.ts` (`readDeployments`, `upsertDeployment`).

- [ ] **Step 1: Failing guard tests** (`test/deployGuard.hh.ts`, mocha + chai, run with `npx hardhat test test/deployGuard.hh.ts`)

```ts
const base = { network: "sepolia", isLocal: false, chainId: 11155111, expectedChainId: 11155111,
               confirm: "sepolia", label: "mock", existingLabels: [], replace: false };

it("allows a confirmed first deploy", () => expect(deployRefusal(base)).to.equal(null));
it("refuses a public network without CONFIRM_DEPLOY", () =>
  expect(deployRefusal({ ...base, confirm: undefined })).to.match(/CONFIRM_DEPLOY=sepolia/));
it("refuses a confirmation for another network", () =>
  expect(deployRefusal({ ...base, confirm: "mainnet" })).to.match(/CONFIRM_DEPLOY=sepolia/));
it("refuses when the RPC is not the configured chain", () =>
  expect(deployRefusal({ ...base, chainId: 1 })).to.match(/chain id 1.*11155111/));
it("refuses to overwrite a recorded label", () =>
  expect(deployRefusal({ ...base, existingLabels: ["mock"] })).to.match(/label "mock" is already deployed.*REPLACE=1.*LABEL=/s));
it("overwrites with REPLACE=1", () =>
  expect(deployRefusal({ ...base, existingLabels: ["mock"], replace: true })).to.equal(null));
it("asks for nothing on a local network", () =>
  expect(deployRefusal({ ...base, network: "localhost", isLocal: true, chainId: 31337,
                         expectedChainId: undefined, confirm: undefined, existingLabels: ["mock"] })).to.equal(null));
```

- [ ] **Step 2: Run, expect failure; implement `deployRefusal`.**

- [ ] **Step 3: Wire it into `scripts/deploy.ts`.** Before any deployment: print the network, chain id, deployer address and balance; call `deployRefusal` and exit non-zero with its message if it refuses. On a non-local network with no signer (no `PRIVATE_KEY`) exit with `PRIVATE_KEY is not set`. For `mock` and `wrapped`, a set `TOKEN_ADDRESS` is reused after checking it has code. Print each address as soon as its deployment is mined, so a later failure loses nothing. `expectedChainId` comes from `network.config.chainId`.

- [ ] **Step 4: Check local behaviour is unchanged:** `npx hardhat node`, then `npx hardhat run scripts/deploy.ts --network localhost` twice (the second overwrites `mock` without `REPLACE`), then `TOKEN_KIND=wrapped …`. `deployments/localhost.json` has both labels.

- [ ] **Step 5: Failing pre-flight tests** (`test/preflight.hh.ts`). Start from a `good` `Facts` value (Sepolia, a deployer with 0.1 ETH, code at all three FHEVM addresses and at WETH, SDK addresses equal to `SEPOLIA_FHEVM`, `relayerEncryptOk: true`, WETH `{symbol: "WETH", decimals: 18}`) and assert:
  - `problems(good)` is `[]` and `warnings(good)` is `[]`
  - chain id 1 → a problem matching `/not Sepolia/`
  - `deployer: null` → `/PRIVATE_KEY/`
  - balance `0n` → a problem `/no Sepolia ETH/`; balance 0.01 ETH → no problem, one warning `/below 0\.05/`
  - no code at the ACL address → `/FHE contracts/`
  - SDK ACL differs (case-insensitive compare) → `/encryption library.*different/`
  - `sdk: null` → `/encryption library/`
  - `relayerEncryptOk: false` → `/relayer/`; `null` → no problem and a warning `/relayer check was skipped/`
  - `weth: null` → no problem, warning `/WETH_ADDRESS is not set.*wrapped/`; WETH symbol `"DAI"` or decimals 6 or no code → `/WETH_ADDRESS/`

- [ ] **Step 6: Implement `problems`/`warnings`, then `scripts/preflight.ts`**, which gathers `Facts` and sends **no transaction**:
  - chain id, deployer and balance from Hardhat's provider and first signer;
  - `getCode` for the three addresses and `WETH_ADDRESS`; `symbol()` / `decimals()` on WETH;
  - `SepoliaConfig` from `@zama-fhe/relayer-sdk/node` (read its ACL and KMS verifier fields; confirm the field names against `node_modules/@zama-fhe/relayer-sdk/lib/node.d.ts`, do not guess);
  - relayer check: `createInstance({...SepoliaConfig, network: process.env.SEPOLIA_RPC_URL})`, then `createEncryptedInput(<WETH or ACL address>, <deployer>).add64(1n).encrypt()` inside a 120-second timeout; any throw is `false`, with the message printed. Skipped (`null`) when `PREFLIGHT_SKIP_RELAYER=1`.

  It prints one line per check, then warnings, then `Pre-flight passed` (exit 0) or the problems (exit 1). It refuses to run on a local network with `Pre-flight is for public networks`.

  The agent cannot run this against Sepolia without the owner's RPC URL. Verify what can be verified: `npx hardhat run scripts/preflight.ts --network localhost` prints the refusal; `npx hardhat run scripts/preflight.ts --network sepolia` with no `SEPOLIA_RPC_URL` fails with a readable message, not a stack trace.

- [ ] **Step 7: Track the Sepolia deployment file.** In `.gitignore` replace `deployments/` with:

```
deployments/*
!deployments/sepolia.json
```

Verify: `git check-ignore deployments/localhost.json` prints the path; `git check-ignore deployments/sepolia.json` prints nothing.

- [ ] **Step 8: `.env.example`** listing `SEPOLIA_RPC_URL`, `PRIVATE_KEY`, `WETH_ADDRESS` (with the Sepolia WETH address), `CONFIRM_DEPLOY`, each with a one-line comment, and a note that Hardhat reads the shell environment, not this file.

- [ ] **Step 9: `npx hardhat test` and `forge test`** — green. **Commit:** `feat: deploy safeguards for public networks and a no-cost pre-flight check`

---

### Task 4: Documentation matches the tooling

**Files:**
- Modify: `guides/sepolia-deployment.md`, `web/docs/manual-checklist.md`, `README.md`

- [ ] **Step 1: Reconcile the guide with what tasks 1 to 3 built.** Every command, variable name, default and quoted output line in `guides/sepolia-deployment.md` must match the code exactly (run each local-safe command and compare; read the code for the rest). Change the guide where it differs, not the code, unless the code is wrong. Remove the "Before you start" paragraph's "until then those commands do not exist" sentence.

- [ ] **Step 2: Fix the manual checklist.**
  - "Before you start" step 1 becomes: follow `guides/sepolia-deployment.md` (the `mock` and `wrapped` variants; today it says `wrapped` and `plain`).
  - Add a section for the mock contract, as spec section 7 requires: Tokens → `Get test tokens` on the mock card → reveal → Create on the mock token → accrue → reveal → claim.
  - Say, where the list waits on the server, that Sepolia shows a new ENFT or a transfer after about half a minute (two confirmations), and that `Created. Waiting for it to appear…` can last that long.
  - Section 7 gains: a wallet that does not know Sepolia is offered it (add network), then switched.
  - Section 8 gains: the page source's `annuart-chain` meta tag has `"rpcUrl":null`, and the server's RPC URL appears nowhere in the Network tab.

- [ ] **Step 3: README "Web app" section.** Add `ANNUART_PUBLIC_RPC_URL`, `ANNUART_CONFIRMATIONS`, `ANNUART_LOG_CHUNK` to the environment table with their defaults from Task 1; replace the Sepolia lines of the Hardhat section with a pointer to the guide and the `CONFIRM_DEPLOY` requirement; note that the dev login is offered only on chain 31337, beside `Connect wallet`.

- [ ] **Step 4: Run all four suites** (see Global Constraints) — green. **Commit:** `docs: Sepolia deployment guide, checklist and README match the tooling`

---

### Task 5: After the owner's deploy (read-only checks, then fixes from the wallet pass)

**Gate: do not start until the owner says both contracts are deployed.** It needs `deployments/sepolia.json` (two entries, chain id 11155111) and `SEPOLIA_RPC_URL` in the environment. If either is missing, stop and ask; do not substitute a public RPC or a local chain. Nothing in this task sends a transaction or uses a private key.

**Files:**
- Create: `web/e2e/sepolia.spec.js`, `web/e2e/playwright.sepolia.config.js`
- Modify: whatever the checks and the owner's report show to be wrong

- [ ] **Step 1: The server indexes Sepolia.** From `web/`: `ANNUART_RPC_URL="$SEPOLIA_RPC_URL" ANNUART_DEPLOYMENTS=../deployments/sepolia.json mix phx.server`. Within two minutes the log has no indexer warnings that repeat, `/` returns 200 and lists both contract labels in the contract filter, and `/tokens` shows `cWETH` with 9 decimals and the mock token's symbol. If the provider refuses the log range, lower `ANNUART_LOG_CHUNK`, record the working value, and add it to the guide.

- [ ] **Step 2: The page keeps the RPC URL private.** `curl -s localhost:4000 | grep -c "$SEPOLIA_RPC_URL"` prints `0`.

- [ ] **Step 3: The browser's encryption library works against live Sepolia** (`sepolia.spec.js`, run with `npx playwright test -c playwright.sepolia.config.js`; the config starts only the Phoenix server with the two variables above and has no Hardhat node). The page gets a minimal read-only EIP-1193 stub whose `request` forwards `eth_chainId`, `eth_call`, `eth_getCode`, `eth_blockNumber` and `eth_getLogs` through Playwright's `page.exposeFunction("__rpc", …)` to `SEPOLIA_RPC_URL` in the Node process, and rejects every other method. Do not add a server route for this: it would publish the URL. The test builds a session `{address: <random>, chainId: 11155111, ethereum: stub}`, calls `createRelayerFhe(session)` and `encrypt64(<mock nft>, <address>, 1n)`, and asserts a 32-byte handle and a non-empty proof. Timeout 180 s.

  If this fails because the relayer rejects SDK 0.4.1: upgrade `@zama-fhe/relayer-sdk` in `web/assets` (and the root, for the pre-flight) to the version `client/` already uses, or to its successor `@zama-fhe/sdk` if the relayer requires it; re-run this step, the JS suite and the e2e suite; record what changed in `web/docs/fhe-browser-spike.md`.

- [ ] **Step 4: Hand over for the wallet pass.** Report steps 1 to 3 to the owner and ask them to run `web/docs/manual-checklist.md`. Their run is the acceptance test of the whole project (spec section 7).

- [ ] **Step 5: Fix what the pass finds.** One commit per finding, each with a failing test first where a test can express it, then the four suites. Repeat until the owner reports the checklist passes. **Final commit message for a clean pass:** `docs: record the Sepolia wallet pass` (add the date, the two contract addresses and the SDK version to `web/docs/manual-checklist.md`).
