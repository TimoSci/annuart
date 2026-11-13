# Automatic-Payout ENFT Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a second ENFT contract type whose payouts anyone can trigger and which pays the owner in plain ETH, with per-ENFT settings (on/off, interval, fee), and surface it in the web app.

**Architecture:** `AutoPayoutEndowmentNFT` extends `EndowmentNFT` and adds a two-transaction payout (request an unwrap of the claimable balance to the contract itself; finalise with a decryption proof the contract verifies on its own, then pay ETH). It is deployed as a third entry (`auto`) sharing the `wrapped` entry's cWETH. The Phoenix server indexes three new public events; the browser gains actions, a panel hook and Create-form controls. A standalone keeper script lets anyone trigger due payouts with their own key.

**Tech Stack:** Solidity 0.8.27, `@fhevm/solidity` 0.11.1, `@openzeppelin/confidential-contracts` 0.4.1, Foundry with `forge-fhevm`, Hardhat 2 with `@fhevm/hardhat-plugin`; Phoenix 1.8 / LiveView, Ecto + SQLite; ethers 6, `node --test`, linkedom, Playwright.

**Spec:** `docs/superpowers/specs/2026-11-13-automatic-payout-enft-design.md`. It builds on `docs/superpowers/specs/2026-11-11-annuart-web-design.md`, whose rules still apply.

## Global Constraints

- **The owner runs every Sepolia transaction.** No task sends a transaction to Sepolia or handles the owner's private key. The keeper is run by Claude on the local chain only.
- The server never holds a private key. The server's RPC URL never reaches a browser off the local chain.
- No plaintext amount reaches the server, its logs or the LiveView socket, **except** automatic payout amounts and fees, which are public chain data (spec section 3). Endowments, claimable balances, token balances and manual claims stay browser-only.
- The UI never implies the remaining endowment is visible.
- `EndowmentNFT`'s external behaviour does not change. Its existing forge and Hardhat tests pass unmodified.
- An ENFT with automatic payouts off behaves exactly like an ENFT of the existing type.
- Exact values: default interval `86400` s; interval bounds `3600` to `31536000` s inclusive; default fee `0`; fee paid `min(fee, amountWei / 10)`; ETH sends use a gas limit of `100000`.
- No admin functions and no contract-owner role.
- Contract errors are custom errors, as in `EndowmentNFT`. Web copy is plain English in the existing dark minimal theme; no new dependencies.
- In `web/`, finish with `mix precommit` (see `web/AGENTS.md`).

## Review Focus

1. **Someone calls the wrapper's `finalizeUnwrap` directly before `finalizePayout`.** The payout must still be paid, once. (Task 2)
2. **The owner changes the fee, or transfers the ENFT, between request and finalise.** Recipient and fee are those at the request. (Task 2)
3. **The recipient is a contract that rejects ETH or burns gas.** The finaliser's transaction succeeds and the recipient is paid in WETH. (Task 2)
4. **The indexer sees `PayoutPaid` in a later chunk than its `PayoutRequested`, or re-reads a range after a reset.** Rows are upserted by request id; nothing is duplicated or lost. (Task 4)
5. **A visitor opens the page while a payout requested by someone else is pending, and decryption is not ready.** The page offers `Finish payout`, a failed decrypt can be retried, and a retry never requests a second payout. (Tasks 5 and 8)

---

### Task 1: Contract settings

**Files:**
- Modify: `src/EndowmentNFT.sol`
- Create: `src/AutoPayoutEndowmentNFT.sol`
- Test: `test/AutoPayoutEndowmentNFT.t.sol`

**Interfaces:**
- Consumes: `EndowmentNFT` internals (`_endowments`, `_accrue`, `_nextId`, `token`).
- Produces (used by Tasks 2, 3, 4, 5, 9):

```solidity
contract AutoPayoutEndowmentNFT is EndowmentNFT {
    uint32 public constant DEFAULT_INTERVAL = 1 days;
    uint32 public constant MIN_INTERVAL = 1 hours;
    uint32 public constant MAX_INTERVAL = 365 days;

    event AutoPayoutSet(uint256 indexed tokenId, bool enabled, uint32 interval, uint128 fee);
    error InvalidInterval();
    error NotWethWrapper();

    constructor(IERC7984ERC20Wrapper wrapper_); // reads underlying() and rate(); reverts NotWethWrapper if underlying is the zero address
    function mintAuto(address to, externalEuint64 encEndowment, bytes calldata inputProof,
        Segment[] calldata segments, uint64 scheduleStart, bool topUpsAllowed, bytes32 name_,
        bool enabled, uint32 interval, uint128 fee) external returns (uint256 tokenId);
    function setAutoPayout(uint256 tokenId, bool enabled, uint32 interval, uint128 fee) external; // NotOwner, InvalidInterval
    function autoPayoutOf(uint256 tokenId) external view
        returns (bool enabled, uint32 interval, uint128 fee, uint64 lastRequestAt); // NonexistentToken
    function totalMinted() external view returns (uint256);
}
```

