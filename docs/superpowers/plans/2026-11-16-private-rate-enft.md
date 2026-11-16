# Private-rate ENFT Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a third ENFT type, `PrivateRateEndowmentNFT`, whose payout rate is encrypted, and offer it as one more option in the web app.

**Architecture:** The new contract inherits from `EndowmentNFT`, overrides `_accrue` to multiply a public weighted time by one encrypted fixed-point rate, and blocks the inherited `mint`. The server learns only the public shape (weights and lengths); the base rate is encrypted and decrypted in the browser.

**Tech Stack:** Solidity 0.8.24 on Zama FHEVM (`@fhevm/solidity` 0.11.1), Foundry with `forge-fhevm`, Hardhat with the FHEVM mock, Phoenix LiveView, ethers v6, node:test, Playwright.

**Spec:** `docs/superpowers/specs/2026-11-16-private-rate-enft-design.md`

## Global Constraints

- Work on a branch, `feat/private-rate-enft`. Never commit on `main`. Never push.
- The only edits to existing Solidity files: `virtual` on `EndowmentNFT.mint` and `EndowmentNFT._accrue`, and one NatSpec note on `EndowmentNFT`. `AutoPayoutEndowmentNFT.sol`, `ConfidentialWETH.sol` and `Schedule.sol` are not edited. No existing contract test is edited.
- The base rate, and any amount derived from it, never reaches the server, a log or the socket. It lives only in the browser and, encrypted, on chain.
- The app never shows a weight as a token amount, and never calls this type "fully private".
- `UNIT_SHIFT = 32`. `MAX_WEIGHT = type(uint32).max` (4294967295). 100% of base is weight 1000.
- Function name `mintPrivate`, selector `0x16a610e7`. Errors `WeightTooLarge()` `0xe5f127cc`, `RateRequired()` `0x72783940`. Deployment value `"nftKind": "private"`.
- Hardhat tests run on the default in-process network only. Never `--network localhost` or `sepolia`, never `npx hardhat node`. Run `npx hardhat compile` before `npx hardhat test` after any contract change.
- Never stop, start or restart anything on ports 8545 or 4000. Never read `.env`. No Sepolia transaction.
- `web/assets/test/actions.local.test.js` and `web/e2e` talk to the owner's chain or start servers. Write those tests, but run them only after the owner says so (Task 9).
- In `web/`: `mix format --check-formatted` stays clean; no apostrophes in HEEx text that a test matches.
- Commit message trailer: `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`.

## Review Focus

1. **Frequent `accrue` calls on a small rate.** A stranger calls `accrue` every second on a rate below one base unit per second. The owner must still receive the full amount. Test in Task 1.
2. **A recipient contract that acts during mint.** Its receive callback calls `accrue` on a schedule that started in the past. No payout may be lost. Test in Task 2.
3. **The inherited `mint` on the new contract.** It must revert and mint nothing. Test in Task 1.
4. **Largest inputs.** `unit = 2^64 - 1`, weights at `MAX_WEIGHT`, decades of elapsed time: no revert, never more than the endowment. Test in Task 2.
5. **A percentage the form cannot represent.** "12.55", a negative number, an empty field, or a value above 429496729.5 must be refused in the browser with a message, before anything is encrypted. Test in Task 6.

## File Structure

| File | Responsibility |
|---|---|
| `src/PrivateRateEndowmentNFT.sol` (new) | The contract |
| `src/EndowmentNFT.sol` | Two `virtual` keywords, one NatSpec note |
| `test/PrivateRateEndowmentNFT.t.sol` (new) | Foundry tests |
| `test/PrivateRateEndowmentNFT.hh.ts` (new) | Hardhat test: who can decrypt the rate |
| `scripts/deploy.ts`, `tasks/deployments.ts`, `test/deployGuard.hh.ts` | `NFT_KIND=private` |
| `web/lib/annuart/chain/config.ex`, `txs.ex`, `indexer.ex` | The new kind on the server |
| `web/lib/annuart/schedule.ex`, `components/enft_components.ex`, the four list/detail LiveViews | Weight-aware display |
| `web/assets/js/units.js` | Percent, weight and fixed-point maths |
| `web/assets/js/chain/abi.js`, `fhe.js`, `actions.js`, `errors.js`, `hooks/secret_value.js` | Mint, reveal, error text |
| `web/assets/js/hooks/create_form.js`, `web/lib/annuart_web/live/create_live.ex` | The Create page |
| `guide_live.ex`, `guides/keeping-the-endowment-private.md`, `README.md`, `web/docs/manual-checklist.md` | Documentation |

