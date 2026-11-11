# Annuart Web, Plan 2 of 3: Browser FHE Spike and Phoenix App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Phoenix LiveView app in `web/` where a person can browse ENFTs without a wallet and, with the development login against a local Hardhat node, create, donate to, claim from, transfer and inspect ENFTs and manage their confidential tokens.

**Architecture:** The Phoenix server is read-only: an indexer GenServer follows `EndowmentMinted` and `Transfer` logs over JSON-RPC into SQLite and LiveViews render public data. Everything secret (encrypting amounts, signing, user decryption, showing decrypted values) happens in browser JavaScript behind two small interfaces, a signer and an FHE client, each with a real and a development implementation. The development implementations live in a separate bundle that production never loads.

**Tech Stack:** Elixir 1.20 / Phoenix 1.8 / LiveView, Ecto + `ecto_sqlite3`, `req`, `ex_abi`; browser JS bundled by Phoenix's esbuild with `ethers@^6.17`, `@fhevm/mock-utils@0.4.2` (dev bundle), `@zama-fhe/relayer-sdk@0.4.1` prebuilt browser bundle; `node --test` for JS unit tests; Playwright 1.65 for browser tests.

**Spec:** `docs/superpowers/specs/2026-11-11-annuart-web-design.md` (sections 2, 4, 5, 6, 7). Plan 1 (contracts) is merged. Plan 3 covers Sepolia deploys and the real-wallet pass; this plan builds the MetaMask signer and the relayer FHE client but verifies them only as far as "loads and passes its stubbed tests".

## Global Constraints

- Work on branch `feat/web-app`, not `main`. All app code lives under `web/`; the only files touched outside it are `README.md` and `.gitignore`.
- **No plaintext amount ever reaches the server.** Endowment amounts, donation amounts, revealed token balances and revealed claimable amounts are read and rendered only by JS hooks. (Wrap and unwrap amounts are public on-chain anyway, but are handled the same way for simplicity.) Inputs that carry a secret amount have no `name` attribute and sit inside a `phx-update="ignore"` container; no `phx-change`, `phx-submit`, `pushEvent` or URL may carry them.
- **The server never holds or sees a private key**, never signs, encrypts or decrypts.
- **The dev login is dev-only.** The dev bundle (`dev.js`: Hardhat mnemonic, dev signer, mock FHE) is referenced only when `Application.get_env(:annuart, :dev_wallet)` is true, which is set only in `config/dev.exs` and `config/test.exs`; and both dev implementations throw unless the chain id is `31337`.
- The UI never implies the remaining endowment can be seen. Exact copy: `Secret. Nobody can read this.`
- An ENFT is identified by `(label, token_id)`; URLs are `/enft/:label/:id`.
- Indefinite sentinel: a segment duration or schedule end equal to `18446744073709551615` (`2^64 - 1`) means indefinite.
- Schedule builder units: a month is 30 days, a year is 365 days, and the Create form says so.
- One running instance talks to one chain. Environment: `ANNUART_RPC_URL` (default `http://127.0.0.1:8545`), `ANNUART_DEPLOYMENTS` (default `../deployments/localhost.json`, relative to `web/`).
- Deployment file shape (written by `scripts/deploy.ts`): `{"chainId": 31337, "contracts": [{"label","nft","token","tokenKind": "mock"|"wrapped"|"plain","underlying": string|null,"deployBlock": number}]}`.
- Contract interface (all on `EndowmentNFT` unless noted):
  - `event EndowmentMinted(uint256 indexed tokenId, address indexed creator, address indexed to, uint64 scheduleStart, bool topUpsAllowed)`, topic0 `0xd8a9f6d0a9cfd3d40de7bcf9e2ae29a4aafc952ea9b81a96fdab2c63f9c1f205`
  - `event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)`, topic0 `0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef`
  - `mint(address to, bytes32 encEndowment, bytes inputProof, (uint64 duration, uint64 ratePerSec)[] segments, uint64 scheduleStart, bool topUpsAllowed) returns (uint256)`
  - `topUp(uint256 tokenId, bytes32 encAmount, bytes inputProof)`, `claim(uint256)`, `accrue(uint256)`, `safeTransferFrom(address,address,uint256)`, `ownerOf(uint256)`
  - views: `scheduleOf(uint256) returns ((uint64,uint64)[])`, `scheduleStartOf`, `scheduleEndOf`, `lastAccrualAtOf` (each `uint64`), `settledOf`, `topUpsAllowedOf` (each `bool`), `distributionHandle(uint256) returns (bytes32)`
  - custom error selectors: `EmptySchedule 0x21bb36f6`, `ZeroDurationSegment 0x91378467`, `IndefiniteSegmentNotLast 0x8dba7587`, `ZeroRateIndefiniteSegment 0x52c92d06`, `TopUpsDisabled 0x4067fd1b`, `NonexistentToken 0xb1d04f08`, `NotOwner 0x30cd7471`, `ScheduleEnded 0x528f27bf`, `ScheduleTooLong 0x15a7d4e1`
  - token (ERC-7984): `symbol()`, `decimals()`, `confidentialBalanceOf(address) returns (bytes32)`, `isOperator(address holder, address spender) returns (bool)`, `setOperator(address operator, uint48 until)`, `event OperatorSet(address indexed holder, address indexed operator, uint48 until)`; mock only: `mint(address to, uint64 amount)`
  - wrapper (`tokenKind: "wrapped"`): `wrap(address to, uint256 amount)`, `unwrap(address from, address to, bytes32 encAmount, bytes inputProof)`, `finalizeUnwrap(bytes32 unwrapRequestId, uint64 unwrapAmountCleartext, bytes decryptionProof)`, `rate()`, `event UnwrapRequested(address indexed receiver, bytes32 indexed unwrapRequestId, bytes32 amount)`; WETH: `deposit()` payable, `withdraw(uint256)`, `approve(address,uint256)`, `balanceOf(address)`
- Colours (greyscale only, no accent): page `#0c0c0d`, resting panel `#141415`, brightest panel `#2b2b2e`, resting text `#86868b`, brightest text `#f2f2f3`, lines `#2a2a2d`.
- TDD: failing test first. Commit after each task, ending messages with
  `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`.
- Commands, all run from `web/` unless stated: `mix test`, `node --test assets/test/`, `npx playwright test` (from `web/e2e/`).

## Review Focus

Conditions the spec implies but does not spell out; each has a test in the named task.

1. The local Hardhat node is restarted and redeployed while the app has a cursor: the indexer rebuilds and shows only the new chain's ENFTs; a deployment entry with no contract code is skipped, not fatal. Task 5.
2. A wallet on the wrong chain, or the user switching account or chain mid-session: actions are blocked with a "switch network" prompt and the page reflects the new address. Task 8.
3. The user rejects the wallet prompt, or a transaction reverts with a custom error: the step shows a plain-language reason and a working retry; nothing is left "in progress". Tasks 7 and 10.
4. A rate that rounds to zero base units per second, an amount with more decimals than the token has, or an amount above `uint64`: the Create form refuses with a specific message before any transaction. Tasks 7 and 11.
5. An ENFT whose contract has no readable schedule (a future private-schedule contract): Browse and the ENFT page show "Private schedule" and nothing crashes. Tasks 5 and 6.

---

## File Structure

```
spike/fhe-browser/            Task 1 only; deleted in Task 14
web/
  config/{config,dev,test,prod,runtime}.exs
  lib/annuart/
    chain/config.ex           deployments file + env -> %Contract{} list
    chain/abi.ex              topics, log decoding, call encoding/decoding
    chain/rpc.ex              JSON-RPC over Req
    chain/reader.ex           typed contract reads
    schedule.ex               pure display maths for schedules
    enfts.ex                  context: queries + upserts
    enfts/{enft,transfer,cursor}.ex
    indexer.ex                GenServer: poll, reset detection, PubSub
  lib/annuart_web/
    live/{browse,enft,create,my_enfts,tokens,market}_live.ex
    live/wallet_hook.ex       on_mount: connected address in assigns
    components/{layouts,enft_components,tx_components}.ex
  assets/js/
    app.js                    LiveSocket + hooks registry (production bundle)
    dev.js                    dev bundle entry: registers dev signer + mock FHE
    units.js                  pure: amounts, durations, rates, schedule maths
    errors.js                 pure: revert/wallet errors -> messages
    activity.js               pure brightness model
    chain/{abi,signer,fhe,actions}.js
    chain/signer/{wallet,dev}.js
    chain/fhe/{relayer,mock}.js
    hooks/{wallet,tx_action,secret_value,create_form,tokens,activity}.js
  assets/test/*.test.js       node --test
  e2e/                        Playwright project
  docs/{fhe-browser-spike.md,manual-checklist.md}
```

