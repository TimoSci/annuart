# Annuart Web, Plan 1 of 3: Contract Changes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Change `EndowmentNFT` so a web app can read it and so no endowment can be stranded, add a confidential wrapper for WETH, and make the deploy tooling record per-network deployments.

**Architecture:** Four changes to the existing contract (public views, a mint event, a leftover sweep at schedule end, an indefinite final segment), one new stock-OpenZeppelin wrapper contract, and a deploy script that writes `deployments/<network>.json`. No encrypted value gains a new ACL grant.

**Tech Stack:** Solidity 0.8.27 (cancun), Foundry + `forge-fhevm`, Hardhat 2 + `@fhevm/hardhat-plugin`, `@fhevm/solidity@0.11.1`, `@openzeppelin/confidential-contracts@0.4.1`, `@openzeppelin/contracts@^5.6.1`.

**Spec:** `docs/superpowers/specs/2026-11-11-annuart-web-design.md`, section 3. This plan covers section 3 and the contract half of section 7. Plan 2 (browser FHE spike and Phoenix app) and Plan 3 (Sepolia deploys and wallet pass) are written after this one lands, because they depend on the final ABI and on the spike's outcome.

## Global Constraints

- Work on a branch `feat/web-contracts`, not `main`.
- `pragma solidity ^0.8.24;` in `src/`; compiler stays `0.8.27`, `evm_version = "cancun"`.
- ACL discipline is unchanged: never `FHE.allow(endowmentRemaining, <anyone>)`; only `FHE.allowThis`. Every new or changed `distribution` handle gets `FHE.allowThis` plus `FHE.allow(distribution, currentOwner)`.
- The mint event must not contain the schedule.
- `mint`'s signature does not change, so `client/src/mint.ts` and the `mint` ABI strings elsewhere stay valid.
- Rates stay whole base units per second; no precision change.
- Hardhat commands need Node >= 20: `export PATH="/opt/homebrew/opt/node@22/bin:$PATH"`.
- TDD: failing test first. Commit after each task. End commit messages with
  `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`.
- Full check after every task: `forge test` passes with no failures.

## Review Focus

Inputs the spec implies but does not spell out; each has a test in the named task.

1. Schedule already over at mint (a past `scheduleStart`): the first accrual sweeps the whole endowment and `topUp` reverts. Task 4.
2. Transfer at or after the end: the leftover goes to the new owner and the old owner cannot decrypt it. Task 4.
3. Repeated `accrue` and `claim` after the sweep: no revert, nothing paid twice. Task 4.
4. Indefinite schedule after a very long time (integration saturates at `uint64` max): no revert, payout capped by the endowment. Task 2.
5. Wrapping an ETH amount that is not a multiple of 1e9 wei: the confidential balance gets the whole multiple and the remainder is not lost. Task 5.

---

## File Structure

| File | Responsibility |
|---|---|
| `src/libraries/Schedule.sol` | Modify. Adds the `INDEFINITE` sentinel and `isIndefinite`. |
| `src/EndowmentNFT.sol` | Modify. Validation, views, event, sweep, late top-up rejection. |
| `src/ConfidentialWETH.sol` | Create. OZ `ERC7984ERC20Wrapper` over WETH with 9 decimals. |
| `src/mocks/MockWETH.sol` | Create. Dev/test WETH9-style token (`deposit`, `withdraw`). |
| `test/Schedule.t.sol` | Modify. Sentinel tests. |
| `test/EndowmentNFT.t.sol` | Modify. Tests for every contract change. |
| `test/ConfidentialWETH.t.sol` | Create. Wrapper tests. |
| `test/EndowmentNFT.hh.ts` | Modify. Event and sweep on the Hardhat mock. |
| `scripts/deploy.ts` | Modify. Variants, per-network file, deploy block. |
| `tasks/deployments.ts` | Create. Reads and writes `deployments/<network>.json`. |
| `tasks/endowment.ts` | Modify. Uses `tasks/deployments.ts`; `task:info` prints new fields. |
| `README.md` | Modify. Deploy and task sections. |