---

### Task 1: The contract, minting and accrual

**Files:**
- Create: `src/PrivateRateEndowmentNFT.sol`, `test/PrivateRateEndowmentNFT.t.sol`
- Modify: `src/EndowmentNFT.sol` (lines 60 and 276: add `virtual`; NatSpec above the contract)

**Interfaces:**
- Produces:
  ```solidity
  contract PrivateRateEndowmentNFT is EndowmentNFT {
      uint8 public constant UNIT_SHIFT = 32;
      uint64 public constant MAX_WEIGHT = type(uint32).max;
      error WeightTooLarge();
      error RateRequired();
      constructor(IERC7984 token_);
      function mintPrivate(address to, externalEuint64 encEndowment, externalEuint64 encUnit,
          bytes calldata inputProof, Segment[] calldata segments, uint64 scheduleStart,
          bool topUpsAllowed, bytes32 name_) external nonReentrant returns (uint256 tokenId);
      function mint(address, externalEuint64, bytes calldata, Segment[] calldata, uint64, bool, bytes32)
          external pure override returns (uint256); // always reverts RateRequired
      function unitHandle(uint256 tokenId) external view returns (euint128);
  }
  ```
  State: `struct Rate { euint128 unit; euint128 carry; }` in `mapping(uint256 => Rate) internal _rates`.

- [ ] **Step 1: Write the failing tests** in `test/PrivateRateEndowmentNFT.t.sol`, a `FhevmTest` like `test/EndowmentNFT.t.sol`. Helper `_mintPrivate(to, amount, unit, segs, start)` funds `creator`, sets the operator, and encrypts both values with one proof:

  ```solidity
  uint256[] memory vals = new uint256[](2); vals[0] = amount; vals[1] = unit;
  FheType[] memory types = new FheType[](2); types[0] = FheType.Uint64; types[1] = FheType.Uint64;
  (bytes32[] memory h, bytes memory proof) = encrypt(vals, types, creator, address(nft));
  vm.prank(creator);
  id = nft.mintPrivate(to, externalEuint64.wrap(h[0]), externalEuint64.wrap(h[1]), proof, segs, start, false, bytes32(0));
  ```

  With `ONE = uint64(1) << 32`:

  ```solidity
  function test_mintPrivate_storesScheduleAndEmits()   // scheduleOf returns the weights; EndowmentMinted(1, creator, alice, start, false, 0)
  function test_inheritedMint_reverts()                // vm.expectRevert(RateRequired.selector); then vm.expectRevert(NonexistentToken.selector) on nameOf(1)
  function test_emptyProof_reverts()                   // EmptyInputProof
  function test_weightAboveMax_reverts()               // weight 2**32 -> WeightTooLarge; weight 2**32-1 mints
  function test_zeroWeightIndefinite_reverts()         // ZeroRateIndefiniteSegment
  function test_paysUnitTimesWeightedTime()            // unit ONE, {1000 s, weight 1}, endow 5000: warp +400, accrue -> distribution 400
  function test_weightsScaleThePayout()                // unit ONE, {100 s, w 1},{100 s, w 3}, endow 5000: warp +150 -> 100 + 150 = 250
  function test_fractionalUnit()                       // unit 49710269629, {1000 s, w 1000}, endow 10**9: warp +100 -> 1157407
  function test_cappedByEndowment()                    // unit ONE, {1000 s, w 1}, endow 300: warp +400 -> 300
  function test_fixedEndReleasesLeftover()             // unit ONE, {100 s, w 1}, endow 500: warp +100, accrue -> 500, settledOf true
  function test_zeroWeightPeriodPaysNothing()          // {100 s, w 0},{100 s, w 1}: warp +100 -> 0; warp +50 more -> 50
  function test_zeroUnit_paysNothingUntilEnd()         // unit 0, {100 s, w 1}, endow 500: warp +50 -> 0; warp +50 -> 500
  function test_frequentAccrualLosesNothing()          // unit ONE/2, indefinite w 1, endow 1000: 10 times {warp +1; vm.prank(bob); accrue} -> 5
  function test_halfUnitSingleSecondCarries()          // unit ONE/2: warp +1, accrue -> 0; warp +1, accrue -> 1
  function test_claimPaysOwner()                       // after test_paysUnitTimesWeightedTime setup: alice claims, her token balance is 400
  ```

  Read amounts with `decrypt(nft.distributionHandle(id))`.