---

### Task 1: Browser FHE spike

A throwaway proof that both FHE implementations run in a real browser. Its outcome fixes how `chain/fhe/mock.js` and `chain/fhe/relayer.js` are built in Task 9.

**Files:**
- Create: `spike/fhe-browser/{package.json,index.html,spike-mock.js,spike-relayer.js,run.spec.js,playwright.config.js}`
- Create: `web/docs/fhe-browser-spike.md`

**Interfaces:**
- Produces: `web/docs/fhe-browser-spike.md` with these exact headings, which Task 9 reads: `## Mock in browser: WORKS | FAILS`, `## Mock: how to construct the instance` (the exact `MockFhevmInstance.create(...)` call and where each config value comes from, including the `fhevm_relayer_metadata` RPC result), `## Mock: bundling notes`, `## Relayer SDK in browser: LOADS | FAILS`, `## Relayer SDK: how to load it` (which file is served and how WASM is located), `## Fallback needed: yes | no`.

- [ ] **Step 1: Write the Playwright spec** `spike/fhe-browser/run.spec.js`

```js
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
```

`playwright.config.js` `webServer` starts, in order: `npx hardhat node` (repo root, port 8545), then `npx hardhat run scripts/deploy.ts --network localhost`, then a static server for `spike/fhe-browser/` (the esbuild output).

- [ ] **Step 2: Run and confirm failure**

Run (from `spike/fhe-browser/`): `npm install && npx playwright install chromium && npx playwright test`
Expected: both tests fail, `window.__spike` never set.

- [ ] **Step 3: Implement `spike-mock.js`**

In the browser, with `ethers` and `@fhevm/mock-utils` bundled by esbuild: connect a `JsonRpcProvider` to `http://127.0.0.1:8545`; build a wallet for Hardhat account 0 from the mnemonic `test test test test test test test test test test test junk`; read `deployments/localhost.json` (inlined at build time); create the `MockFhevmInstance`; mock-mint 500 tokens, `setOperator`, encrypt 500, `mint` with segments `[{duration: 1000, ratePerSec: 1}]`; `evm_increaseTime` 100 and `accrue(1)`; user-decrypt `distributionHandle(1)` with an EIP-712 signature from the wallet. Set `window.__spike = { done: true, mintedTokenId, decryptedDistribution, expectedDistribution }` where expected is `min(500, accrueBlockTimestamp - scheduleStartOf(1))`, or `{ done: true, error }`.

- [ ] **Step 4: Implement `spike-relayer.js`**

Load the relayer SDK's prebuilt browser bundle (`@zama-fhe/relayer-sdk/bundle`) with its WASM files served from the same static directory, call `initSDK()`, and set `window.__spike = { done: true, sdkInitialised: true }`. Do not contact Sepolia.

- [ ] **Step 5: Run and record the outcome**

Run: `npx playwright test`
Expected: both pass. Write `web/docs/fhe-browser-spike.md` with the headings above and what was actually needed to make each work.

If the mock cannot be made to work in a browser after a serious attempt, do not fake it: record `## Mock in browser: FAILS` with the exact error, set `## Fallback needed: yes`, and report DONE_WITH_CONCERNS. The fallback (Task 9) is a dev-only local HTTP helper run under Hardhat that performs mock encryption and decryption; no other task changes.

- [ ] **Step 6: Commit**

```bash
git add spike/fhe-browser web/docs/fhe-browser-spike.md
git commit -m "spike: FHE encryption and decryption in the browser"
```

---

### Task 2: Phoenix scaffold, configuration, two asset bundles

**Files:**
- Create: `web/` via `mix phx.new web --app annuart --database sqlite3 --no-mailer --no-dashboard --no-gettext`
- Create: `web/lib/annuart/chain/config.ex`, `web/assets/js/dev.js`, `web/assets/package.json`
- Modify: `web/config/*.exs`, `web/lib/annuart_web/components/layouts/root.html.heex`, `.gitignore`
- Test: `web/test/annuart/chain/config_test.exs`, `web/test/annuart_web/dev_bundle_test.exs`

**Interfaces:**
- Produces: `Annuart.Chain.Config`
  - `%Annuart.Chain.Config.Contract{label: String.t, nft: String.t, token: String.t, token_kind: :mock | :wrapped | :plain, underlying: String.t | nil, deploy_block: non_neg_integer}` (addresses lowercased)
  - `load(path :: String.t) :: {:ok, %{chain_id: integer, contracts: [Contract.t]}} | {:error, :enoent | :invalid}`
  - `chain_id() :: integer`, `contracts() :: [Contract.t]`, `contract(label) :: Contract.t | nil`, `rpc_url() :: String.t` (read from application env set in `runtime.exs`; a missing file yields an empty contract list and a logged warning, not a crash)
- Produces: application env `:annuart, :dev_wallet` (boolean).
- Produces: esbuild builds two outputs, `priv/static/assets/app.js` and `priv/static/assets/dev.js`. The root layout emits `<script src=".../dev.js">` before `app.js` only when `:dev_wallet` is true, and always emits `<meta name="annuart-chain" content='{"chainId":…,"rpcUrl":…,"contracts":[…]}'>` (public data; contracts in the deployment-file shape).
- `dev.js` sets `window.__annuartDev = {}` for now; Tasks 8 and 9 add to it.

- [ ] **Step 1: Generate the app and confirm the generated suite passes**

Run: `mix phx.new web --app annuart --database sqlite3 --no-mailer --no-dashboard --no-gettext`, then in `web/`: `mix setup && mix test`
Expected: generated tests pass. Remove the generated home page, the daisyUI plugin and the theme switcher; keep Tailwind.

- [ ] **Step 2: Write the failing tests**

```elixir
# config_test.exs
test "loads the deployment file shape" do
  path = write_tmp!(~s({"chainId":31337,"contracts":[{"label":"mock","nft":"0xAbC0000000000000000000000000000000000001","token":"0x0000000000000000000000000000000000000002","tokenKind":"mock","underlying":null,"deployBlock":8}]}))
  assert {:ok, %{chain_id: 31337, contracts: [c]}} = Config.load(path)
  assert c.label == "mock" and c.token_kind == :mock and c.deploy_block == 8
  assert c.nft == "0xabc0000000000000000000000000000000000001"
  assert c.underlying == nil
end
test "missing file", do: assert {:error, :enoent} = Config.load("/nonexistent.json")
test "malformed file", do: assert {:error, :invalid} = Config.load(write_tmp!("{"))
test "unknown tokenKind is invalid" # tokenKind "weird" -> {:error, :invalid}

# dev_bundle_test.exs
test "root layout references dev.js only when dev_wallet is on", %{conn: conn} do
  Application.put_env(:annuart, :dev_wallet, true)
  assert html_response(get(conn, ~p"/"), 200) =~ "/assets/dev.js"
  Application.put_env(:annuart, :dev_wallet, false)
  refute html_response(get(conn, ~p"/"), 200) =~ "/assets/dev.js"
end
test "chain meta tag carries chain id and contracts" # parse the meta JSON, assert chainId and labels
```

- [ ] **Step 3: Run and confirm failure**

Run: `mix test test/annuart/chain/config_test.exs test/annuart_web/dev_bundle_test.exs`
Expected: `Annuart.Chain.Config` undefined.

- [ ] **Step 4: Implement** `Chain.Config`, the `runtime.exs` wiring, the second esbuild entry, the layout changes, and a placeholder `/` route rendering an empty page.

- [ ] **Step 5: Verify the production build excludes dev code**

Run: `MIX_ENV=prod mix assets.deploy && ! grep -l "test test test test" priv/static/assets/app*.js`
Expected: exit 0 (no match in the production bundle). Then `mix phx.digest.clean --all`.

- [ ] **Step 6: Run and commit**

Run: `mix test` — expected: all pass.

```bash
git add web .gitignore
git commit -m "feat(web): Phoenix scaffold, chain config, separate dev bundle"
```