In `EndowmentNFT`, behaviour-preserving only: `_update` becomes `virtual`; the body of `mint` moves to `_mintEndowment(...) internal returns (uint256)`; the accrue-take-zero-allow sequence of `claim` moves to `_takeDistribution(uint256 tokenId, address reader) internal returns (euint64)`.

- [ ] **Step 1: Write the failing tests** in `test/AutoPayoutEndowmentNFT.t.sol` (extend `FhevmTest`; token is `ConfidentialWETH` over `MockWETH`, as in `test/ConfidentialWETH.t.sol`):
  - `test_mint_defaultsOffOneDayNoFee`: plain `mint` gives `autoPayoutOf == (false, 86400, 0, 0)` and emits `AutoPayoutSet(id, false, 86400, 0)` after `EndowmentMinted`.
  - `test_mintAuto_storesSettings`: `mintAuto(..., true, 7200, 5)` gives `(true, 7200, 5, 0)` and emits the event.
  - `test_mintAuto_rejectsInterval`: `3599` and `31536001` revert `InvalidInterval`; `3600` and `31536000` succeed.
  - `test_setAutoPayout_ownerOnly`: non-owner reverts `NotOwner`; owner sets and the event is emitted.
  - `test_setAutoPayout_rejectsInterval`, `test_autoPayoutOf_nonexistentReverts`.
  - `test_transfer_resetsEnabledKeepsIntervalAndFee`: after a transfer to another address `(false, 7200, 5, _)` and `AutoPayoutSet(id, false, 7200, 5)`.
  - `test_transfer_byApprovedOperator_resets`.
  - `test_transfer_toSelf_changesNothing`: no `AutoPayoutSet` emitted.
  - `test_totalMinted`.
  - `test_claim_stillWorks`: mint, warp, `claim`, decrypt the owner's cWETH balance.

- [ ] **Step 2: Run** `forge test --match-path test/AutoPayoutEndowmentNFT.t.sol`. Expected: compile failure, contract not found.

- [ ] **Step 3: Refactor `EndowmentNFT`** as described. Run `forge test --no-match-path test/AutoPayoutEndowmentNFT.t.sol` and `npx hardhat test`. Expected: all existing tests pass.

- [ ] **Step 4: Implement `AutoPayoutEndowmentNFT`** settings. The transfer reset goes in the `_update` override after `super._update`, for `from != 0 && to != 0 && from != to`.

- [ ] **Step 5: Run** `forge test`. Expected: all pass.

- [ ] **Step 6: Commit** `feat: AutoPayoutEndowmentNFT with per-token automatic payout settings`.

---

### Task 2: Requesting and finalising a payout

**Files:**
- Modify: `src/AutoPayoutEndowmentNFT.sol`, `src/mocks/MockWETH.sol` (only if a helper is missing)
- Test: `test/AutoPayoutEndowmentNFT.t.sol`, `test/AutoPayoutEndowmentNFT.hh.ts`

**Interfaces:**
- Consumes: Task 1; wrapper `unwrap(address,address,euint64)`, `finalizeUnwrap`, `unwrapRequester`, `rate`, `underlying`; `FHE.checkSignatures(bytes32[] handles, bytes cleartexts, bytes proof)`; test helper `buildDecryptionProof` in `lib/forge-fhevm/src/FhevmTest.sol`.
- Produces (used by Tasks 4, 5, 9):

```solidity
event PayoutRequested(uint256 indexed tokenId, bytes32 indexed requestId, address indexed recipient, address requester, uint128 fee);
event PayoutPaid(uint256 indexed tokenId, bytes32 indexed requestId, uint256 amountWei, uint256 feeWei, bool paidInWeth);
error AutoPayoutDisabled();
error PayoutPending();
error PayoutTooSoon(uint64 notBefore);
error ScheduleNotStarted();
error NothingLeft();
error FeeTooLow(uint128 fee);
error NoPendingPayout();
error OnlyWeth();

function requestPayout(uint256 tokenId, uint128 minFee) external returns (bytes32 requestId);
function finalizePayout(uint256 tokenId, uint64 cleartextAmount, bytes calldata decryptionProof) external;
function pendingPayoutOf(uint256 tokenId) external view
    returns (bytes32 requestId, address recipient, address requester, uint128 fee); // all zero when none
function payoutDue(uint256 tokenId) external view returns (bool); // false for a nonexistent token
function lastPayoutOf(uint256 tokenId) external view returns (uint64 paidAt, uint256 amountWei);
receive() external payable; // OnlyWeth unless msg.sender is the WETH contract
```