- [ ] **Step 2: Run** `forge test --match-path test/PrivateRateEndowmentNFT.t.sol`. Expected: compile failure, `PrivateRateEndowmentNFT` not found.

- [ ] **Step 3: Edit `EndowmentNFT.sol`.** `function mint(...) external virtual nonReentrant` and `function _accrue(uint256 tokenId) internal virtual`. Add above `contract EndowmentNFT`: `/// @dev PrivateRateEndowmentNFT inherits this contract and reads Segment.ratePerSec as a weight, with the rate encrypted. A change here that treats ratePerSec as an amount must be checked against it.`

- [ ] **Step 4: Run** `forge test --no-match-path test/PrivateRateEndowmentNFT.t.sol`. Expected: every existing test passes.

- [ ] **Step 5: Implement the contract.** `mintPrivate`, in this order: revert `EmptyInputProof` on an empty proof; revert `WeightTooLarge` if any `segments[i].ratePerSec > MAX_WEIGHT`; `uint256 id = _nextId + 1`; store `unit = FHE.asEuint128(FHE.fromExternal(encUnit, inputProof))` with `allowThis`, `allow(msg.sender)`, `allow(to)`; store `carry = FHE.asEuint128(0)` with `allowThis`; `tokenId = _mintEndowment(...)`; `assert(tokenId == id)`.

  `_accrue` override. The settled and past-the-end branches are the same statements as the base (copy them; the base body cannot be called for one branch only). The paying branch:

  ```solidity
  uint64 w = Schedule.integrate(e.schedule, e.scheduleStart, e.lastAccrualAt, nowTs);
  if (w == 0) return;
  Rate storage r = _rates[tokenId];
  euint128 acc = FHE.add(FHE.mul(r.unit, uint128(w)), r.carry);
  r.carry = FHE.and(acc, uint128(type(uint32).max));
  euint64 actual = FHE.asEuint64(FHE.min(FHE.shr(acc, UNIT_SHIFT), FHE.asEuint128(e.endowmentRemaining)));
  e.endowmentRemaining = FHE.sub(e.endowmentRemaining, actual);
  e.distribution = FHE.add(e.distribution, actual);
  FHE.allowThis(r.carry);
  FHE.allowThis(e.endowmentRemaining);
  FHE.allowThis(e.distribution);
  FHE.allow(e.distribution, ownerOf(tokenId));
  e.lastAccrualAt = nowTs;
  ```

  NatSpec on the contract: what stays public, that `ratePerSec` is a weight, that a zero unit cannot be refused.

- [ ] **Step 6: Run** `forge test`. Expected: all pass.

- [ ] **Step 7: Commit** `feat(contracts): PrivateRateEndowmentNFT, an ENFT with an encrypted payout rate`.

---

### Task 2: Transfers, the mint callback, extremes and cost

**Files:**
- Modify: `src/PrivateRateEndowmentNFT.sol` (`_update` override)
- Test: `test/PrivateRateEndowmentNFT.t.sol`

**Interfaces:**
- Consumes: Task 1's contract and `_mintPrivate` helper.
- Produces: `_update(address to, uint256 tokenId, address auth) internal override returns (address from)`; on a real transfer it also does `FHE.allow(_rates[tokenId].unit, to)`.