---

### Task 3: Chain access: ABI, RPC, typed reads

**Files:**
- Create: `web/lib/annuart/chain/{abi,rpc,reader}.ex`
- Test: `web/test/annuart/chain/{abi_test,reader_test}.exs`, `web/test/support/rpc_stub.ex`

**Interfaces:**
- Produces `Annuart.Chain.Abi`:
  - `topic(:endowment_minted | :transfer) :: String.t` (0x-hex)
  - `decode_log(map) :: {:minted, %{token_id, creator, to, schedule_start, top_ups_allowed}} | {:transfer, %{from, to, token_id}} | :unknown`. Input is a JSON-RPC log map with string keys `"topics"`, `"data"`.
  - `encode_call(fun :: atom, args :: list) :: String.t`, `decode_result(fun :: atom, hex :: String.t) :: term` for `:schedule_of, :schedule_start_of, :schedule_end_of, :last_accrual_at_of, :settled_of, :top_ups_allowed_of, :owner_of, :symbol, :decimals`
- Produces `Annuart.Chain.Rpc` (module chosen via `Application.get_env(:annuart, :rpc, Annuart.Chain.Rpc)` so tests can stub):
  - `block_number() :: {:ok, integer} | {:error, term}`
  - `block(number :: integer) :: {:ok, %{hash: String.t, timestamp: integer}} | {:error, term}`
  - `get_logs(%{address: String.t, from_block: integer, to_block: integer, topics: [String.t | [String.t]]}) :: {:ok, [map]} | {:error, term}`
  - `eth_call(to :: String.t, data :: String.t) :: {:ok, String.t} | {:error, term}` (a revert is `{:error, {:revert, data}}`)
  - `get_code(address) :: {:ok, String.t} | {:error, term}`
- Produces `Annuart.Chain.Reader`:
  - `schedule(nft, id) :: {:ok, [%{duration: integer, rate_per_sec: integer}]} | {:error, :hidden | term}`; `:hidden` when the call reverts or the function does not exist
  - `last_accrual_at(nft, id)`, `schedule_end(nft, id)` :: `{:ok, integer} | {:error, term}`; `settled(nft, id) :: {:ok, boolean} | {:error, term}`
  - `token_meta(token) :: {:ok, %{symbol: String.t, decimals: integer}} | {:error, term}`
- Produces `Annuart.RpcStub` (test support): an Agent-backed module implementing the Rpc functions from canned data, with `put_logs/1`, `put_call/3`, `put_block/2`, `put_head/1`, `put_code/2`.

- [ ] **Step 1: Write the failing tests**

```elixir
test "topics match the contract" do
  assert Abi.topic(:endowment_minted) == "0xd8a9f6d0a9cfd3d40de7bcf9e2ae29a4aafc952ea9b81a96fdab2c63f9c1f205"
  assert Abi.topic(:transfer) == "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
end

test "decodes an EndowmentMinted log" do
  log = %{"topics" => [Abi.topic(:endowment_minted), pad(7), pad_addr("0x00000000000000000000000000000000000c0ffe"), pad_addr("0x00000000000000000000000000000000000a11ce")],
          "data" => "0x" <> word(1_700_000_000) <> word(1)}
  assert {:minted, %{token_id: 7, creator: "0x00000000000000000000000000000000000c0ffe",
                     to: "0x00000000000000000000000000000000000a11ce",
                     schedule_start: 1_700_000_000, top_ups_allowed: true}} = Abi.decode_log(log)
end

test "decodes scheduleOf result" do
  hex = "0x0000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000003e80000000000000000000000000000000000000000000000000000000000000001"
  assert Abi.decode_result(:schedule_of, hex) == [%{duration: 1000, rate_per_sec: 1}]
end

test "unknown log", do: assert Abi.decode_log(%{"topics" => ["0x" <> String.duplicate("00", 32)], "data" => "0x"}) == :unknown
test "Reader.schedule is :hidden when the call reverts"       # RpcStub.put_call(nft, data, {:error, {:revert, "0x"}})
test "Reader.schedule decodes via the stub"                   # canned hex above -> one segment
test "Reader.token_meta"                                      # symbol "MOCK", decimals 6
```

- [ ] **Step 2: Run and confirm failure** — `mix test test/annuart/chain` — modules undefined.

- [ ] **Step 3: Implement**, adding `{:ex_abi, "~> 0.8"}` and `{:req, "~> 0.5"}` to `mix.exs`. `Rpc` posts JSON-RPC 2.0 to `Config.rpc_url()`.

- [ ] **Step 4: Run and commit** — `mix test` passes.

```bash
git add web
git commit -m "feat(web): ABI codec, JSON-RPC client and typed contract reads"
```

---

### Task 4: ENFT store and schedule display maths

**Files:**
- Create: `web/lib/annuart/enfts.ex`, `web/lib/annuart/enfts/{enft,transfer,cursor}.ex`, `web/lib/annuart/schedule.ex`, a migration
- Test: `web/test/annuart/{enfts_test,schedule_test}.exs`

**Interfaces:**
- Schemas:
  - `Enft`: `label`, `nft` (address), `token_id` (integer), `creator`, `owner`, `created_at` (utc_datetime), `created_block`, `schedule_start` (integer, unix), `top_ups_allowed` (boolean), `schedule` (list of `%{"duration" => int, "rate_per_sec" => int}` stored as JSON, or `nil` when hidden). Unique on `(nft, token_id)`.
  - `Transfer`: `enft_id`, `from`, `to`, `block_number`, `log_index`, `tx_hash`, `at` (utc_datetime). Unique on `(tx_hash, log_index)`.
  - `Cursor`: `nft` (unique), `last_block`, `last_block_hash`.
- `Annuart.Enfts`:
  - `list_enfts(opts) :: [Enft.t]` with `opts`: `top_ups: true | false | nil`, `label: String.t | nil`, `sort: :newest | :oldest` (default `:newest`)
  - `get_enft(label, token_id) :: Enft.t | nil`, `list_owned(address) :: [Enft.t]` (case-insensitive), `history(Enft.t) :: [Transfer.t]` (oldest first)
  - `record_mint(attrs) :: {:ok, Enft.t}`, `record_transfer(attrs) :: :ok` (updates `owner`; both idempotent), `reset_contract(nft) :: :ok`, `cursor(nft)`, `put_cursor(nft, block, hash)`
- `Annuart.Schedule` (pure):
  - `indefinite?(segments) :: boolean`
  - `periods(segments, schedule_start) :: [%{starts_at: integer, duration: integer | :indefinite, rate_per_sec: integer, max_payable: integer | :until_empty}]`
  - `total(segments) :: integer | :unbounded`, `ends_at(segments, schedule_start) :: integer | :never`
  - Every function accepts segments keyed by atoms (`%{duration:, rate_per_sec:}`, as `Reader.schedule/2` returns) or by strings (`%{"duration" =>, "rate_per_sec" =>}`, as `Enft.schedule` is stored).
  - `summary(segments, decimals) :: String.t`, e.g. `"100 / day for 18 months, then 2 more periods"`, `"25 / day, indefinitely"`; `"Private schedule"` for `nil`

- [ ] **Step 1: Write the failing tests**

```elixir
# schedule_test.exs
@max 18_446_744_073_709_551_615
test "periods and totals for a fixed schedule" do
  segs = [%{duration: 100, rate_per_sec: 2}, %{duration: 100, rate_per_sec: 5}]
  assert [%{starts_at: 1000, duration: 100, max_payable: 200}, %{starts_at: 1100, duration: 100, max_payable: 500}] = Schedule.periods(segs, 1000)
  assert Schedule.total(segs) == 700
  assert Schedule.ends_at(segs, 1000) == 1200
  refute Schedule.indefinite?(segs)
end
test "indefinite tail" do
  segs = [%{duration: 100, rate_per_sec: 2}, %{duration: @max, rate_per_sec: 3}]
  assert Schedule.indefinite?(segs)
  assert [_, %{starts_at: 1100, duration: :indefinite, max_payable: :until_empty}] = Schedule.periods(segs, 1000)
  assert Schedule.total(segs) == :unbounded
  assert Schedule.ends_at(segs, 1000) == :never
end
test "summary of a hidden schedule", do: assert Schedule.summary(nil, 6) == "Private schedule"
test "summary of a single indefinite period" # rate 1 base unit/sec at 6 decimals -> "0.0864 / day, indefinitely"

# enfts_test.exs
test "record_mint is idempotent and record_transfer moves the owner"
test "list_enfts filters by top_ups and label and sorts by created_at"
test "list_owned is case-insensitive on the address"
test "reset_contract removes that contract's enfts, transfers and cursor only"
test "an enft with schedule nil round-trips"
```