---

### Task 1: Indefinite sentinel in the schedule library

**Files:**
- Modify: `src/libraries/Schedule.sol`
- Test: `test/Schedule.t.sol`

**Interfaces:**
- Produces, at file level in `Schedule.sol`: `uint64 constant INDEFINITE = type(uint64).max;`
- Produces: `Schedule.isIndefinite(Segment[] memory s) internal pure returns (bool)`, true when `s` is non-empty and its last segment's `duration == INDEFINITE`.
- Unchanged: `Schedule.integrate`, `Schedule.scheduleEnd`. For an indefinite schedule `scheduleEnd` returns `type(uint64).max`; callers treat that value as "no end".

- [ ] **Step 1: Write the failing tests** in `test/Schedule.t.sol` (import `INDEFINITE` alongside `Schedule, Segment`)

```solidity
function _openEnded() internal pure returns (Segment[] memory s) {
    s = new Segment[](2);
    s[0] = Segment({duration: 100, ratePerSec: 2});       // [0,100) -> 200
    s[1] = Segment({duration: INDEFINITE, ratePerSec: 3}); // [100, forever)
}

function test_isIndefinite() public pure {
    assertTrue(Schedule.isIndefinite(_openEnded()));
    assertFalse(Schedule.isIndefinite(_two()));
    assertFalse(Schedule.isIndefinite(new Segment[](0)));
}

function test_indefinite_integratesPastFiniteSegments() public pure {
    // 200 from the first segment + 3 * 900 from the open one
    assertEq(Schedule.integrate(_openEnded(), 0, 0, 1_000), 2_900);
}

function test_indefinite_scheduleEndIsMax() public pure {
    assertEq(Schedule.scheduleEnd(_openEnded(), 1_700_000_000), type(uint64).max);
}

function test_indefinite_noOverflowWithLateStart() public pure {
    uint64 start = type(uint64).max - 10;
    assertEq(Schedule.integrate(_openEnded(), start, start, type(uint64).max), 20);
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `forge test --match-contract ScheduleTest`
Expected: compile error, `INDEFINITE` and `isIndefinite` undefined.

- [ ] **Step 3: Add `INDEFINITE` and `isIndefinite` to `src/libraries/Schedule.sol`**

If `test_indefinite_noOverflowWithLateStart` fails afterwards, fix `integrate` so `segStart + duration` cannot wrap (it is already `uint256`; keep it that way).

- [ ] **Step 4: Run and confirm pass**

Run: `forge test --match-contract ScheduleTest`
Expected: all pass, including the existing fuzz test.

- [ ] **Step 5: Commit**

```bash
git add src/libraries/Schedule.sol test/Schedule.t.sol
git commit -m "feat: indefinite-segment sentinel in Schedule library"
```

---

### Task 2: Mint validation and indefinite accrual

**Files:**
- Modify: `src/EndowmentNFT.sol` (the `mint` loop and error list)
- Test: `test/EndowmentNFT.t.sol`

**Interfaces:**
- Consumes: `INDEFINITE`, `Schedule.isIndefinite` (Task 1).
- Produces: `error IndefiniteSegmentNotLast();`, `error ZeroRateIndefiniteSegment();` on `EndowmentNFT`.
- Produces, in the test contract, for later tasks:
  `_mintWith(address to, uint64 amount, bool topUps, Segment[] memory segs, uint64 start) internal returns (uint256 id)`: same as the existing `_mintEndowment` but with caller-supplied segments and start. Reimplement `_mintEndowment` on top of it.

- [ ] **Step 1: Write the failing tests**

```solidity
function _open(uint64 rate) internal pure returns (Segment[] memory s) {
    s = new Segment[](2);
    s[0] = Segment({duration: 100, ratePerSec: 1});
    s[1] = Segment({duration: INDEFINITE, ratePerSec: rate});
}