`requestPayout` order of checks: `NonexistentToken`, `AutoPayoutDisabled`, `PayoutPending`, `FeeTooLow`, `PayoutTooSoon` (when `lastRequestAt != 0 && now < lastRequestAt + interval`), `ScheduleNotStarted` (`now < scheduleStart`), `NothingLeft` (`lastRequestAt != 0 && lastRequestAt >= scheduleEnd`). Then `_takeDistribution(tokenId, ownerOf(tokenId))`, `FHE.allowTransient(amt, token)`, `wrapper.unwrap(address(this), address(this), amt)`, store pending, set `lastRequestAt = now`, emit.

`finalizePayout`: `NoPendingPayout`; `FHE.checkSignatures([requestId], abi.encode(cleartextAmount), proof)`; delete pending; if `wrapper.unwrapRequester(requestId) != address(0)` call `wrapper.finalizeUnwrap`; `amountWei = cleartextAmount * rate`; if non-zero, `weth.withdraw(amountWei)`, `feeWei = min(fee, amountWei / 10)`, pay requester then recipient with `call{value, gas: 100000}`; a failed requester payment is added to the recipient's share; a failed recipient payment is re-deposited and sent as WETH; record `lastPayoutOf`; emit. `nonReentrant`.

- [ ] **Step 1: Write the failing forge tests** (helpers: `RejectingReceiver` with no `receive`, `GasBurner` whose `receive` loops, `ReentrantReceiver` whose `receive` calls `finalizePayout`/`requestPayout`):
  - `test_request_revertsWhenDisabled`, `_whenPending`, `_tooSoon` (asserts `notBefore`), `_beforeScheduleStart`, `_feeTooLow`, `_nonexistent`.
  - `test_request_firstIsImmediate_thenWaitsInterval`.
  - `test_roundTrip_paysOwnerEth`: 1 unit/s for 1000 s, warp 100 s, request as `keeper`, build the proof for the request id, finalise; owner's ETH rises by `amount * 1e9`, `pendingPayoutOf` is zero, claimable decrypts to 0, `lastPayoutOf` matches, both events emitted.
  - `test_fee_paidToRequester_cappedAtTenPercent`: fee `1 ether` on a payout of `100 * 1e9` wei pays the requester `10 * 1e9` and the owner `90 * 1e9`; a fee of `1` pays exactly `1`.
  - `test_fee_andRecipient_snapshottedAtRequest`: after the request the owner sets fee 0 and transfers to bob; the old owner and the original fee are paid.
  - `test_finalize_afterThirdPartyFinalizedOnWrapper`: call `wrapper.finalizeUnwrap` first, then `finalizePayout` pays once.
  - `test_finalize_wrongCleartext_reverts`, `test_finalize_noPending_reverts`, `test_finalize_twice_reverts`.
  - `test_zeroPayout_clearsPending_paysNothing` (endowment 0 or request straight after a claim).
  - `test_recipientRejectsEth_paidInWeth` and `test_recipientBurnsGas_paidInWeth`: `paidInWeth == true`, WETH balance rises.
  - `test_requesterRejectsEth_feeGoesToRecipient`.
  - `test_reentrantRecipient_cannotReenter`.
  - `test_afterScheduleEnd_onePayoutThenNothingLeft`: leftover is paid by the first request at or after the end; the next request reverts `NothingLeft`; `payoutDue` is false.
  - `test_payoutDue_matchesRequest` across disabled, pending, too soon, due.
  - `test_receive_rejectsPlainEth`.
  - `test_shortfall_paysRemainder`: endowment 50, 100 owed, payout is 50.

- [ ] **Step 2: Run** `forge test --match-path test/AutoPayoutEndowmentNFT.t.sol`. Expected: the new tests fail to compile.

- [ ] **Step 3: Implement** `requestPayout`, `finalizePayout`, the reads and `receive`.

- [ ] **Step 4: Write `test/AutoPayoutEndowmentNFT.hh.ts`**, one test, `"request -> public decrypt -> finalise pays ETH"`, following `test/EndowmentNFT.hh.ts`: deploy `MockWETH`, `ConfidentialWETH`, `AutoPayoutEndowmentNFT`; wrap; `mintAuto` enabled; `time.increase(100)`; `requestPayout` from another signer; obtain cleartext and proof with the plugin's `fhevm.publicDecrypt([requestId])`; `finalizePayout`; assert the owner's ETH balance rose by `clear * 1e9`. This pins the plugin's decrypt result shape for Tasks 5 and 9.

- [ ] **Step 5: Run** `forge test` and `npx hardhat test`. Expected: all pass.

- [ ] **Step 6: Commit** `feat: anyone can request and finalise an automatic payout in ETH`.

---

### Task 3: Deployment