Write each named test with real assertions on the returned structs.

- [ ] **Step 2: Run and confirm failure** — `mix test test/annuart/enfts_test.exs test/annuart/schedule_test.exs`.

- [ ] **Step 3: Implement.** Display amounts in `summary/2` are per day (`rate_per_sec * 86_400 / 10^decimals`), trailing zeros trimmed, lengths in the largest whole unit among years (365 d), months (30 d), days, hours.

- [ ] **Step 4: Run and commit** — `mix test` passes.

```bash
git add web
git commit -m "feat(web): ENFT store and schedule display maths"
```

---

### Task 5: Indexer

**Files:**
- Create: `web/lib/annuart/indexer.ex`; Modify: `web/lib/annuart/application.ex`
- Test: `web/test/annuart/indexer_test.exs`

**Interfaces:**
- Consumes: `Chain.Config.contracts/0`, the Rpc functions, `Chain.Abi.decode_log/1`, `Chain.Reader.schedule/2`, `Enfts.*` (Tasks 2-4), `Annuart.RpcStub`.
- Produces `Annuart.Indexer`:
  - `sync_once() :: :ok`: one pass over every configured contract; pure function of chain state and DB, callable from tests without the GenServer
  - `sync_now() :: :ok`: asks the running GenServer to sync immediately (cast)
  - GenServer polls every `Application.get_env(:annuart, :indexer_interval_ms, 4_000)`; not started when `Application.get_env(:annuart, :indexer, true)` is false (set false in `test.exs`)
  - Broadcasts on `Phoenix.PubSub` (`Annuart.PubSub`), topic `"enfts"`: `{:enft_changed, label, token_id}` per ENFT touched in a pass, and `:enfts_reset` after a rebuild
- Behaviour:
  - Per contract, fetch logs from `cursor.last_block + 1` (or `deploy_block`) to head in chunks of at most 2,000 blocks; apply in `(blockNumber, logIndex)` order.
  - On `:minted`: read the schedule once (`nil` when `{:error, :hidden}`) and the block timestamp for `created_at`; `record_mint`. On `:transfer` with a non-zero `from`: `record_transfer`.
  - Reset detection at the start of each pass: if head is below `cursor.last_block`, or `Rpc.block(cursor.last_block).hash` differs from `cursor.last_block_hash`, call `Enfts.reset_contract/1` and start from `deploy_block`.
  - A contract whose `Rpc.get_code` is `"0x"`, or whose `deploy_block` is above head, is skipped with a logged warning.
  - An RPC error ends the pass for that contract without advancing its cursor and without crashing the GenServer.

- [ ] **Step 1: Write the failing tests** (all against `RpcStub`, using `Abi` to build logs)

```elixir
test "indexes a mint and a transfer" do
  # head 20; mint of token 1 to alice at block 10, transfer alice->bob at block 15
  Indexer.sync_once()
  e = Enfts.get_enft("mock", 1)
  assert e.owner == bob and e.creator == creator and e.top_ups_allowed
  assert e.schedule == [%{"duration" => 1000, "rate_per_sec" => 1}]
  assert [%{from: ^alice, to: ^bob}] = Enfts.history(e)
  assert Enfts.cursor(nft).last_block == 20
end
test "a second pass with no new logs changes nothing and is idempotent"
test "hidden schedule is stored as nil"                              # Review Focus 5: scheduleOf call reverts
test "chain restart rebuilds: old enfts gone, new ones present"       # Review Focus 1: block hash at cursor differs
test "head below cursor triggers a rebuild"                           # Review Focus 1
test "contract with no code is skipped and others still index"       # Review Focus 1
test "rpc error leaves the cursor where it was and does not raise"
test "broadcasts enft_changed for each touched enft"                 # subscribe, assert_receive {:enft_changed, "mock", 1}
test "ranges above 2000 blocks are fetched in chunks"                # assert the stub saw >1 get_logs call with spans <= 2000
```

- [ ] **Step 2: Run and confirm failure** — `mix test test/annuart/indexer_test.exs`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and commit** — `mix test` passes.

```bash
git add web
git commit -m "feat(web): event indexer with restart detection"
```

---

### Task 6: Public pages: layout, Browse, ENFT page, Market

**Files:**
- Create: `web/lib/annuart_web/live/{browse,enft,market}_live.ex`, `web/lib/annuart_web/components/enft_components.ex`
- Modify: `web/lib/annuart_web/router.ex`, `web/lib/annuart_web/components/layouts.ex`, `web/assets/css/app.css`
- Test: `web/test/annuart_web/live/{browse,enft,market}_live_test.exs`

**Interfaces:**
- Routes (one `live_session`): `/` Browse, `/enft/:label/:id` ENFT, `/market` Market. Tasks 8, 11, 12 add `/mine`, `/create`, `/tokens`.
- Navigation, in order: `Browse`, `Create`, `My ENFTs`, `Market` with a small `soon` tag, `Tokens`; then a wallet slot (`<div id="wallet" phx-update="ignore">`, filled in Task 8) and a `Clear my activity history` button (`id="clear-activity"`, wired in Task 13).
- `EnftComponents`: `schedule_chart/1` (attr `periods`; one bar per period, width proportional to duration with an indefinite period drawn striped at a fixed 30% width, height proportional to rate), `schedule_table/1` (attrs `periods`, `decimals`, `symbol`), `address/1` (attrs `value`, `you`; renders `0x70f3…a2c1`, plus ` (you)` when `you` is true), `datetime/1`.
- Every panel and nav item carries `data-activity-id` (Task 13 uses it): `nav:browse`, `nav:create`, `nav:mine`, `nav:market`, `nav:tokens`, `panel:enft:details`, `panel:enft:schedule`, `panel:enft:history`, `panel:enft:yours`, `panel:enft:donate`, `panel:enft:maintenance`, and each Browse row `enft:<label>:<id>`.
- ENFT page assigns available to later tasks: `@enft`, `@contract`, `@token_meta`, `@periods`, `@last_accrual_at`, `@settled`.

- [ ] **Step 1: Write the failing tests** (insert ENFTs through `Enfts.record_mint/1`; stub `last_accrual_at`, `settled`, `token_meta` in `RpcStub`)

```elixir
# browse
test "lists ENFTs without a wallet, newest first", %{conn: conn} do
  {:ok, _v, html} = live(conn, ~p"/")
  assert html =~ "#2" and html =~ "#1"
  assert position(html, "#2") < position(html, "#1")
  assert html =~ "0x0000…a11ce"          # owner, shortened
  assert html =~ "Donations on"
end
test "filters by donations on/off"                 # click filter, the 'off' ENFT disappears
test "hidden schedule shows Private schedule"      # Review Focus 5
test "a new mint appears without reload"           # broadcast {:enft_changed, ...} after record_mint, assert render(view) =~ "#3"
test "empty state"                                 # no ENFTs: "No ENFTs yet."

# enft
test "shows the public details", %{conn: conn} do
  {:ok, _v, html} = live(conn, ~p"/enft/mock/1")
  for text <- ["Owner", "Creator", "Created", "Payouts start", "Payouts end", "Donations", "Last accrued",
               "Secret. Nobody can read this.", "Payout schedule", "History", "Created by"], do: assert html =~ text
end
test "indefinite schedule: Payouts end reads 'When the endowment runs out' and the last row 'Indefinitely' / 'until empty'"
test "fixed schedule notes that any leftover is paid to the owner at the end"
test "settled ENFT says the schedule has ended and the leftover was released"
test "hidden schedule shows Private schedule and no table"   # Review Focus 5
test "history lists transfers oldest first"
test "unknown ENFT renders a not-found page with status 404"
test "no secret-bearing input has a name attribute"          # refute html =~ ~r/<input[^>]*name="amount"/

# market
test "says buying and selling is coming soon and has no form or button"
```