- [ ] **Step 1: Write the failing tests.** Helper contract `AccruingReceiver` whose `onERC721Received` calls `PrivateRateEndowmentNFT(msg.sender).accrue(tokenId)` and returns the selector; it also exposes `claim(nft, id)`.

  ```solidity
  function test_newOwnerIsAllowedTheUnit()        // mint to alice; alice transfers to bob; acl.isAllowed(unitHandle, bob) true, and still true for alice and creator; false for address(0xBAD)
  function test_carryAndRemainingStayContractOnly() // isAllowed(endowmentHandle, alice|creator) false after mint, accrue and transfer
  function test_transferSettlesAndHandsOverDistribution() // unit ONE: warp +100, transfer to bob; bob claims 100; alice cannot decrypt the new distribution handle
  function test_receiverAccruingDuringMintLosesNothing()  // start = block.timestamp - 100, unit ONE, indefinite w 1, endow 1000, to = AccruingReceiver; then accrue; distribution == 100
  function test_extremeInputsNeverOverpay()       // unit type(uint64).max, {indefinite, w MAX_WEIGHT}, endow 1000: warp +60 * 365 days, accrue -> 1000, no revert
  function test_costWithinLimits()                // mintPrivate, accrue, claim, topUp and transferFrom each in turn on one token, default limits, none reverts
  ```

  Use the ACL the same way the existing tests in `test/redteam/Confidentiality.t.sol` do. `test_costWithinLimits` must not call `disableHCUDepthLimit()`. If the harness counts a whole test as one transaction and the depth limit trips for that reason, split it into one test per operation and say so in the commit message; do not relax the limit.

- [ ] **Step 2: Run** `forge test --match-path test/PrivateRateEndowmentNFT.t.sol`. Expected: `test_newOwnerIsAllowedTheUnit` fails (bob not allowed); note which others already pass.

- [ ] **Step 3: Implement `_update`**: `from = super._update(to, tokenId, auth); if (from != address(0) && to != address(0)) FHE.allow(_rates[tokenId].unit, to);`

- [ ] **Step 4: Run** `forge test`, then `npx hardhat compile && npx hardhat test`. Expected: all pass.

- [ ] **Step 5: Commit** `feat(contracts): private-rate ENFT hands the rate to a new owner; limits and callback tests`.

---

### Task 3: Hardhat decryption test and deployment

**Files:**
- Create: `test/PrivateRateEndowmentNFT.hh.ts`
- Modify: `scripts/deploy.ts`, `tasks/deployments.ts:9`, `test/deployGuard.hh.ts` or `test/redteam/deploy.hh.ts` (whichever tests `NFT_KIND` handling today)

**Interfaces:**
- Produces: `Deployment.nftKind?: "auto" | "private"`. `NFT_KIND=private` deploys `PrivateRateEndowmentNFT` over a token chosen by `TOKEN_KIND` exactly as the standard kind does; default label `private-<tokenKind>` for mock, `private` for wrapped; the entry carries `nftKind: "private"`.

- [ ] **Step 1: Write the failing Hardhat test.** Deploy `MockConfidentialToken` and `PrivateRateEndowmentNFT`; creator mints to alice with `fhevm.createEncryptedInput(nftAddr, creator.address).add64(500).add64(2n ** 32n).encrypt()`, passing `handles[0]`, `handles[1]` and segments `[{ duration: 1000, ratePerSec: 1 }]`. Assert:
  - `fhevm.userDecryptEuint(FhevmType.euint128, await nft.unitHandle(1), nftAddr, creator)` equals `2n ** 32n`, and the same for alice;
  - the same call for a third signer rejects;
  - after `time.increase(100)` and `accrue`, alice decrypts a distribution between 100 and 105;
  - after alice transfers to bob, bob decrypts the unit.

- [ ] **Step 2: Run** `npx hardhat compile && npx hardhat test test/PrivateRateEndowmentNFT.hh.ts`. Expected: pass if Tasks 1 and 2 are right. A failure here is a contract defect: fix the contract, not the test.

- [ ] **Step 3: Write the failing deploy test**: `NFT_KIND=private` is accepted, `NFT_KIND=secret` is refused with `NFT_KIND must be standard, auto or private (got "secret")`, and the label defaults are as above. Follow the shape of the existing `NFT_KIND=auto` tests.

- [ ] **Step 4: Run it.** Expected: fail on the message text.

- [ ] **Step 5: Implement** in `scripts/deploy.ts` and `tasks/deployments.ts`. Update the header comment of `deploy.ts`.