**Files:**
- Modify: `tasks/deployments.ts`, `tasks/deployGuard.ts`, `scripts/deploy.ts`, `web/e2e/global-setup.js`, `guides/running-locally.md`, `guides/sepolia-deployment.md`, `README.md`
- Test: `test/deployGuard.hh.ts`

**Interfaces:**
- Produces: `Deployment.nftKind?: "auto"` (absent means the existing type); a deployment entry `{label: "auto", tokenKind: "wrapped", nftKind: "auto", token: <same as wrapped>, underlying, nft, deployBlock}`;

```ts
// tasks/deployGuard.ts
export function autoToken(i: { tokenKind: string | undefined; tokenAddress: string | undefined; contracts: Deployment[] }):
  { token: string } | { refusal: string };
```

  Rules: `tokenKind` set and not `wrapped` refuses (`NFT_KIND=auto needs the wrapped token`); `tokenAddress` wins; else the entry labelled `wrapped`; else refuses (`No "wrapped" entry to share a token with. Deploy it first, or set TOKEN_ADDRESS.`).

- [ ] **Step 1: Write failing tests** for `autoToken` in `test/deployGuard.hh.ts`, one per rule.
- [ ] **Step 2: Run** `npx hardhat test test/deployGuard.hh.ts`. Expected: fail, `autoToken` not exported.
- [ ] **Step 3: Implement.** `scripts/deploy.ts` reads `NFT_KIND` (`standard` default, `auto`); for `auto` the token comes from `autoToken`, the underlying from the token's `underlying()` (as the reuse path does), the contract is `AutoPayoutEndowmentNFT`, the default label is `auto`, and the entry carries `nftKind: "auto"`. Every existing guard runs first. Document `NFT_KIND` in the header comment.
- [ ] **Step 4: Verify locally.** With `npx hardhat node` running on a free port: the two existing deploys, then `NFT_KIND=auto npx hardhat run scripts/deploy.ts --network localhost`. Expected: `Wrote deployments/localhost.json (label "auto")`, three entries, `auto.token == wrapped.token`. Running the auto deploy alone on a fresh node exits non-zero with the refusal. (If port 8545 is in use by the owner's node, use it rather than stopping it, and deploy with `LABEL` unchanged only if no `auto` entry exists.)
- [ ] **Step 5: Update** `web/e2e/global-setup.js` to deploy the third variant; `guides/running-locally.md` (third command; the file lists three entries); `guides/sepolia-deployment.md` (a new step after the wrapped deploy: `CONFIRM_DEPLOY=sepolia NFT_KIND=auto npx hardhat run scripts/deploy.ts --network sepolia`, expected output, and the table of labels); `README.md` deploy section.
- [ ] **Step 6: Run** `npx hardhat test`. Commit `feat: deploy the automatic-payout ENFT as a third entry sharing cWETH`.

---

### Task 4: Server: config, indexing, store

**Files:**
- Modify: `web/lib/annuart/chain/config.ex`, `web/lib/annuart/chain/abi.ex`, `web/lib/annuart/chain/reader.ex`, `web/lib/annuart/indexer.ex`, `web/lib/annuart/enfts.ex`, `web/lib/annuart/enfts/enft.ex`, `web/test/support/enft_fixtures.ex`, `web/test/support/rpc_stub.ex`
- Create: `web/lib/annuart/enfts/payout.ex`, `web/lib/annuart/enfts/big_uint.ex`, a migration via `mix ecto.gen.migration add_auto_payouts`
- Test: `web/test/annuart/chain/config_test.exs` (or where `load/1` is tested), `web/test/annuart/chain/abi_test.exs`, `web/test/annuart/indexer_test.exs`, `web/test/annuart/enfts_test.exs`

**Interfaces:**
- Consumes: event signatures from Tasks 1 and 2; `nftKind` from Task 3.
- Produces (used by Tasks 6, 7, 8):
  - `%Config.Contract{nft_kind: :standard | :auto}`; `Config.public/0` contracts carry `nftKind: "standard" | "auto"`.
  - `Annuart.Enfts.BigUint`: Ecto type, non-negative integer stored as decimal text.
  - `enfts` columns: `auto_enabled :boolean` (nil for standard), `auto_interval :integer`, `auto_fee BigUint`, `pending_request_id :string`.
  - `payouts` table / `Annuart.Enfts.Payout`: `enft_id`, `request_id`, `recipient`, `requester`, `fee_offered BigUint`, `requested_at`, `requested_block`, and nullable `amount_wei BigUint`, `fee_wei BigUint`, `paid_in_weth`, `paid_at`, `paid_block`, `tx_hash`; unique on `(enft_id, request_id)`.
  - `Enfts.record_auto_settings(%{nft, token_id, enabled, interval, fee})`, `Enfts.record_payout_requested(attrs)`, `Enfts.record_payout_paid(attrs)` (each upserts; `record_payout_paid` creates the row if the request was never seen), `Enfts.list_payouts(%Enft{})` newest first, `Enfts.last_payout(%Enft{})` (latest paid).
  - `Abi.topic(:auto_payout_set | :payout_requested | :payout_paid)` and matching `decode_log/1` results.
  - PubSub: the existing `{:enft_changed, label, token_id}` is broadcast for each of the three events.

- [ ] **Step 1: Write failing tests:**
  - Config: an entry with `"nftKind": "auto"` loads as `:auto`; without it `:standard`; any other value is `{:error, :invalid}`; `public/0` includes `nftKind`.
  - Abi: each new topic equals the keccak of its signature; a hand-built log of each event decodes to its fields (`fee`, `amountWei`, `feeWei` as integers).
  - Enfts: settings upsert; request then paid fills one row; paid without request creates one row; replaying both changes nothing; `pending_request_id` is set by a request and cleared by its paid event; `reset_contract/1` deletes payouts.
  - Indexer: logs for mint + `AutoPayoutSet` in one block give an ENFT with settings; `PayoutRequested` in one range and `PayoutPaid` in the next give one paid row; re-syncing the same ranges leaves one row; each event broadcasts `:enft_changed`.
- [ ] **Step 2: Run** `mix test test/annuart`. Expected: failures on the missing functions and fields.
- [ ] **Step 3: Implement.** The indexer adds the three topics to the filter it already uses for every contract; timestamps come from the block cache it already keeps. Amount fields are logged nowhere.
- [ ] **Step 4: Run** `mix ecto.migrate` then `mix precommit`. Expected: pass.
- [ ] **Step 5: Commit** `feat(web): index automatic payout settings and payouts`.

---

### Task 5: Browser chain layer

**Files:**
- Modify: `web/assets/js/chain/abi.js`, `web/assets/js/chain/actions.js`, `web/assets/js/hooks/tx_action.js`, `web/assets/js/errors.js`, `web/assets/js/units.js`
- Test: `web/assets/test/actions.local.test.js`, `web/assets/test/tx_action.test.js`, `web/assets/test/errors.test.js`, `web/assets/test/units.test.js`

**Interfaces:**
- Consumes: contract ABI from Tasks 1 and 2; `chainInfo().contracts[i].nftKind` from Task 4; `getFhe(s).publicDecrypt`.
- Produces (used by Tasks 7, 8):

```js
// units.js
export const INTERVAL_UNITS = {hours: 3600, days: 86400, weeks: 604800};
export function intervalSeconds(value, unit);   // whole number > 0, within 3600..31536000, else throws ScheduleError("bad_interval")
export function intervalText(seconds);          // "1 day", "36 hours", "2 weeks"; largest unit that divides evenly

// actions.js
createEnft(session, contract, {..., auto}, onStep)        // auto: {enabled, interval, fee} | undefined; mintAuto when contract.nftKind === "auto" and auto is given
setAutoPayout(session, contract, {tokenId, enabled, interval, fee}, onStep)   // steps "confirm", "mined"
triggerPayout(session, contract, {tokenId}, onStep)        // steps "requestPayout", "decrypt", "payOut", "mined"
finishPayout(session, contract, {tokenId}, onStep)         // steps "decrypt", "payOut", "mined"
autoPayoutStatus(session, contract, tokenId)               // requireChain; {enabled, interval, fee, lastRequestAt, due, pending: null | {requestId, recipient, requester, fee}, last: null | {paidAt, wei}}
```

  `interval` is a number of seconds, `fee` a bigint of wei. `triggerPayout` reads the fee and passes it as `minFee`. `triggerPayout` and `finishPayout` resolve to `{hash, wei, feeWei, paidInWeth, note}`; `note` is `"<x> ETH was paid to the owner."`, with `" <y> ETH went to you as the fee."` appended when the fee is non-zero and the caller was the requester, or `"There was nothing to pay out."` for zero. A failure after the request is mined carries `err.resume = {action: "finishPayout", args: {tokenId}}`. All four refuse a contract whose `nftKind` is not `"auto"`.

  `tx_action.js`: plans for the new actions and labels for the two new step ids (`requestPayout: "Request the payout"`, `payOut: "Pay out"`); both join `SENDING`; after a failure, `err.resume` (or the existing unwrap `err.requestId`) decides what the next click runs.

- [ ] **Step 1: Write failing tests.**
  - `units.test.js`: `intervalSeconds("1","days") === 86400`; `("0","hours")`, `("1.5","days")` and `("366","days")` throw `bad_interval`; `("1","hours")` and `("365","days")` pass; `intervalText(86400) === "1 day"`, `intervalText(129600) === "36 hours"`.
  - `errors.test.js`: the selector of each new custom error maps to a sentence (`PayoutTooSoon` → `"It is too soon for the next automatic payout."`, `AutoPayoutDisabled` → `"Automatic payouts are switched off for this ENFT."`, `PayoutPending` → `"A payout is already waiting to be finished."`, `NothingLeft` → `"This ENFT has paid out everything."`, `FeeTooLow` → `"The fee was lowered. Reload and try again."`, `InvalidInterval` → `"The interval must be between 1 hour and 365 days."`, `ScheduleNotStarted` → `"Payouts have not started yet."`, `NoPendingPayout` → `"This payout has already been finished."`).
  - `actions.local.test.js` (skipped when the deployment file has no `auto` entry): create with `auto` on reports settings through `autoPayoutStatus`; `triggerPayout` by another account raises the owner's ETH by `wei - feeWei` and the caller's by `feeWei` less gas; a second trigger at once fails with the too-soon sentence in the `requestPayout` step; with the caller's second transaction rejected the error carries `resume`, `autoPayoutStatus().pending` is set, and `finishPayout` by a third account completes it; `setAutoPayout` by a non-owner fails with the `NotOwner` sentence; `createEnft` without `auto` on the auto contract mints with payouts off; the four actions refuse the `wrapped` contract.
  - `tx_action.test.js`: a `triggerPayout` that throws with `resume` offers `Try again`, and the click runs `finishPayout` with `{tokenId}` and not `triggerPayout`; the note is shown; the pushed event has only `action`, `label`, `tokenId`, `hash`.
- [ ] **Step 2: Run** `node --test "assets/test/**/*.test.js"` from `web/` against a local node with all three variants deployed. Expected: the new tests fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the suite again. Expected: pass (the pre-existing `create -> accrue -> reveal -> claim on the mock token` test needs a fresh chain).
- [ ] **Step 5: Commit** `feat(web): browser actions for automatic payouts`.

---

### Task 6: Tokens page, one card per token

**Files:**
- Modify: `web/lib/annuart_web/live/tokens_live.ex`, `web/assets/js/hooks/tokens.js`
- Test: `web/test/annuart_web/live/tokens_live_test.exs`, `web/assets/test/tokens.test.js`, `web/e2e/flows.spec.js` (selectors only)

**Interfaces:**
- Consumes: `Config.contracts/0` with `nft_kind` (Task 4).
- Produces: one card per distinct token address, `id="token-<label of the first contract using it>"`, so existing ids `token-mock` and `token-wrapped` and everything inside them keep working. The card carries `data-labels` (all contract labels using the token, comma-separated). Balance, faucet, wrap, unwrap, pending unwraps and WETH act through the first label. The authorisation part renders one line per contract: its label, the state text and its own `Authorise` action with `id="tx-authorise-<label>"`.

- [ ] **Step 1: Write failing tests.** Server: with `wrapped` and `auto` sharing a token there is one `#token-wrapped`, no `#token-auto`, and `#tx-authorise-wrapped` and `#tx-authorise-auto` both inside it; `mock` is unchanged. JS: `TokensController` with two labels reads `operatorStatus` once per contract and renders two lines; a card with one label renders as before.
- [ ] **Step 2: Run** `mix test test/annuart_web/live/tokens_live_test.exs` and `node --test assets/test/tokens.test.js`. Expected: fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `mix precommit` and the JS suite. Commit `feat(web): one Tokens card per token, with an authorisation per contract`.

---

### Task 7: Create page

**Files:**
- Modify: `web/lib/annuart_web/live/create_live.ex`, `web/assets/js/hooks/create_form.js`
- Test: `web/test/annuart_web/live/create_live_test.exs`, `web/assets/test/create_form.test.js`

**Interfaces:**
- Consumes: `createEnft(..., {auto})`, `intervalSeconds`, `intervalText`, `INTERVAL_UNITS` (Task 5); `nft_kind` (Task 4).
- Produces: each token option carries `data-nft-kind`; an auto contract's option reads `<label> (<symbol>, automatic payouts)`. Markup inside the Options panel: `[data-role=auto]` (hidden unless the selected option is auto) containing `[data-role=auto-enabled]` (checkbox, checked), `[data-role=auto-interval]` (value `1`), `[data-role=auto-interval-unit]` (`hours`, `days` selected, `weeks`), `[data-role=auto-fee]` (value `0`, ETH), `[data-role=auto-fee-echo]`, and a note with this exact text: `Anyone can trigger these payouts, and you receive them as plain ETH. Each automatic payout amount is public. If the ENFT ever runs out, that reveals how much it held in total.`

- [ ] **Step 1: Write failing tests.**
  - Server: the auto option has `data-nft-kind="auto"` and the wording above; the group and note are rendered.
  - JS: the group is hidden for a standard contract and `args.auto` is `undefined`; shown for auto with defaults giving `auto = {enabled: true, interval: 86400, fee: 0n}`; unticking gives `enabled: false`; interval `"0"` or `400` days stops validation with `"The interval must be between 1 hour and 365 days."`; a fee of `"1,5"` stops with the amount message; the summary contains `Automatic payouts are on, at most once every 1 day, with no fee.` (or `with a fee of up to 0.001 ETH per payout, never more than 10% of it.`), and `Automatic payouts are off.` when unticked; a fee above 10% of one interval's scheduled payout shows `The fee is capped at 10% of each payout.` in `[data-role=auto-fee-echo]`.
- [ ] **Step 2: Run** both test files. Expected: fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `mix precommit` and the JS suite. Commit `feat(web): automatic payout settings on the Create form`.

---

### Task 8: ENFT page, Browse and My ENFTs

**Files:**
- Create: `web/assets/js/hooks/auto_payout.js`
- Modify: `web/assets/js/app.js`, `web/lib/annuart_web/live/enft_live.ex`, `web/lib/annuart_web/live/browse_live.ex`, `web/lib/annuart_web/live/my_enfts_live.ex`, `web/lib/annuart_web/components/enft_components.ex`, `web/assets/css/app.css`
- Test: `web/assets/test/auto_payout.test.js`, `web/test/annuart_web/live/enft_live_test.exs`, `web/test/annuart_web/live/browse_live_test.exs`, `web/test/annuart_web/live/my_enfts_live_test.exs`

**Interfaces:**
- Consumes: Task 4 store (`auto_enabled`, `auto_interval`, `auto_fee`, `Enfts.list_payouts/1`, `Enfts.last_payout/1`); Task 5 actions and `StepList` from `tx_action.js`.
- Produces:
  - `EnftComponents.auto_badge/1`: renders `Automatic` for an ENFT with `auto_enabled == true`, nothing otherwise; used in Browse and My ENFTs rows and the ENFT page heading area.
  - ENFT page, auto contracts only, `#panel-auto` (public, server-rendered from the index): `On` or `Off`; `At most once every <interval>`; `Fee: <x> ETH per payout, never more than 10% of it` or `No fee`; `Last automatic payout: <amount> ETH on <date>` or `None yet`.
  - Inside it `#auto-payout`, `phx-hook="AutoPayout"`, `phx-update="ignore"`, `data-label`, `data-token-id`, `data-owner` (`"true"` for the connected owner). `AutoPayoutController(el, deps)` follows `TokensController`'s shape (deps: `session`, `contract`, `actions`, `push`, `announce`, `confirm`, `now`). It reads `autoPayoutStatus` when a wallet is connected and on `annuart:tx`, and renders: a state line (`A payout can be triggered now.` / `Next payout possible <date and time>.` / `A payout is waiting to be finished.` / nothing when off); `Trigger payout` (`data-role="trigger"`, only when due) with the line `You pay the transaction fees.` plus ` You receive up to <fee> ETH as the fee.` when the fee is non-zero; `Finish payout` (`data-role="finish"`, only when pending); for the owner, a settings form: `[data-role=set-enabled]`, `[data-role=set-interval]`, `[data-role=set-interval-unit]`, `[data-role=set-fee]`, `Save` (`data-role="save"`), prefilled from the status, with the Task 7 privacy note shown next to the checkbox. Saving with `enabled` going from off to on first asks `Switch automatic payouts on? Each payout amount becomes public.` Each action reports into an `ol.steps` and pushes `tx:confirmed` with `{action, label, tokenId, hash}` only.
  - History on the ENFT page lists each paid payout as `Automatic payout of <amount> ETH` with its date, `(paid in WETH)` when so, and `fee <y> ETH` when non-zero, merged by time with transfers.
  - `Claim` and `Claim and convert to ETH` stay as they are (the auto entry's token kind is wrapped).

- [ ] **Step 1: Write failing tests.**
  - `auto_payout.test.js` (linkedom, stubbed deps): due → `trigger` present, `finish` absent, fee line as specified; pending → `finish` only; too soon → the next-possible line and neither button; off and not owner → no buttons; owner → form prefilled (`86400` shows as `1` `days`); `Save` calls `setAutoPayout` with seconds and wei; switching on asks first and a declined question sends nothing; an invalid interval shows the message and sends nothing; a `triggerPayout` failure carrying `resume` turns the next click into `finishPayout`; the action's `note` is shown; no wallet → `Connect a wallet to trigger a payout.`; a status read that throws shows `Automatic payout status is unavailable.` and no buttons.
  - `enft_live_test.exs`: `#panel-auto` only for an auto contract; settings and last payout from the store; `data-owner` only for the owner; history lines; a standard contract's page is unchanged.
  - Browse and My ENFTs: the badge appears only for `auto_enabled == true`.
- [ ] **Step 2: Run** the listed tests. Expected: fail.
- [ ] **Step 3: Implement**, registering the hook in `app.js`.
- [ ] **Step 4: Run** `mix precommit` and the JS suite. Then open the page in a browser against the local chain (dev login) and check the panel at desktop and phone width; fix what reads badly.
- [ ] **Step 5: Commit** `feat(web): automatic payout panel, trigger and settings on the ENFT page`.

---

### Task 9: Keeper script

**Files:**
- Create: `tasks/keeper.ts`, `scripts/keeper.ts`, `guides/keeper.md`
- Test: `test/keeper.hh.ts`

**Interfaces:**
- Consumes: `totalMinted`, `payoutDue`, `pendingPayoutOf`, `lastPayoutOf`, `autoPayoutOf`, `requestPayout`, `finalizePayout`; `readDeployments`; `deployRefusal`-style confirmation; the plugin's `fhevm.publicDecrypt` (shape pinned in Task 2 Step 4).
- Produces:

```ts
// tasks/keeper.ts
export type KeeperToken = { tokenId: bigint; pending: boolean; due: boolean; lastPaidZero: boolean };
export function keeperPlan(tokens: KeeperToken[], opts: { includeDry: boolean }): { finish: bigint[]; request: bigint[] };
export function keeperRefusal(i: { network: string; isLocal: boolean; confirm: string | undefined }): string | null;
```

  `finish` is every pending token. `request` is every due, non-pending token, minus those with `lastPaidZero` unless `includeDry`. `lastPaidZero` means `lastPayoutOf` has `paidAt != 0 && amountWei == 0`. `keeperRefusal` requires `CONFIRM_KEEPER` to equal the network name off the local chain.

  `scripts/keeper.ts`: one pass over every `nftKind: "auto"` entry; finish first, then request, then finish what it just requested; each transaction is printed as it is sent; a failure on one token is printed (RPC URL redacted, as `scripts/deploy.ts` does) and the pass continues; exit code 1 if any failed. Env: `KEEPER_INCLUDE_DRY=1`, `CONFIRM_KEEPER`.

- [ ] **Step 1: Write failing tests** in `test/keeper.hh.ts`: `keeperPlan` cases (pending only; due; due and dry excluded; due and dry with `includeDry`; pending and due together appears only in `finish`); `keeperRefusal` (local passes; public without confirmation refuses; with it passes); one integration test on the in-process Hardhat network that mints two automatic ENFTs, advances time, runs the pass function, and sees both owners paid.
- [ ] **Step 2: Run** `npx hardhat test test/keeper.hh.ts`. Expected: fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Write `guides/keeper.md`:** what it does, that whoever runs it pays the gas and receives any fees, the throwaway-key advice from the deployment guide (`read -s`, never in a file, `unset` afterwards), the local command, the Sepolia command with `CONFIRM_KEEPER=sepolia`, a cron example, and that it is the owner who runs it on Sepolia.
- [ ] **Step 5: Run** `npx hardhat test`. Commit `feat: keeper script that triggers due automatic payouts`.

---

### Task 10: End to end, checklist, final verification

**Files:**
- Modify: `web/e2e/flows.spec.js`, `web/docs/manual-checklist.md`, `README.md`

- [ ] **Step 1: Add the Playwright flow** `"automatic ENFT: created by one account, triggered by another, owner is paid in ETH"`: account 1 wraps ETH, creates on the `auto` contract with defaults (asserting the summary sentence from Task 7), lands on the page with `#panel-auto` showing `On`; switch to account 2, wait for `Trigger payout`, run it through `Done`; assert the note `ETH was paid to the owner.`, that History gains an `Automatic payout of` line, that `Trigger payout` is gone and the next-possible line is shown, and (through the page's provider) that account 1's ETH balance rose. Add to the existing no-amount-leak flow that creating on the auto contract sends no endowment amount.
- [ ] **Step 2: Run** `npx playwright test` from `web/e2e` with ports 8545 and 4000 free. Expected: all flows pass. If the owner's chain or app is running, do not stop it: say so and leave this step for when the ports are free.
- [ ] **Step 3: Add a checklist section** to `web/docs/manual-checklist.md` for the Sepolia pass: create an automatic ENFT; see the panel; trigger from a second account and watch all steps; check the owner's ETH and the public amount on Etherscan; change the settings; switch off and see `Trigger payout` go; transfer and see it reset to off; the Tokens page shows one cWETH card with two authorisations.
- [ ] **Step 4: Update `README.md`:** the new contract, its functions and events, the privacy cost (spec section 3), `NFT_KIND`, the keeper.
- [ ] **Step 5: Full verification.** `forge test`; `npx hardhat test`; in `web/`: `mix precommit`, `node --test "assets/test/**/*.test.js"` against a fresh local chain with all three variants; Playwright as in Step 2. Report each result as run.
- [ ] **Step 6: Commit** `test(web): end-to-end automatic payout flow; docs`.