- [ ] **Step 2: Run and confirm failure** — `mix test test/annuart_web/live`.
- [ ] **Step 3: Implement** pages, components and the dark greyscale base styles using the colour values in Global Constraints. Both LiveViews subscribe to `"enfts"`.
- [ ] **Step 4: Run and commit** — `mix test` passes.

```bash
git add web
git commit -m "feat(web): Browse, ENFT and Market pages"
```

---

### Task 7: Browser maths and error messages

**Files:**
- Create: `web/assets/js/{units,errors}.js`
- Test: `web/assets/test/{units,errors}.test.js`

**Interfaces:**
- `units.js` (pure, bigint throughout):
  - `U64_MAX = 18446744073709551615n`
  - `parseAmount(text, decimals) -> bigint`; throws `AmountError` with `code`: `"empty"`, `"not_a_number"`, `"too_many_decimals"`, `"negative"`, `"zero"`, `"too_large"` (above `U64_MAX`)
  - `formatAmount(units, decimals) -> string` (thousands separators, trailing zeros trimmed)
  - `durationSeconds(n, unit) -> bigint` for `unit` in `"days" | "weeks" | "months" | "years"` (86400, 604800, 2592000, 31536000)
  - `ratePerSecond(amountText, per, decimals) -> bigint` for `per` in `"day" | "month" | "year"`: `floor(parseAmount(amountText) / seconds(per))`; throws `AmountError` `"rate_rounds_to_zero"` when the result is `0n`
  - `effectiveRate(perSec, per, decimals) -> string`
  - `toSegments(rows) -> [{duration: bigint, ratePerSec: bigint}]` where a row is `{length, unit, rate, per, indefinite}`; an indefinite row gets `duration: U64_MAX`; throws `ScheduleError` with `code` `"empty"`, `"indefinite_not_last"`, `"zero_length"`
  - `scheduleTotal(segments) -> bigint | null` (`null` when indefinite)
  - `runsDryAt(segments, start, amount) -> bigint | null`: unix time at which cumulative payout reaches `amount`; `null` when the schedule's total is below `amount`
  - `amountWarning(segments, start, amount) -> {kind: "stops_early", at} | {kind: "leftover", extra} | {kind: "runs_dry", at} | null`
- `errors.js`:
  - `explain(err) -> string`, using this exact copy:

| Condition | Message |
|---|---|
| `0x4067fd1b` TopUpsDisabled | `This ENFT does not accept donations.` |
| `0x30cd7471` NotOwner | `Only the owner can do this.` |
| `0x528f27bf` ScheduleEnded | `This ENFT's schedule has ended, so it no longer accepts donations.` |
| `0x15a7d4e1` ScheduleTooLong | `This schedule runs too far into the future.` |
| `0x21bb36f6` EmptySchedule | `Add at least one period.` |
| `0x91378467` ZeroDurationSegment | `Every period needs a length.` |
| `0x8dba7587` IndefiniteSegmentNotLast | `Only the last period can be indefinite.` |
| `0x52c92d06` ZeroRateIndefiniteSegment | `An indefinite period needs a rate above zero.` |
| `0xb1d04f08` NonexistentToken | `This ENFT does not exist.` |
| wallet code `4001` or ethers `ACTION_REJECTED` | `You cancelled the request in your wallet.` |
| ethers `INSUFFICIENT_FUNDS` | `Your wallet does not have enough ETH to pay for this transaction.` |
| anything else | `The transaction failed: ` followed by the error's short message |

  The selector is found in `err.data`, `err.info?.error?.data` or `err.error?.data`.
  - `explainAmount(err, symbol) -> string` for `AmountError`/`ScheduleError` codes; `"rate_rounds_to_zero"` reads `This rate is too small to pay anything. Enter a larger rate.`, `"too_many_decimals"` reads `Use at most N decimal places.` with the token's decimals.

- [ ] **Step 1: Write the failing tests**

```js
test("parseAmount", () => {
  assert.equal(parseAmount("1,000.5", 6), 1000500000n);
  assert.equal(parseAmount("0.000001", 6), 1n);
  assert.throws(() => parseAmount("0.0000001", 6), { code: "too_many_decimals" });
  assert.throws(() => parseAmount("", 6), { code: "empty" });
  assert.throws(() => parseAmount("abc", 6), { code: "not_a_number" });
  assert.throws(() => parseAmount("0", 6), { code: "zero" });
  assert.throws(() => parseAmount("-1", 6), { code: "negative" });
  assert.throws(() => parseAmount("18446744073710", 6), { code: "too_large" }); // > U64_MAX base units
});
test("ratePerSecond", () => {
  assert.equal(ratePerSecond("100", "day", 6), 1157n);        // 100e6 / 86400 floored
  assert.equal(effectiveRate(1157n, "day", 6), "99.9648");
  assert.throws(() => ratePerSecond("1", "month", 6), { code: "rate_rounds_to_zero" }); // 1e6 / 2592000 -> 0
  assert.equal(ratePerSecond("0.0001", "day", 9), 1n);        // cWETH: 100000 / 86400
});
test("toSegments marks the indefinite tail", () => {
  const s = toSegments([{ length: 18, unit: "months", rate: "100", per: "day" }, { rate: "25", per: "day", indefinite: true }]);
  assert.equal(s[0].duration, 46656000n);
  assert.equal(s[1].duration, U64_MAX);
});
test("toSegments rejects an indefinite row that is not last", ...);   // code "indefinite_not_last"
test("scheduleTotal", ...);                                            // [{100n,2n},{100n,5n}] -> 700n; indefinite -> null
test("amountWarning: stops early", ...);   // segments total 700, amount 300 from start 1000 -> {kind:"stops_early", at: 1120n}
test("amountWarning: leftover", ...);      // amount 1000 -> {kind:"leftover", extra: 300n}
test("amountWarning: exact", ...);         // amount 700 -> null
test("amountWarning: indefinite runs dry", ...); // [{100n,2n},{U64_MAX,3n}], amount 500 -> {kind:"runs_dry", at: 1200n}
test("explain maps every selector in the table", ...);                 // loop over the nine selectors
test("explain: user rejection and fallback", ...);
```

Write every `...` test out with the stated values.

- [ ] **Step 2: Run and confirm failure** — `node --test assets/test/` — modules not found.
- [ ] **Step 3: Implement** both modules with no dependencies.
- [ ] **Step 4: Run and commit** — `node --test assets/test/` passes.

```bash
git add web/assets
git commit -m "feat(web): amount, rate and schedule maths; error messages"
```

---

### Task 8: Signer, wallet control, My ENFTs

**Files:**
- Create: `web/assets/js/chain/signer.js`, `web/assets/js/chain/signer/{wallet,dev}.js`, `web/assets/js/hooks/wallet.js`, `web/lib/annuart_web/live/wallet_hook.ex`, `web/lib/annuart_web/live/my_enfts_live.ex`
- Modify: `web/assets/js/{app,dev}.js`, router, layout
- Test: `web/assets/test/signer.test.js`, `web/test/annuart_web/live/my_enfts_live_test.exs`, `web/test/annuart_web/live/wallet_hook_test.exs`

**Interfaces:**
- `chain/signer.js`:
  - `chainInfo() -> {chainId: number, rpcUrl: string, contracts: [...]}` parsed from the `annuart-chain` meta tag
  - `availableSigners() -> [{id: "wallet" | "dev", label}]` (`dev` listed only when `window.__annuartDev?.createSigner` exists)
  - `connect(id, opts) -> Promise<Session>`, `current() -> Session | null`, `disconnect()`, `onChange(fn)`
  - `Session = { kind: "wallet" | "dev", address: string /* checksummed */, signer: ethers.Signer, provider: ethers.Provider, chainId: number }`
  - `ensureChain() -> Promise<void>`: resolves when the session's chain equals `chainInfo().chainId`; for a wallet, requests `wallet_switchEthereumChain` and throws `WrongChainError` if refused