function test_mint_revertsWhenIndefiniteNotLast() public {
    Segment[] memory s = new Segment[](2);
    s[0] = Segment({duration: INDEFINITE, ratePerSec: 1});
    s[1] = Segment({duration: 100, ratePerSec: 1});
    token.mint(creator, 10);
    vm.prank(creator);
    token.setOperator(address(nft), uint48(block.timestamp + 365 days));
    (externalEuint64 h, bytes memory p) = encryptUint64(10, creator, address(nft));
    vm.expectRevert(EndowmentNFT.IndefiniteSegmentNotLast.selector);
    vm.prank(creator);
    nft.mint(alice, h, p, s, uint64(block.timestamp), false);
}

function test_mint_revertsWhenIndefiniteRateZero() public {
    // same setup, segments = _open(0), expect ZeroRateIndefiniteSegment
}

function test_indefinite_paysUntilEndowmentRunsOut() public {
    uint256 id = _mintWith(alice, 1_000, false, _open(2), uint64(block.timestamp));
    vm.warp(block.timestamp + 200);          // 100*1 + 100*2 = 300
    nft.accrue(id);
    assertEq(decrypt(nft.distributionHandle(id)), 300);
    vm.warp(block.timestamp + 10_000);       // would be far more than 1000
    nft.accrue(id);
    assertEq(decrypt(nft.distributionHandle(id)), 1_000);
}