- [ ] **Step 6: Run** `npx hardhat test`. Expected: all pass.

- [ ] **Step 7: Commit** `feat(deploy): NFT_KIND=private deploys the private-rate ENFT`.

---

### Task 4: The new kind on the server

**Files:**
- Modify: `web/lib/annuart/chain/config.ex` (lines 24, 33), `web/lib/annuart/txs.ex` (lines 21-46, 111), `web/lib/annuart/indexer.ex:351`, `web/lib/annuart_web/live/transactions_live.ex:59`
- Test: `web/test/annuart/chain/` config test, `web/test/annuart/txs_test.exs`, `web/test/annuart/indexer_test.exs`, `web/test/annuart_web/live/transactions_live_test.exs`

**Interfaces:**
- Produces: `Config.Contract.nft_kind :: :standard | :auto | :private`; transaction kind `"create_private"` for selector `0x16a610e7`, in the private list, labelled "Create private-rate ENFT"; the browser config carries `nftKind: "private"`.

- [ ] **Step 1: Write the failing tests.**
  - Config: a deployments entry with `"nftKind": "private"` loads with `nft_kind: :private`; `"nftKind": "secret"` is still refused.
  - Txs: `describe/3` of a call with input starting `0x16a610e7` to the contract's `nft` gives `kind: "create_private"` and the token id from the `EndowmentMinted` log; `Txs.private?("create_private")` is true.
  - Indexer: a `:private` contract indexes a mint (schedule stored as read), and ignores automatic-payout events as `:standard` does.
  - Transactions page: the row reads "Create private-rate ENFT" and "Private".

- [ ] **Step 2: Run** `mix test` for those four files. Expected: the new tests fail.

- [ ] **Step 3: Implement.**

- [ ] **Step 4: Run** `mix format --check-formatted && mix test`. Expected: all pass.

- [ ] **Step 5: Commit** `feat(web): index the private-rate ENFT contract`.

---

### Task 5: Showing a private-rate ENFT

**Files:**
- Modify: `web/lib/annuart/schedule.ex`, `web/lib/annuart_web/components/enft_components.ex` (`schedule_table`), `web/lib/annuart_web/live/enft_live.ex`, `browse_live.ex:75-77`, and the summary callers in `my_enfts_live.ex` and `market_live.ex`
- Test: `web/test/annuart/schedule_test.exs`, `enft_live_test.exs`, `browse_live_test.exs`, `my_enfts_live_test.exs`, `market_live_test.exs`

**Interfaces:**
- Produces:
  ```elixir
  @spec Schedule.share_text(non_neg_integer) :: String.t()   # 1000 -> "100%", 125 -> "12.5%", 0 -> "0%"
  @spec Schedule.private_summary([map] | nil) :: String.t()  # nil -> "Schedule unavailable"; "Rate hidden, 1 period"; "Rate hidden, 3 periods"; indefinite last -> "Rate hidden, 3 periods, indefinitely"
  ```
  `schedule_table` gains `attr :private, :boolean, default: false`. When set, the columns are Period, Length, "Share of base rate" and nothing else.
  The ENFT page renders, for a `:private` contract and a viewer who is the creator or the owner:
  ```heex
  <span id={"rate-#{@enft.label}-#{@enft.token_id}"} phx-hook="SecretValue" phx-update="ignore"
        data-secret="rate" data-label={@enft.label} data-id={@enft.token_id}
        data-decimals={...} data-symbol={...}></span>
  ```

- [ ] **Step 1: Write the failing tests.**
  - `share_text` and `private_summary` with the values above.
  - ENFT page, `:private` contract with schedule `[%{duration: 8_640_000, rate_per_sec: 1000}, %{duration: 8_640_000, rate_per_sec: 500}]`: the schedule panel contains "Share of base rate", "100%" and "50%"; it contains neither "/ day" nor "Up to"; a "Base rate" row shows "Hidden" for a stranger and the `SecretValue` span (`data-secret="rate"`) for the owner and for the creator; no automatic-payout panel.
  - ENFT page, `:private`, schedule with no end, donations open: the donate panel contains "A donor cannot check that this ENFT pays anything."
  - Browse, Mine and Market cards for a `:private` ENFT show "Rate hidden, 2 periods" and no "/ day".
  - A `:standard` ENFT page is unchanged (existing tests stay green untouched).