- `signer/wallet.js`: `createWalletSigner(ethereum = window.ethereum)`; listens to `accountsChanged` (empty list means disconnected) and `chainChanged`.
- `signer/dev.js` (dev bundle only): `createDevSigner({index})` deriving account `index` (0-4) from the mnemonic `test test test test test test test test test test test junk`, path `m/44'/60'/0'/0/<index>`, on a `JsonRpcProvider(chainInfo().rpcUrl)`; throws `Error("dev login is only available on chain 31337")` when `chainInfo().chainId !== 31337` or the provider reports another chain. Registered as `window.__annuartDev.createSigner` and `window.__annuartDev.accounts` (five checksummed addresses).
- Wallet hook (`#wallet`): renders `Connect wallet`, or in dev a `<select>` of the five accounts plus `Not connected`; shows the shortened address when connected; remembers the choice in `localStorage` key `annuart:signer` and reconnects on mount; pushes `"wallet:changed"` with `{address: string | null}` to the LiveView on every change.
- `AnnuartWeb.WalletHook` (`on_mount`): assigns `:address` (lowercased or `nil`) and attaches a `handle_event` for `"wallet:changed"` that validates the value is `nil` or a 20-byte hex address before assigning; anything else is ignored.
- `/mine` `MyEnftsLive`: lists `Enfts.list_owned(@address)`; without an address shows `Connect a wallet to see your ENFTs.` Each row has a reveal slot `<span data-secret="distribution" data-label data-id phx-update="ignore">` (wired in Task 10) and links to the ENFT page.

- [ ] **Step 1: Write the failing tests**

```js
// signer.test.js (node --test, with a fake EIP-1193 provider object)
test("wallet signer reports address and reacts to accountsChanged", ...);   // emit accountsChanged(["0xb0b…"]) -> onChange called with new address
test("accountsChanged([]) disconnects", ...);                               // current() === null
test("ensureChain requests a switch and throws WrongChainError when refused", ...); // Review Focus 2
test("ensureChain resolves when already on the right chain", ...);
test("dev signer refuses a chain other than 31337", ...);                   // chainInfo stub with chainId 11155111 -> rejects with the exact message
test("dev signer derives Hardhat account 0", ...);                          // address 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
```

```elixir
# wallet_hook_test.exs
test "wallet:changed assigns a valid address, lowercased"
test "wallet:changed with null clears the address"
test "wallet:changed with a malformed value is ignored"        # "0x123", "<script>", 42
# my_enfts_live_test.exs
test "prompts to connect when no address"
test "lists only ENFTs owned by the connected address"         # render_hook(view, "wallet:changed", %{"address" => alice})
test "updates when the address changes"                        # Review Focus 2
```

- [ ] **Step 2: Run and confirm failure** — `node --test assets/test/signer.test.js` and `mix test test/annuart_web/live`.
- [ ] **Step 3: Implement.** Add `ethers` to `web/assets/package.json`. Structure `signer.js` so it imports nothing dev-only; the dev signer reaches it only through `window.__annuartDev`.
- [ ] **Step 4: Run and commit** — both suites pass; re-run Task 2's production-bundle grep.

```bash
git add web
git commit -m "feat(web): wallet and dev signers, wallet control, My ENFTs"
```

---

### Task 9: FHE client and chain actions

**Files:**
- Create: `web/assets/js/chain/{abi,fhe,actions}.js`, `web/assets/js/chain/fhe/{relayer,mock}.js`
- Modify: `web/assets/js/dev.js`; copy the relayer SDK browser bundle and WASM into `web/priv/static/vendor/relayer-sdk/` via an npm `postinstall` or mix alias (git-ignored)
- Test: `web/assets/test/actions.local.test.js`, `web/assets/test/fhe.test.js`

**Interfaces:**
- Consumes: `web/docs/fhe-browser-spike.md` (Task 1) for how each implementation is constructed; `Session` (Task 8); `units.js`, `errors.js` (Task 7).
- `chain/fhe.js`: `getFhe(session) -> Promise<Fhe>` choosing `window.__annuartDev.createFhe` when `session.chainId === 31337` and it exists, otherwise the relayer client (loaded on first use from `/vendor/relayer-sdk/`).
  - `Fhe = { encrypt64(contractAddress, userAddress, value: bigint) -> Promise<{handle, inputProof}>, userDecrypt(pairs: [{handle, contractAddress}], session) -> Promise<Map<handle, bigint>>, publicDecrypt(handles) -> Promise<{values: Map<handle, bigint>, proof: string}> }`
  - `userDecrypt` caches its keypair and EIP-712 signature per `(address, sorted contract addresses)` in memory for the page's lifetime so repeated reveals do not prompt again; a handle equal to 32 zero bytes decrypts to `0n` without a request.
- `fhe/mock.js` (dev bundle; throws unless chain id is `31337`), `fhe/relayer.js`.
- `chain/actions.js`: every action takes `(session, contract, args, onStep)` where `contract` is an entry of `chainInfo().contracts` and `onStep(stepId, state, detail?)` has `state` in `"active" | "done" | "skipped" | "failed"`. Each returns `{hash}` (the last transaction) plus the extras listed:

| Action | Args | Steps (ids, in order) | Extra result |
|---|---|---|---|
| `createEnft` | `{to, amount: bigint, segments, start: bigint /* 0n = now */, topUps: boolean}` | `authorise` (skipped when `isOperator`), `encrypt`, `confirm`, `mined` | `tokenId` (from `EndowmentMinted`) |
| `donate` | `{tokenId, amount}` | `authorise`, `encrypt`, `confirm`, `mined` | |
| `claim` | `{tokenId}` | `confirm`, `mined` | |
| `accrue` | `{tokenId}` | `confirm`, `mined` | |
| `transfer` | `{tokenId, to}` | `confirm`, `mined` | |
| `authorise` | `{}` | `confirm`, `mined` | `until` |
| `faucet` | `{amount}` | `confirm`, `mined` | (mock tokens only; throws otherwise) |
| `wrap` | `{wei: bigint}` | `deposit`, `approve`, `wrap`, `mined` | |
| `unwrap` | `{amount: bigint}` | `encrypt`, `request`, `decrypt`, `finalise`, `withdraw`, `mined` | |

  - Reads: `revealDistribution(session, contract, tokenId) -> bigint`, `revealBalance(session, contract) -> bigint`, `operatorStatus(session, contract) -> {authorised: boolean, until: number | null}` (`until` from the latest `OperatorSet(holder, nft)` log at or after `contract.deployBlock`), `ethBalance(session) -> bigint`.
  - `authorise` uses `until = now + 365 days`. Every action calls `ensureChain()` first. A failure marks the current step `"failed"` with `errors.explain(err)` and rethrows.

- [ ] **Step 1: Write the failing chain-layer test** `actions.local.test.js` (Node, real local Hardhat node; skipped with a clear message when `http://127.0.0.1:8545` is unreachable)

```js
// before: read ../../deployments/localhost.json; sessions for Hardhat accounts 1 (alice) and 2 (bob) via the dev signer; fhe via the mock
test("create -> accrue -> reveal -> claim on the mock token", async () => {
  await actions.faucet(alice, mock, { amount: 5_000n }, steps);
  const { tokenId } = await actions.createEnft(alice, mock,
    { to: alice.address, amount: 2_000n, segments: [{ duration: 1000n, ratePerSec: 1n }], start: 0n, topUps: true }, steps);
  assert.deepEqual(steps.ids(), ["authorise", "encrypt", "confirm", "mined"]);
  await increaseTime(100);
  await actions.accrue(bob, mock, { tokenId }, steps);          // anyone may accrue
  const d = await actions.revealDistribution(alice, mock, tokenId);
  assert.ok(d >= 100n && d <= 110n);
  await actions.claim(alice, mock, { tokenId }, steps);
  assert.equal(await actions.revealDistribution(alice, mock, tokenId), 0n);
});
test("second create skips the authorise step", ...);            // steps.state("authorise") === "skipped"
test("donate, then transfer; the new owner can reveal and the old owner cannot", ...);
test("leftover is released at the end", ...);                   // amount 2000, schedule total 1000, +1001s, claim -> balance rose by 2000
test("claim by a non-owner fails with the NotOwner message and marks the step failed", ...); // Review Focus 3
test("donate to an ENFT with donations off fails with the TopUpsDisabled message", ...);
test("wrap then unwrap on the wrapped token restores the ETH balance less gas", ...);
test("operatorStatus reports authorised and an expiry about a year out", ...);
```

`fhe.test.js`: `userDecrypt` reuses its signature (a counting fake signer is asked to sign once for two reveals); the zero handle decrypts to `0n` with no signing.

- [ ] **Step 2: Run and confirm failure**