// Review Focus 4
function test_indefinite_saturatedIntegrationDoesNotRevert() public {
    uint256 id = _mintWith(alice, 1_000, false, _open(type(uint64).max), uint64(block.timestamp));
    vm.warp(block.timestamp + 365 days);
    nft.accrue(id);
    assertEq(decrypt(nft.distributionHandle(id)), 1_000);
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `forge test --match-contract EndowmentNFTTest --match-test "indefinite|Indefinite"`
Expected: compile error on the new error selectors.

- [ ] **Step 3: Implement validation in `mint`**

In the segment loop: a segment with `duration == INDEFINITE` must be the last one (else `IndefiniteSegmentNotLast`) and must have `ratePerSec > 0` (else `ZeroRateIndefiniteSegment`). `ZeroDurationSegment` stays. `_accrue` needs no change for this task.

- [ ] **Step 4: Run and confirm pass**

Run: `forge test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/EndowmentNFT.sol test/EndowmentNFT.t.sol
git commit -m "feat: allow an indefinite final schedule segment"
```

---

### Task 3: Public views and the mint event

**Files:**
- Modify: `src/EndowmentNFT.sol`
- Test: `test/EndowmentNFT.t.sol`

**Interfaces:**
- Produces on `EndowmentNFT` (each view reverts `NonexistentToken` for an unminted id):
  - `event EndowmentMinted(uint256 indexed tokenId, address indexed creator, address indexed to, uint64 scheduleStart, bool topUpsAllowed);`
  - `function scheduleOf(uint256 tokenId) external view returns (Segment[] memory)`
  - `function scheduleStartOf(uint256 tokenId) external view returns (uint64)`
  - `function scheduleEndOf(uint256 tokenId) external view returns (uint64)`; `type(uint64).max` means no end.
  - `function lastAccrualAtOf(uint256 tokenId) external view returns (uint64)`
- `creator` in the event is `msg.sender`; `scheduleStart` is the resolved start (never 0).

- [ ] **Step 1: Write the failing tests**

```solidity
function test_views_exposeSchedule() public {
    uint64 t0 = uint64(block.timestamp);
    uint256 id = _mintEndowment(alice, 500, true);
    Segment[] memory s = nft.scheduleOf(id);
    assertEq(s.length, 1);
    assertEq(s[0].duration, 1_000);
    assertEq(s[0].ratePerSec, 1);
    assertEq(nft.scheduleStartOf(id), t0);
    assertEq(nft.scheduleEndOf(id), t0 + 1_000);
    assertEq(nft.lastAccrualAtOf(id), t0);
    vm.warp(t0 + 40);
    nft.accrue(id);
    assertEq(nft.lastAccrualAtOf(id), t0 + 40);
}

function test_views_indefiniteEndIsMax() public {
    uint256 id = _mintWith(alice, 500, false, _open(1), uint64(block.timestamp));
    assertEq(nft.scheduleEndOf(id), type(uint64).max);
}

function test_views_revertForNonexistentToken() public {
    vm.expectRevert(EndowmentNFT.NonexistentToken.selector);
    nft.scheduleOf(99);
    // repeat for scheduleStartOf, scheduleEndOf, lastAccrualAtOf
}

function test_mint_emitsEndowmentMinted() public {
    token.mint(creator, 500);
    vm.prank(creator);
    token.setOperator(address(nft), uint48(block.timestamp + 365 days));
    (externalEuint64 h, bytes memory p) = encryptUint64(500, creator, address(nft));
    vm.expectEmit(true, true, true, true, address(nft));
    emit EndowmentNFT.EndowmentMinted(1, creator, alice, uint64(block.timestamp), true);
    vm.prank(creator);
    nft.mint(alice, h, p, _segments(), 0, true); // 0 resolves to block.timestamp
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `forge test --match-contract EndowmentNFTTest --match-test "views|emits"`
Expected: compile error, members not found.

- [ ] **Step 3: Implement the four views and emit the event at the end of `mint`**

- [ ] **Step 4: Run and confirm pass**

Run: `forge test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/EndowmentNFT.sol test/EndowmentNFT.t.sol
git commit -m "feat: public schedule views and EndowmentMinted event"
```

---

### Task 4: Leftover sweep at schedule end

**Files:**
- Modify: `src/EndowmentNFT.sol` (`Endowment` struct, `_accrue`, `topUp`)
- Test: `test/EndowmentNFT.t.sol`

**Interfaces:**
- Produces: `error ScheduleEnded();`
- Produces: `function settledOf(uint256 tokenId) external view returns (bool)`; reverts `NonexistentToken`.
- `Endowment` gains `bool settled`.

- [ ] **Step 1: Write the failing tests**

```solidity
function test_sweep_releasesLeftoverAtEnd() public {
    uint256 id = _mintEndowment(alice, 5_000, false); // schedule total is 1000
    vm.warp(block.timestamp + 999);
    nft.accrue(id);
    assertEq(decrypt(nft.distributionHandle(id)), 999);
    assertFalse(nft.settledOf(id));
    vm.warp(block.timestamp + 1);                     // exactly the end
    nft.accrue(id);
    assertEq(decrypt(nft.distributionHandle(id)), 5_000);
    assertTrue(nft.settledOf(id));
}

function test_sweep_claimPaysEverything() public {
    uint256 id = _mintEndowment(alice, 5_000, false);
    vm.warp(block.timestamp + 2_000);
    vm.prank(alice);
    nft.claim(id);
    assertEq(decrypt(token.confidentialBalanceOf(alice)), 5_000);
    assertEq(decrypt(token.confidentialBalanceOf(address(nft))), 0);
}

// Review Focus 3
function test_sweep_repeatAccrueAndClaimPayNothingMore() public {
    uint256 id = _mintEndowment(alice, 5_000, false);
    vm.warp(block.timestamp + 2_000);
    vm.prank(alice);
    nft.claim(id);
    vm.warp(block.timestamp + 500);
    nft.accrue(id);
    assertEq(decrypt(nft.distributionHandle(id)), 0);
    vm.prank(alice);
    nft.claim(id);
    assertEq(decrypt(token.confidentialBalanceOf(alice)), 5_000);
}

// Review Focus 1
function test_sweep_scheduleAlreadyOverAtMint() public {
    vm.warp(1_000_000);
    uint256 id = _mintWith(alice, 700, true, _segments(), uint64(block.timestamp - 5_000));
    nft.accrue(id);
    assertEq(decrypt(nft.distributionHandle(id)), 700);
    token.mint(bob, 100);
    vm.prank(bob);
    token.setOperator(address(nft), uint48(block.timestamp + 365 days));
    (externalEuint64 h, bytes memory p) = encryptUint64(100, bob, address(nft));
    vm.expectRevert(EndowmentNFT.ScheduleEnded.selector);
    vm.prank(bob);
    nft.topUp(id, h, p);
}

// Review Focus 2
function test_sweep_transferAfterEndGivesLeftoverToNewOwner() public {
    uint256 id = _mintEndowment(alice, 5_000, false);
    vm.warp(block.timestamp + 2_000);
    vm.prank(alice);
    nft.transferFrom(alice, bob, id);
    vm.prank(bob);
    nft.claim(id);
    assertEq(decrypt(token.confidentialBalanceOf(bob)), 5_000);
    // alice must not be allowed on the post-transfer distribution handle;
    // assert it the same way test_transfer_newOwnerCanReadOldOwnerCannot does.
}

function test_topUp_allowedBeforeEndRejectedAtEnd() public {
    uint256 id = _mintEndowment(alice, 500, true);
    vm.warp(block.timestamp + 999);
    _topUp(id, bob, 10);                              // one second before the end: fine
    vm.warp(block.timestamp + 1);
    // expect ScheduleEnded on a further top-up, set up as in the test above
}

function test_topUp_neverRejectedOnIndefinite() public {
    uint256 id = _mintWith(alice, 500, true, _open(1), uint64(block.timestamp));
    vm.warp(block.timestamp + 10 * 365 days);
    _topUp(id, bob, 10);                              // must not revert
    assertFalse(nft.settledOf(id));
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `forge test --match-contract EndowmentNFTTest --match-test "sweep|topUp_"`
Expected: compile error on `ScheduleEnded` / `settledOf`.

- [ ] **Step 3: Implement**

`_accrue`, in this order:

```solidity
Endowment storage e = _endowments[tokenId];
if (e.settled) return;
uint64 nowTs = uint64(block.timestamp);
uint64 end = Schedule.scheduleEnd(e.schedule, e.scheduleStart);

if (nowTs >= end) {
    // Fixed-end schedule is over: release everything that is left.
    // (end == type(uint64).max for an indefinite schedule, so this is never reached.)
    e.distribution = FHE.add(e.distribution, e.endowmentRemaining);
    e.endowmentRemaining = FHE.asEuint64(0);
    e.settled = true;
    e.lastAccrualAt = end;
    FHE.allowThis(e.endowmentRemaining);
    FHE.allowThis(e.distribution);
    FHE.allow(e.distribution, ownerOf(tokenId));
    return;
}
// ...existing owed / FHE.min path, unchanged...
```

`topUp`: after the `TopUpsDisabled` check and before pulling tokens, revert `ScheduleEnded` when `block.timestamp >= Schedule.scheduleEnd(e.schedule, e.scheduleStart)`.

- [ ] **Step 4: Repair existing tests whose expectations the sweep changes**

Run: `forge test`
Any existing test that accrues at or past the end now sees the whole endowment in `distribution`, and any that tops up at or past the end now reverts. `testFuzz_conservation` is the likely one: keep its invariant (claimed + distribution + remaining equals endowment + top-ups, nothing created or lost) and bound its top-up to before the end. Do not weaken an assertion to make it pass; if a test fails for another reason, the implementation is wrong.
Expected after repair: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/EndowmentNFT.sol test/EndowmentNFT.t.sol
git commit -m "feat: release leftover endowment to the owner at schedule end"
```

---

### Task 5: Confidential WETH wrapper

**Files:**
- Create: `src/ConfidentialWETH.sol`, `src/mocks/MockWETH.sol`
- Test: `test/ConfidentialWETH.t.sol`

**Interfaces:**
- Produces: `contract ConfidentialWETH is ERC7984ERC20Wrapper, ZamaEthereumConfig` with
  `constructor(IERC20 weth)`, name `"Confidential Wrapped Ether"`, symbol `"cWETH"`, empty URI, and `_maxDecimals()` overridden to return `9`. Nothing else is overridden.
- Produces: `contract MockWETH is ERC20("Wrapped Ether", "WETH")` with `deposit() external payable` (mints `msg.value`), `withdraw(uint256 amount) external` (burns and sends ETH), and `receive()` calling `deposit`. Same chain-id guard as `MockConfidentialToken` (reverts on chain ids 1, 56, 999).
- Inherited and used by later plans: `wrap(address to, uint256 amount)`, `unwrap(address from, address to, bytes32 encAmount, bytes inputProof)`, `finalizeUnwrap(...)`, `rate()`, `underlying()`, `decimals()`.

- [ ] **Step 1: Write the failing tests** (`ConfidentialWETHTest is FhevmTest`, `setUp` deploys `MockWETH`, `ConfidentialWETH`, and an `EndowmentNFT` over the wrapper)

```solidity
function test_decimalsAndRate() public view {
    assertEq(cweth.decimals(), 9);
    assertEq(cweth.rate(), 1e9);
    assertEq(cweth.underlying(), address(weth));
}

function test_wrap_oneEther() public {
    vm.deal(alice, 1 ether);
    vm.startPrank(alice);
    weth.deposit{value: 1 ether}();
    weth.approve(address(cweth), 1 ether);
    cweth.wrap(alice, 1 ether);
    vm.stopPrank();
    assertEq(decrypt(cweth.confidentialBalanceOf(alice)), 1e9);
    assertEq(weth.balanceOf(address(cweth)), 1 ether);
}

// Review Focus 5
function test_wrap_dustStaysWithSender() public {
    vm.deal(alice, 2 ether);
    vm.startPrank(alice);
    weth.deposit{value: 2 ether}();
    weth.approve(address(cweth), 2 ether);
    cweth.wrap(alice, 1 ether + 1);              // 1 wei below the 1e9 granularity
    vm.stopPrank();
    assertEq(decrypt(cweth.confidentialBalanceOf(alice)), 1e9);
    assertEq(weth.balanceOf(alice), 1 ether);    // the extra wei was not taken
}

function test_enftOverWrapper_mintAccrueClaim() public {
    // alice wraps 1 ether, sets nft as operator, mints an ENFT of 1e9 units
    // with one segment {duration: 1000, ratePerSec: 1e6}, warps 1000, claims:
    // confidential balance of alice is 1e9 again.
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `forge test --match-contract ConfidentialWETHTest`
Expected: compile error, contracts not found.

- [ ] **Step 3: Implement both contracts**

- [ ] **Step 4: Run and confirm pass**

Run: `forge test`
Expected: all pass. If `test_wrap_dustStaysWithSender` fails because the installed wrapper takes the dust, do not patch the wrapper: change the assertion to what the library does, and record the behaviour in the README section of Task 6 so the web app can warn about it.

- [ ] **Step 5: Commit**

```bash
git add src/ConfidentialWETH.sol src/mocks/MockWETH.sol test/ConfidentialWETH.t.sol
git commit -m "feat: confidential WETH wrapper with 9 decimals"
```

---

### Task 6: Deploy script, tasks, Hardhat test, README

**Files:**
- Create: `tasks/deployments.ts`
- Modify: `scripts/deploy.ts`, `tasks/endowment.ts`, `test/EndowmentNFT.hh.ts`, `README.md`

**Interfaces:**
- Produces the deployment file, `deployments/<network>.json`, where `<network>` is Hardhat's network name (`localhost`, `sepolia`). Plan 2's web app reads this exact shape:

```json
{
  "chainId": 31337,
  "contracts": [
    {
      "label": "mock",
      "nft": "0x…",
      "token": "0x…",
      "tokenKind": "mock",
      "underlying": null,
      "deployBlock": 3
    }
  ]
}
```

  `tokenKind` is `"mock"`, `"wrapped"` or `"plain"`. `underlying` is the WETH address for `"wrapped"`, otherwise `null`. `deployBlock` is the block of the ENFT contract's deployment.
- Produces in `tasks/deployments.ts`:
  - `type Deployment = { label: string; nft: string; token: string; tokenKind: "mock" | "wrapped" | "plain"; underlying: string | null; deployBlock: number }`
  - `readDeployments(network: string): { chainId: number; contracts: Deployment[] }` (empty list when the file is missing)
  - `upsertDeployment(network: string, chainId: number, d: Deployment): void` (replaces the entry with the same `label`, otherwise appends)
  - `findDeployment(network: string, label?: string): Deployment | undefined` (first entry when `label` is omitted)
- `scripts/deploy.ts` environment:
  - `TOKEN_KIND` = `mock` (default) | `wrapped` | `plain`
  - `LABEL` (default: the token kind)
  - `WETH_ADDRESS`: required for `wrapped` on any network except `localhost`/`hardhat`, where a `MockWETH` is deployed when it is unset
  - `TOKEN_ADDRESS`: required for `plain`
- `tasks/endowment.ts`: every task gains `--label`; `--nft`/`--token` still override. `task:mint` keeps minting test tokens only when the deployment's `tokenKind` is `mock`, and fails with a clear message otherwise.

- [ ] **Step 1: Extend the Hardhat smoke test** in `test/EndowmentNFT.hh.ts`

Add to the existing test: the mint receipt contains an `EndowmentMinted` event whose `creator` and `to` are the deployer and whose `topUpsAllowed` is `false`.

Add a second test, "releases the leftover at schedule end": endowment `2000`, segments `[{ duration: 1000, ratePerSec: 1 }]`, `time.increase(1001)`, `claim`, then the deployer's decrypted token balance equals `2000n` and `await nft.settledOf(1n)` is `true`.

- [ ] **Step 2: Run and confirm the new assertions pass against Tasks 2-4**

Run: `npx hardhat test test/EndowmentNFT.hh.ts`
Expected: 2 passing. (These exercise already-built behaviour on the Hardhat mock; a failure here means the Foundry and Hardhat mocks disagree and must be investigated, not papered over.)

- [ ] **Step 3: Implement `tasks/deployments.ts` and switch `scripts/deploy.ts` and `tasks/endowment.ts` to it**

`task:info` additionally prints `scheduleOf`, `scheduleStartOf`, `scheduleEndOf` (printing `indefinite` for `type(uint64).max`), `lastAccrualAtOf` and `settledOf`.

- [ ] **Step 4: Verify the deploy flow by hand**

```bash
npx hardhat node                                                    # terminal 1
npx hardhat run scripts/deploy.ts --network localhost               # terminal 2
TOKEN_KIND=wrapped npx hardhat run scripts/deploy.ts --network localhost
cat deployments/localhost.json
npx hardhat task:mint --amount 1000000 --topups true --network localhost
npx hardhat task:info --id 1 --network localhost
npx hardhat task:mint --amount 1 --label wrapped --network localhost
```

Expected: the JSON has two entries, `mock` and `wrapped`, each with a non-zero `deployBlock`, and `wrapped` has a non-null `underlying`. `task:info` prints a one-segment schedule and `settled = false`. The last command fails with the "not a mock token" message and sends no transaction. Running the first deploy command a second time leaves two entries, not three.

- [ ] **Step 5: Update `README.md`**

In "Interacting via Hardhat": the per-network deployment file and its shape, `TOKEN_KIND` / `LABEL` / `WETH_ADDRESS`, the `--label` option, and a short "Behaviour" list covering: leftover is released to the owner at the end of a fixed schedule; top-ups are rejected after that end; a final segment with `duration = 2^64 - 1` is indefinite and must have a non-zero rate; cWETH has 9 decimals. Remove references to `deployments/local.json`.

- [ ] **Step 6: Full check and commit**

Run: `forge test && npx hardhat test test/EndowmentNFT.hh.ts`
Expected: everything passes.

```bash
git add tasks scripts test/EndowmentNFT.hh.ts README.md
git commit -m "chore: per-network deployments, token variants, tooling for new ABI"
```