- [ ] **Step 2: Run** those test files. Expected: the new tests fail.

- [ ] **Step 3: Implement.** Every call to `Schedule.summary/2`, `Schedule.per_day/2`, `Schedule.total/1` and the `max_payable` column must be behind a check that the contract is not `:private`. The chart keeps using `rate_per_sec` for relative bar heights.

- [ ] **Step 4: Run** `mix format --check-formatted && mix test`. Expected: all pass.

- [ ] **Step 5: Commit** `feat(web): show a private-rate ENFT without amounts`.

---

### Task 6: Browser maths

**Files:**
- Modify: `web/assets/js/units.js`
- Test: `web/assets/test/units.test.js`

**Interfaces:**
- Produces:
  ```js
  export const UNIT_SHIFT = 32n;
  export const BASE_WEIGHT = 1000n;                 // 100%
  export const MAX_WEIGHT = 4294967295n;
  export function percentToWeight(text)             // -> bigint; throws ScheduleError("bad_percent")
  export function baseUnit(amountText, per, decimals) // -> bigint unit; throws AmountError("rate_rounds_to_zero") or AmountError("too_large")
  export function toWeightSegments(rows)            // rows: {length, unit, indefinite, percent} -> [{duration, ratePerSec: weight}]
  export function effectiveSegments(segments, unit) // -> [{duration, ratePerSec: unit * weight >> 32}] for the browser's own warnings
  export function unitPerDay(unit, decimals, options) // -> string, unit * 1000 * 86400 >> 32 formatted
  ```
  `ScheduleError` messages gain `bad_percent` ("Enter a percentage with at most one decimal place.") and `zero_percent_indefinite` ("A period with no end must pay more than 0%.").

- [ ] **Step 1: Write the failing tests.**
  ```js
  percentToWeight("100") === 1000n; percentToWeight("12.5") === 125n; percentToWeight("0") === 0n;
  percentToWeight(" 250 ") === 2500n; percentToWeight("429496729.5") === 4294967295n;
  // each throws ScheduleError with code "bad_percent":
  "12.55", "-1", "", "abc", "1e3", "429496729.6"
  baseUnit("1", "day", 9) === 49710269629n;
  baseUnit("0.5", "week", 9) === 3550733544n;
  baseUnit("0.000000001", "year", 9)   // throws AmountError "rate_rounds_to_zero"
  unitPerDay(49710269629n, 9) === "0.999999999";
  unitPerDay(1n << 32n, 0) === "86,400,000";
  toWeightSegments([{length: "100", unit: "days", percent: "100"}, {indefinite: true, percent: "50"}])
    // -> [{duration: 8640000n, ratePerSec: 1000n}, {duration: U64_MAX, ratePerSec: 500n}]
  toWeightSegments([{indefinite: true, percent: "0"}])  // throws ScheduleError "zero_percent_indefinite"
  toWeightSegments(257 rows)                            // throws ScheduleError "too_many"
  effectiveSegments([{duration: 100n, ratePerSec: 1000n}], 49710269629n)[0].ratePerSec === 11574n;
  ```
  `baseUnit` throws `too_large` when the result is 2^64 or more.

- [ ] **Step 2: Run** `node --test assets/test/units.test.js` from `web/`. Expected: fail, functions not exported.

- [ ] **Step 3: Implement** with BigInt only; parse the percent as text, never as a float.

- [ ] **Step 4: Run** the JS tests that use fakes (every file in `web/assets/test` except `actions.local.test.js`). Expected: all pass.

- [ ] **Step 5: Commit** `feat(web): percent, weight and fixed-point rate maths`.

---

### Task 7: Minting and revealing from the browser

**Files:**
- Modify: `web/assets/js/chain/abi.js`, `chain/fhe.js:50`, `chain/actions.js` (line 106 area, `createEnft` at 159, reveal functions at 438), `errors.js`, `hooks/secret_value.js`
- Test: `web/assets/test/errors.test.js`, `secret_value.test.js`, `fhe.test.js`, and a new fake-based test for `createEnft` argument checks in `web/assets/test/tokens.test.js`
- Test (written, not run here): `web/assets/test/actions.local.test.js`