Run (repo root, two terminals): `npx hardhat node`; `npx hardhat run scripts/deploy.ts --network localhost && TOKEN_KIND=wrapped npx hardhat run scripts/deploy.ts --network localhost`. Then from `web/`: `node --test assets/test/`
Expected: `actions.js` not found.

- [ ] **Step 3: Implement**, following the spike document. If the spike recorded `Fallback needed: yes`, `fhe/mock.js` instead calls a dev-only helper: add `scripts/fhe-dev-helper.ts` (run with `npx hardhat run --network localhost`), an HTTP server on `127.0.0.1:8546` with `POST /encrypt64`, `/user-decrypt`, `/public-decrypt` backed by the Hardhat plugin's `fhevm` object, and document starting it in the README. Nothing else in this plan changes.

- [ ] **Step 4: Run and commit** — `node --test assets/test/` passes with the node running; re-run Task 2's production-bundle grep.

```bash
git add web scripts
git commit -m "feat(web): FHE client and chain actions"
```

---

### Task 10: Transaction steps and the ENFT page actions

**Files:**
- Create: `web/assets/js/hooks/{tx_action,secret_value}.js`, `web/lib/annuart_web/components/tx_components.ex`
- Modify: `web/lib/annuart_web/live/{enft,my_enfts}_live.ex`, `web/assets/js/app.js`
- Test: `web/assets/test/tx_action.test.js`, extend `web/test/annuart_web/live/enft_live_test.exs`

**Interfaces:**
- `TxComponents.action/1`: attrs `id`, `action` (an `actions.js` name), `label` (button text), `contract_label`, `token_id` (optional), `confirm` (optional confirmation text); slot `inner_block` for inputs. Renders `<div id={@id} phx-hook="TxAction" phx-update="ignore" data-action data-label data-token-id data-confirm>` containing the slot, the button, and an empty `<ol class="steps">`.
- `TxAction` hook: on click, reads its inputs (`[data-arg="amount"]`, `[data-arg="to"]`) from the DOM, validates with `units.js`, runs the action, and renders the step list itself: each step shows `waiting`, `in progress`, `done`, `skipped` or `failed: <message>` and a `Try again` button on failure. Step labels: `authorise` "Authorise the contract", `encrypt` "Encrypt the amount", `confirm` "Confirm in your wallet", `mined` "Done", `deposit` "Convert ETH to WETH", `approve` "Approve WETH", `wrap` "Wrap", `request` "Request unwrap", `decrypt` "Wait for decryption", `finalise` "Finalise unwrap", `withdraw` "Convert WETH to ETH". On success it pushes `"tx:confirmed"` with `{action, label, tokenId, hash}` only (never an amount).
- `SecretValue` hook on `[data-secret]` (`"distribution"` or `"balance"`): shows `•••••` and a `Reveal` button; on click calls `revealDistribution` / `revealBalance`, shows the formatted value and a `Hide` button; listens for the window event `annuart:tx` to reset to hidden.
- ENFT LiveView: handles `"tx:confirmed"` by calling `Indexer.sync_now()` and re-reading `last_accrual_at` and `settled`; shows panels by rule:
  - **Yours** only when `@address == @enft.owner`: claimable (`SecretValue`, with the note `As of the last accrual.`), `Claim`, `Transfer` (address input; confirmation text `Unclaimed balance goes with the ENFT. Claim first if you want to keep it.`)
  - **Donate** when `@enft.top_ups_allowed` and not past a fixed end; when connected an amount input, otherwise `Connect a wallet to donate.`; note `Encrypted before it leaves your browser.`
  - **Maintenance**: `Update accrual` with `Moves earned payouts into the claimable balance. Anyone may do this.`
  - **Sell**: disabled, `Coming soon`.

- [ ] **Step 1: Write the failing tests**

```elixir
test "owner sees Yours with claim and transfer"                 # render_hook wallet:changed owner
test "non-owner and anonymous visitors do not see Yours"
test "donate panel hidden when donations are off"
test "donate panel hidden after a fixed schedule has ended"     # schedule end in the past
test "donate panel shown on an indefinite schedule"
test "anonymous visitor is told to connect a wallet to donate"
test "tx:confirmed triggers a sync and refreshes last accrued"  # RpcStub new last_accrual_at -> rendered
test "tx:confirmed payload with an amount key is rejected"      # render_hook with %{"amount" => "5"} raises or is ignored and logged; assert no assign holds it
test "amount inputs carry data-arg and no name"                 # html =~ ~s(data-arg="amount"); refute name="amount"
```

```js
// tx_action.test.js (node --test with a minimal DOM stub or linkedom)
test("renders steps as the action reports them", ...);          // onStep("encrypt","active") -> "in progress"
test("a failed step shows the explained message and a retry", ...);   // Review Focus 3
test("retry runs the action again from the start", ...);
test("user rejection leaves no step in progress", ...);         // Review Focus 3
test("an invalid amount is refused before any action runs", ...);
test("the pushed event contains no amount", ...);
```

- [ ] **Step 2: Run and confirm failure.**
- [ ] **Step 3: Implement.** If a DOM library is needed for the hook tests, add `linkedom` as a dev dependency of `web/assets`.
- [ ] **Step 4: Run and commit** — `mix test` and `node --test assets/test/` pass.

```bash
git add web
git commit -m "feat(web): transaction steps and ENFT page actions"
```

---

### Task 11: Create page

**Files:**
- Create: `web/lib/annuart_web/live/create_live.ex`, `web/assets/js/hooks/create_form.js`
- Test: `web/test/annuart_web/live/create_live_test.exs`, `web/assets/test/create_form.test.js`

**Interfaces:**
- Consumes: `units.js` (`toSegments`, `scheduleTotal`, `amountWarning`, `effectiveRate`), `actions.createEnft`, the step rendering of `TxAction`.
- `/create`. Without an address: `Connect a wallet to create an ENFT.` With one, a single `phx-update="ignore"` form driven entirely by the `CreateForm` hook (nothing is sent to the server until success):
  1. **Endowment**: token selector when more than one contract is configured (by label and symbol); amount input; the user's balance as a `SecretValue`; note `Encrypted in your browser. Nobody but you will ever know this number.`
  2. **Payout schedule**: rows of `Lasts [n] [days|weeks|months|years]` and `Pays [amount] per [day|month|year]`; `+ Add period`; remove per row; the last row has an `Indefinitely` checkbox replacing its length; per row the effective rate after rounding and its `Up to` total; a live chart; the line `Schedule pays up to X in total over Y.` or `Schedule pays until the endowment runs out.`; the note `A month is 30 days and a year is 365 days.`
  3. **Options**: `Payouts start` `Now` or a date-time; `Allow donations` with `Cannot be changed later.`; `Recipient` `Me` or an address.
- Warnings (from `amountWarning`, rendered by the hook, never sent anywhere):
  - `stops_early`: `Your endowment is less than the schedule total. Payouts will stop early, around <date>.`
  - `leftover`: `<extra> <symbol> extra will be paid to the owner as a lump sum when the schedule ends.`
  - `runs_dry`: `At these rates the endowment runs out around <date>.`
- On success the hook pushes `"tx:confirmed"` with `{action: "createEnft", label, tokenId, hash}` and the LiveView navigates to `/enft/:label/:tokenId` after `Indexer.sync_now()`.

- [ ] **Step 1: Write the failing tests**

```elixir
test "prompts to connect without an address"
test "renders the three sections and the units note when connected"
test "no amount input has a name and the form has no phx-change or phx-submit"
test "tx:confirmed for createEnft navigates to the new ENFT"    # assert_redirect(view, ~p"/enft/mock/3")
```

```js
// create_form.test.js
test("collects rows into segments and calls createEnft with them", ...);   // 18 months @100/day + indefinite @25/day
test("shows the stops_early warning with a date", ...);
test("shows the leftover warning with the extra amount and symbol", ...);
test("refuses a rate that rounds to zero with the specific message", ...);   // Review Focus 4
test("refuses an amount with too many decimals", ...);                        // Review Focus 4
test("refuses an amount above uint64", ...);                                  // Review Focus 4
test("refuses an invalid recipient address", ...);
test("refuses a start date in the past", ...);
test("the Indefinitely checkbox is offered only on the last row", ...);
```

- [ ] **Step 2: Run and confirm failure.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and commit** — both suites pass.

```bash
git add web
git commit -m "feat(web): Create ENFT page"
```

---

### Task 12: Tokens page

**Files:**
- Create: `web/lib/annuart_web/live/tokens_live.ex`, `web/assets/js/hooks/tokens.js`
- Test: `web/test/annuart_web/live/tokens_live_test.exs`, `web/assets/test/tokens.test.js`

**Interfaces:**
- `/tokens`. Without an address: `Connect a wallet to see your tokens.` With one, a card per configured contract (label, token symbol and decimals from `Reader.token_meta/1`):
  - balance (`SecretValue`, `data-secret="balance"`)
  - authorisation, filled by the `Tokens` hook from `actions.operatorStatus`: `Authorised until <date>` or `Not authorised`, and an `Authorise` action (`actions.authorise`)
  - `token_kind: :mock`: `Get test tokens` (`actions.faucet`, amount `1000` whole tokens)
  - `token_kind: :wrapped`: the wallet's ETH balance; `Wrap` (ETH amount input; `actions.wrap`) and `Unwrap` (token amount input; `actions.unwrap`); the note `Wrapped and unwrapped amounts are public.`; the note `Amounts below 0.000000001 ETH cannot be wrapped and stay in your wallet.`
  - `token_kind: :plain`: balance and authorisation only

- [ ] **Step 1: Write the failing tests**

```elixir
test "prompts to connect without an address"
test "mock token card offers test tokens and no wrap controls"
test "wrapped token card offers wrap and unwrap and says amounts are public"
test "plain token card offers neither"
test "symbol and decimals come from the chain"                 # RpcStub token_meta
```

```js
test("shows 'Authorised until' with the expiry date", ...);    // operatorStatus {authorised: true, until: 1794441600}
test("shows 'Not authorised' and the Authorise button", ...);
test("wrap converts the ETH amount to wei and calls actions.wrap", ...);     // "0.5" -> 500000000000000000n
test("wrap refuses more ETH than the wallet holds", ...);
```

- [ ] **Step 2: Run and confirm failure.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and commit** — both suites pass.

```bash
git add web
git commit -m "feat(web): Tokens page with authorise, faucet, wrap and unwrap"
```

---

### Task 13: Activity brightness

**Files:**
- Create: `web/assets/js/activity.js`, `web/assets/js/hooks/activity.js`
- Modify: `web/assets/css/app.css`, layout, `web/assets/js/app.js`
- Test: `web/assets/test/activity.test.js`

**Interfaces:**
- `activity.js` (pure):
  - `STEPS = 8`, `MAX_ITEMS = 50`
  - `touch(history: string[], id) -> string[]`: `id` moved to the front, deduplicated, truncated to `MAX_ITEMS`
  - `level(history, id) -> number`: `0` when absent, otherwise `max(0, 1 - index / STEPS)`
  - `storageFor({chainId, address}) -> {area: "session" | "local", key}`: no address gives `{area: "session", key: "annuart:activity:session"}`; an address gives `{area: "local", key: "annuart:activity:<chainId>:<address lowercased>"}`
  - `load(storage, key) -> string[]` and `save(storage, key, history)`; both tolerate missing, blocked or corrupt storage by returning `[]` / doing nothing
- `Activity` hook on `<body>`: on click or on `Enter`/`Space` activation inside the nearest `[data-activity-id]`, `touch` and save, then repaint; repaint sets the CSS variable `--lvl` on every `[data-activity-id]`; repaints after every LiveView patch and navigation; switches history when the wallet address changes (no merging); `#clear-activity` empties the active history and repaints.
- CSS: `[data-activity-id]` gets `background: color-mix(in srgb, #2b2b2e calc(var(--lvl, 0) * 100%), #141415)` and `color: color-mix(in srgb, #f2f2f3 calc(var(--lvl, 0) * 100%), #86868b)` with a `.25s` transition. No time-based fading anywhere.

- [ ] **Step 1: Write the failing tests**

```js
test("touch moves the id to the front without duplicates", () => {
  assert.deepEqual(touch(["a", "b", "c"], "c"), ["c", "a", "b"]);
  assert.deepEqual(touch([], "a"), ["a"]);
});
test("level falls one step per other click and reaches zero after 8", () => {
  let h = touch([], "x");
  assert.equal(level(h, "x"), 1);
  for (let i = 0; i < 4; i++) h = touch(h, "o" + i);
  assert.equal(level(h, "x"), 0.5);
  for (let i = 4; i < 8; i++) h = touch(h, "o" + i);
  assert.equal(level(h, "x"), 0);
  assert.equal(level(h, "never"), 0);
});
test("clicking the same item repeatedly does not dim the others", ...);   // touch(h,"a") twice leaves level(h,"b") unchanged
test("history is capped at 50", ...);
test("storageFor: session without a wallet, local and per-address with one", ...);
test("load tolerates corrupt JSON and a throwing storage", ...);
test("the hook repaints levels after a LiveView update", ...);             // call updated(), assert --lvl reapplied to a re-rendered node
test("switching wallet swaps histories without merging", ...);
test("clear empties only the active history", ...);
```

- [ ] **Step 2: Run and confirm failure** — `node --test assets/test/activity.test.js`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and commit** — `node --test assets/test/` and `mix test` pass.

```bash
git add web
git commit -m "feat(web): click-based activity brightness with clearable history"
```

---

### Task 14: Browser end-to-end, checklist, README

**Files:**
- Create: `web/e2e/{package.json,playwright.config.js,global-setup.js,flows.spec.js}`, `web/docs/manual-checklist.md`
- Modify: `README.md`; Delete: `spike/fhe-browser/`

**Interfaces:**
- `playwright.config.js` `webServer`: `npx hardhat node` (repo root), then `mix phx.server` in `web/` on port 4000 with `MIX_ENV=dev`; `global-setup.js` deploys the `mock` and `wrapped` variants before the Phoenix server's first sync.

- [ ] **Step 1: Write the browser flows** `flows.spec.js`

```js
test("anonymous visitor can browse and open an ENFT but sees no owner actions", ...);
test("dev login: get test tokens, create an ENFT, land on its page", ...);
   // Tokens -> Get test tokens -> Create: 2000, one period 1 day @ 1000/day, donations on -> steps reach Done -> URL /enft/mock/<id>
test("owner reveals, claims; a second account donates; owner transfers", ...);
   // evm_increaseTime via RPC, Update accrual, Reveal shows a positive number, Claim -> Reveal shows 0;
   // switch dev account -> Donate 100 -> Done; switch back -> Transfer to account 2 -> owner shown changes, Yours panel gone
test("wrapped token: wrap 0.01 ETH, then unwrap it", ...);
test("a failed action shows its reason and can be retried", ...);
   // open a donations-on ENFT with a 60 s schedule, evm_increaseTime past its end without reloading, Donate
   // -> the step reads "failed: This ENFT's schedule has ended, so it no longer accepts donations." and Try again is offered
test("activity brightness persists across reload and clears", ...);
   // click three panels, reload, assert getComputedStyle --lvl of the last clicked is "1"; Clear -> all "0"
test("no request body or websocket frame contains the entered amount", ...);
   // record page.on("request") bodies and websocket frames during a create with amount 31337.42; assert none contains "31337"
```

- [ ] **Step 2: Run and fix what the browser reveals**

Run (from `web/e2e/`): `npm install && npx playwright install chromium && npx playwright test`
Expected: all pass. A failure here is a real defect in an earlier task: fix it in that task's files with a test at that level where one is possible, and say so in the report.

- [ ] **Step 3: Write `web/docs/manual-checklist.md`**: the same flows as numbered manual steps for a real wallet on Sepolia (used by Plan 3), plus what the automated run cannot judge: readability of dimmed text, layout at phone width, and that the page never suggests the remaining endowment is visible.

- [ ] **Step 4: Update `README.md`** with a "Web app" section: prerequisites (Elixir 1.20, Node 20+), starting the Hardhat node and deploying both variants, `cd web && mix setup && mix phx.server`, the dev login, the environment variables, how to run the three test suites, and the privacy rule that no amount reaches the server. Delete `spike/fhe-browser/`.

- [ ] **Step 5: Full check and commit**

Run: `forge test` (repo root); in `web/`: `mix test && node --test assets/test/`; in `web/e2e/`: `npx playwright test`
Expected: everything passes.

```bash
git add -A web README.md spike
git commit -m "test(web): browser end-to-end flows, manual checklist, README"
```