**Interfaces:**
- Consumes: Task 6's `unitPerDay`.
- Produces:
  ```js
  export const PRIVATE_NFT_ABI = [...NFT_ABI,
    "function mintPrivate(address to, bytes32 encEndowment, bytes32 encUnit, bytes inputProof, (uint64 duration, uint64 ratePerSec)[] segments, uint64 scheduleStart, bool topUpsAllowed, bytes32 name) returns (uint256)",
    "function unitHandle(uint256 tokenId) view returns (bytes32)",
    "error WeightTooLarge()", "error RateRequired()"];
  // fhe.js
  encrypt64Pair(contractAddress, userAddress, a, b) // -> {handles: [h0, h1], inputProof}
  // actions.js: createEnft args gain `unit` (bigint)
  export async function revealRate(session, contract, tokenId) // -> bigint unit
  ```
  `createEnft` rules, checked before anything is sent: a contract with `nftKind === "private"` requires `unit`, else `ActionError("This ENFT type needs a base payout.")`; any other contract given `unit` throws `ActionError("Only a private-rate ENFT takes a base payout.")`; `auto` with a private contract throws the existing `requireAuto` error.
  `errors.js`: `0xe5f127cc` → "A period's share of the base rate is too large."; `0x72783940` → "This ENFT type needs a base payout. Reload and try again."
  `secret_value.js`: `data-secret="rate"` calls `deps.reveal.rate(session, contract, BigInt(id))` and shows `` `${unitPerDay(value, Number(decimals))} ${symbol} / day at 100%` ``.

- [ ] **Step 1: Write the failing tests.**
  - errors: `explain` of each new selector gives the text above. (The first text contains an apostrophe; it is JS, not HEEx, so that is fine.)
  - secret_value: a span with `data-secret="rate" data-id="7" data-decimals="9" data-symbol="cWETH"` and a fake `reveal.rate` returning `49710269629n` shows `0.999999999 cWETH / day at 100%`; the fake was called with `7n`.
  - fhe: `encrypt64Pair` calls `add64` twice in order on one input and returns both handles.
  - createEnft: the three refusals above, each thrown before `ensureChain` is reached (pass a session whose use would throw).
  - `actions.local.test.js` (write only): "create -> accrue -> reveal rate -> claim on a private-rate contract": creator and owner get the unit back from `revealRate`; a third account is refused; the claim is within 5% of `unit * weight * seconds >> 32`. Skip it when the deployments file has no `private` entry.

- [ ] **Step 2: Run** the fake-based JS tests. Expected: the new ones fail.

- [ ] **Step 3: Implement.** In `createEnft`, for a private contract: `encrypt64Pair(contract.nft, s.address, amount, unit)` in the "encrypt" step, then `mintPrivate(to, h0, h1, proof, schedule, start, topUps, nameWord)`. `revealRate` reads `unitHandle` and user-decrypts it with `contractAddress: contract.nft`. Register `rate: revealRate` in the `SecretValue` hook's deps.

- [ ] **Step 4: Run** the fake-based JS tests. Expected: all pass.

- [ ] **Step 5: Commit** `feat(web): mint a private-rate ENFT and reveal its rate in the browser`.

---

### Task 8: The Create page

**Files:**
- Modify: `web/lib/annuart_web/live/create_live.ex` (lines 104-116 and the schedule panel), `web/assets/js/hooks/create_form.js`, `web/assets/css/app.css`
- Test: `web/test/annuart_web/live/create_live_test.exs`, `web/assets/test/create_form.test.js`

**Interfaces:**
- Consumes: Task 6 (`percentToWeight`, `baseUnit`, `toWeightSegments`, `effectiveSegments`), Task 7 (`createEnft` with `unit`).
- Produces: option text `"#{label} (#{symbol}, private payout rate)"`; markup in the schedule panel:
  ```heex
  <div class="field" data-role="base-fields" hidden>
    <label>Base payout</label>
    <input type="text" inputmode="decimal" data-role="base" autocomplete="off" />
    <select data-role="base-per">day, week, month, year</select>
    <span class="note">Secret. Encrypted in your browser together with the amount.</span>
  </div>
  <p class="note" data-role="private-note" hidden>
    Period lengths and each period's share of the base payout are public. The base payout is hidden.
    A base payout that rounds to nothing on a schedule with no end locks the endowment for good.
  </p>
  ```
  Each period row, for a private type, shows a `data-role="percent"` input (default "100") in place of the rate and per fields.

- [ ] **Step 1: Write the failing tests.**
  - LiveView: with a `:private` contract configured, the option reads "… (TKN, private payout rate)" and carries `data-nft-kind="private"`; the page contains `data-role="base-fields"` and the private note text.
  - Form controller, private type chosen:
    - `base-fields` and the note are visible, the automatic-payout fields are hidden, each row has a percent input and no rate input; switching back to a standard type restores the rate inputs and hides the base fields;
    - base "1" per day, one row of 100 days at 100%, amount "150": `deps.actions.createEnft` is called with `unit: 49710269629n` and `segments: [{duration: 8640000n, ratePerSec: 1000n}]`;
    - percent "12.55" shows "Enter a percentage with at most one decimal place." and sends nothing;
    - an empty base shows a message and sends nothing;
    - the confirmation summary lists the base payout and each period's percent;
    - nothing pushed to the server (`deps.pushEvent` or equivalent in the existing tests) contains the base text, the unit or the amount.
  - Form controller, standard type: every existing test passes untouched.

- [ ] **Step 2: Run** both test files. Expected: the new tests fail.

- [ ] **Step 3: Implement.** `isPrivate()` beside `isAuto()`. The warning line uses `amountWarning(effectiveSegments(segments, unit), start, amount)` so "runs dry" and "leftover" still work, computed in the browser only.

- [ ] **Step 4: Run** `mix format --check-formatted && mix test`, then the fake-based JS tests. Expected: all pass.

- [ ] **Step 5: Commit** `feat(web): create a private-rate ENFT`.

---

### Task 9: Documentation, chain tests and final check

**Files:**
- Modify: `web/lib/annuart_web/live/guide_live.ex`, `web/test/annuart_web/live/guide_live_test.exs`, `guides/keeping-the-endowment-private.md`, `README.md`, `web/docs/manual-checklist.md`, `web/e2e/flows.spec.js`, `web/e2e/global-setup.js`

- [ ] **Step 1: Write the failing guide test**: the "Creating an ENFT" section mentions "private payout rate"; "What is private and what is public" says the base rate is hidden and that period lengths and shares are public; "Keeping the endowment total private" contains the three consequences from spec section 3 (one public amount reveals the rate; a past owner keeps the rate; a zero rate cannot be refused).

- [ ] **Step 2: Run** `mix test test/annuart_web/live/guide_live_test.exs`. Expected: fail.

- [ ] **Step 3: Write the text** in `guide_live.ex`, the same three points in `guides/keeping-the-endowment-private.md` (with a line in "How far this has been checked" that the Sepolia ACL check has not been run for this contract), a "Private-rate ENFT" paragraph in the README privacy model and deployment section (`NFT_KIND=private`), and manual-checklist entries: create, reveal rate as creator and as owner, claim, transfer and reveal as the new owner.

- [ ] **Step 4: Add the e2e flow** "create a private-rate ENFT, reveal its rate, claim" to `web/e2e/flows.spec.js`, and have `global-setup.js` deploy a private-rate contract over the mock token. Do not run it.

- [ ] **Step 5: Run everything that may be run**: `forge test`; `npx hardhat compile && npx hardhat test`; in `web/`, `mix format --check-formatted && mix test` and the fake-based JS tests. Expected: all pass.

- [ ] **Step 6: Commit** `docs: private-rate ENFT in the guide, README and checklists; e2e flow`.

- [ ] **Step 7: Stop and ask the owner** whether to run `web/assets/test/actions.local.test.js` (needs a private-rate contract deployed on their local chain, which only they deploy) and the e2e spec (needs ports 8545 and 4000 free). Report both as not run until they are.

## After the plan

Sepolia deployment and the ACL check on Sepolia are the owner's to run. The new contract has had no red-team review; the spec's section 3 and this plan's Review Focus list where to start.
