# Zero-Knowledge Endowment NFT Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `EndowmentNFT` — an ERC-721 on Zama FHEVM where each token is a transferable income stream backed by a secret encrypted endowment that drains into an owner-readable distribution account on a creator-defined piecewise-linear schedule.

**Architecture:** A single pooled contract that is simultaneously an ERC-721, an escrow holding a pooled balance of an external confidential token (OZ `ERC7984`), and a lazy accrual engine with per-token encrypted state (`endowmentRemaining`, `distribution`). Endowment secrecy is enforced purely through the FHEVM ACL — the owner is never granted `FHE.allow` on the endowment handle. Everything is homomorphic; no decryption oracle is used on-chain.

**Tech Stack:** Solidity, Foundry, `@fhevm/solidity` (FHE library + ACL), `@openzeppelin/confidential-contracts` (ERC7984), `forge-fhevm` (Foundry-native FHE test harness with real host contracts), `@zama-fhe/relayer-sdk` (TypeScript client for Sepolia), `@openzeppelin/contracts` (ERC721, ReentrancyGuard).

## Global Constraints

- **Solidity pragma in `src/`:** `pragma solidity ^0.8.24;` (matches `@fhevm/solidity` and OZ source).
- **Foundry compiler:** `solc >= 0.8.27` and `evm_version = "cancun"` — **required by `forge-fhevm`** (a `^0.8.24` pragma compiles fine under 0.8.27, so both hold simultaneously).
- **Pinned dependency versions:** `@fhevm/solidity@0.11.1`, `@openzeppelin/confidential-contracts@0.4.1`, `@openzeppelin/contracts@^5.6.1`, `@zama-fhe/relayer-sdk@0.4.4`, `forge-fhevm` (git `main`).
- **FHE config base contract name is version-dependent.** In `@fhevm/solidity@0.11.1` it is `ZamaEthereumConfig` (in 0.8.x it was `SepoliaConfig`). **Task 1 establishes the exact name from the installed package; use that name everywhere this plan writes `ZamaEthereumConfig`.**
- **Confidential token type is `ERC7984`** (the old name `ConfidentialFungibleToken` is gone). Interface: `@openzeppelin/confidential-contracts/interfaces/IERC7984.sol`.
- **Amount type is `euint64`** throughout (max ~1.8×10¹⁹ base units).
- **ACL discipline (non-negotiable):** never call `FHE.allow(endowmentRemaining, <any owner>)`. The endowment handle gets `FHE.allowThis` only. The distribution handle gets `FHE.allowThis` + `FHE.allow(distribution, currentOwner)`.
- **Every FHE op produces a fresh handle.** After mutating a handle, re-apply its ACL. On transfer, refresh the distribution handle so the prior owner loses read access to post-transfer values.
- **Operator precondition:** before `mint`/`topUp`, the funder must call `token.setOperator(endowmentNFT, until)` so the contract can pull tokens via `confidentialTransferFrom`.
- **Commit after every task.** TDD: write the failing test first.

---

## File Structure

| File | Responsibility |
|---|---|
| `foundry.toml` | Compiler config (solc ≥0.8.27, cancun), remappings, fs permissions. |
| `remappings.txt` | Dependency import remappings. |
| `package.json` | npm deps for Solidity libs (installed into `node_modules`) + client. |
| `.gitignore` | Ignore `out/`, `cache/`, `node_modules/`, `broadcast/`, `.env`. |
| `src/libraries/Schedule.sol` | Pure piecewise-linear integration + schedule-end math. Defines `Segment`. |
| `src/EndowmentNFT.sol` | The main contract: ERC721 + escrow + accrual engine. |
| `test/mocks/MockConfidentialToken.sol` | Concrete `ERC7984` with a public `mint` for tests/local deploy. |
| `test/Schedule.t.sol` | Pure unit + fuzz tests for the schedule math. |
| `test/EndowmentNFT.t.sol` | `forge-fhevm` integration + invariant tests. |
| `script/Deploy.s.sol` | Deploy `MockConfidentialToken` + `EndowmentNFT` (local + Sepolia). |
| `client/package.json` | TS client deps (`@zama-fhe/relayer-sdk`, `ethers`). |
| `client/src/*.ts` | Sepolia flows: mint, accrue, claim, decrypt, negative-decrypt. |
| `README.md` | How to build, test, deploy, run the client. |

---

## Task 1: Project scaffolding & dependencies

**Files:**
- Create: `foundry.toml`, `remappings.txt`, `package.json`, `.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces: a compiling Foundry project with all FHEVM deps importable.

- [ ] **Step 1: Initialize Foundry & install deps**

Run from repo root (already a git repo):
```bash
forge init --no-git --force .
rm -f src/Counter.sol test/Counter.t.sol script/Counter.s.sol
npm init -y
npm install @fhevm/solidity@0.11.1 @openzeppelin/confidential-contracts@0.4.1 @openzeppelin/contracts@^5.6.1 encrypted-types
forge install zama-ai/forge-fhevm
```

- [ ] **Step 2: Write `remappings.txt`**

```
@fhevm/solidity/=node_modules/@fhevm/solidity/
@openzeppelin/confidential-contracts/=node_modules/@openzeppelin/confidential-contracts/contracts/
@openzeppelin/contracts/=node_modules/@openzeppelin/contracts/
encrypted-types/=node_modules/encrypted-types/
forge-fhevm/=lib/forge-fhevm/src/
forge-std/=lib/forge-std/src/
```

- [ ] **Step 3: Write `foundry.toml`**

```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib", "node_modules"]
solc_version = "0.8.27"
evm_version = "cancun"
ffi = true
fs_permissions = [{ access = "read", path = "./"}]
optimizer = true
optimizer_runs = 200

[rpc_endpoints]
sepolia = "${SEPOLIA_RPC_URL}"
```

- [ ] **Step 4: Write `.gitignore`**

```
out/
cache/
node_modules/
broadcast/
.env
client/node_modules/
client/dist/
```

- [ ] **Step 5: Establish the FHE config base-contract name (CRITICAL)**

Open the installed config file and record the config contract name. Run:
```bash
grep -nE "contract (Sepolia|ZamaEthereum|ZamaSepolia|Ethereum)[A-Za-z]*Config" node_modules/@fhevm/solidity/config/ZamaConfig.sol
```
Expected: a line like `abstract contract ZamaEthereumConfig is CoprocessorConfig`. **Whatever name this prints is `CONFIG_BASE` for the rest of the plan.** If multiple configs exist (e.g. a distinct Sepolia testnet config), note both: the one matching the network you will deploy to is what `script/Deploy.s.sol` must inherit; for `forge-fhevm` local tests the name is cosmetic (host contracts are injected at canonical addresses regardless).

- [ ] **Step 6: Verify it compiles**

Run: `forge build`
Expected: compiles successfully (no source yet beyond forge-std/lib) — confirms remappings resolve. If `forge build` reports "Nothing to compile", that is also acceptable.

- [ ] **Step 7: Commit**

```bash
git add foundry.toml remappings.txt package.json package-lock.json .gitignore lib .gitmodules
git commit -m "chore: scaffold Foundry project with FHEVM dependencies"
```

---

## Task 2: Schedule library (pure piecewise-linear math)

**Files:**
- Create: `src/libraries/Schedule.sol`
- Test: `test/Schedule.t.sol`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct Segment { uint64 duration; uint64 ratePerSec; }`
  - `Schedule.integrate(Segment[] memory s, uint64 start, uint64 from, uint64 to) internal pure returns (uint64)` — total accrued over `[from, to]` ∩ schedule window, saturating at `type(uint64).max`.
  - `Schedule.scheduleEnd(Segment[] memory s, uint64 start) internal pure returns (uint64)` — `start + Σ durations`, saturating at `type(uint64).max`.

- [ ] **Step 1: Write the failing tests**

`test/Schedule.t.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Schedule, Segment} from "../src/libraries/Schedule.sol";

contract ScheduleTest is Test {
    function _two() internal pure returns (Segment[] memory s) {
        s = new Segment[](2);
        s[0] = Segment({duration: 100, ratePerSec: 2}); // [0,100)   -> 200
        s[1] = Segment({duration: 100, ratePerSec: 5}); // [100,200) -> 500
    }

    function test_fullWindow() public pure {
        assertEq(Schedule.integrate(_two(), 0, 0, 200), 700);
    }

    function test_partialFirstSegment() public pure {
        assertEq(Schedule.integrate(_two(), 0, 0, 50), 100);
    }

    function test_spanningBoundary() public pure {
        // [50,150): 50s@2 + 50s@5 = 100 + 250
        assertEq(Schedule.integrate(_two(), 0, 50, 150), 350);
    }

    function test_clampsPastEnd() public pure {
        // to=10_000 clamps to 200 -> full 700
        assertEq(Schedule.integrate(_two(), 0, 0, 10_000), 700);
    }

    function test_emptyWhenToBeforeFrom() public pure {
        assertEq(Schedule.integrate(_two(), 0, 200, 100), 0);
    }

    function test_nonZeroStartOffset() public pure {
        // start=1000 shifts windows: integrate over [1000,1100) -> first segment -> 200
        assertEq(Schedule.integrate(_two(), 1000, 1000, 1100), 200);
    }

    function test_scheduleEnd() public pure {
        assertEq(Schedule.scheduleEnd(_two(), 1000), 1200);
    }

    function test_saturatesOnOverflow() public pure {
        Segment[] memory s = new Segment[](1);
        s[0] = Segment({duration: type(uint64).max, ratePerSec: type(uint64).max});
        assertEq(Schedule.integrate(s, 0, 0, type(uint64).max), type(uint64).max);
    }

    function testFuzz_monotonicAndBounded(uint64 from, uint64 to) public pure {
        Segment[] memory s = _two();
        uint64 v = Schedule.integrate(s, 0, from, to);
        assertLe(v, 700); // can never exceed the full schedule total
        if (to <= from) assertEq(v, 0);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-contract ScheduleTest`
Expected: FAIL — `Schedule.sol` / `Segment` not found.

- [ ] **Step 3: Write `src/libraries/Schedule.sol`**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

struct Segment {
    uint64 duration;   // seconds this segment lasts
    uint64 ratePerSec; // base units accrued per second during this segment
}

library Schedule {
    /// @dev Total accrued over [from, to] intersected with the schedule window,
    ///      saturating at type(uint64).max instead of overflowing.
    function integrate(Segment[] memory s, uint64 start, uint64 from, uint64 to)
        internal
        pure
        returns (uint64)
    {
        if (to <= from) return 0;
        uint256 segStart = start;
        uint256 acc = 0;
        for (uint256 i = 0; i < s.length; i++) {
            uint256 segEnd = segStart + s[i].duration;
            uint256 lo = from > segStart ? from : segStart;
            uint256 hi = to < segEnd ? to : segEnd;
            if (hi > lo) {
                acc += uint256(s[i].ratePerSec) * (hi - lo);
                if (acc >= type(uint64).max) return type(uint64).max;
            }
            segStart = segEnd;
        }
        return uint64(acc);
    }

    /// @dev start + sum of all segment durations, saturating at type(uint64).max.
    function scheduleEnd(Segment[] memory s, uint64 start) internal pure returns (uint64) {
        uint256 total = start;
        for (uint256 i = 0; i < s.length; i++) {
            total += s[i].duration;
            if (total >= type(uint64).max) return type(uint64).max;
        }
        return uint64(total);
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `forge test --match-contract ScheduleTest`
Expected: PASS (all tests, including fuzz).

- [ ] **Step 5: Commit**

```bash
git add src/libraries/Schedule.sol test/Schedule.t.sol
git commit -m "feat: piecewise-linear schedule integration library"
```

---

## Task 3: Mock confidential token + FHE test-harness sanity check

**Files:**
- Create: `test/mocks/MockConfidentialToken.sol`
- Test: extend `test/EndowmentNFT.t.sol` (new file, harness section)

**Interfaces:**
- Consumes: `ERC7984` (OZ), `FHE`, `CONFIG_BASE` (from Task 1).
- Produces: `MockConfidentialToken` with `constructor()` and `mint(address to, uint64 amount)`; proves `forge-fhevm` encrypt/decrypt works end to end.

> **Verification note:** OZ `ERC7984`'s constructor and `_mint` signatures are pinned to `@openzeppelin/confidential-contracts@0.4.1`. The code below uses the expected forms `constructor(string name_, string symbol_, string uri_)` and `_mint(address to, euint64 amount) returns (euint64)`. If `forge build` errors on these, open `node_modules/@openzeppelin/confidential-contracts/contracts/token/ERC7984/ERC7984.sol`, copy the actual `constructor` and `_mint` signatures, and adjust. Do not guess past a compile error — read the file.

- [ ] **Step 1: Write the mock**

`test/mocks/MockConfidentialToken.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC7984} from "@openzeppelin/confidential-contracts/token/ERC7984/ERC7984.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol"; // CONFIG_BASE (Task 1)
import {FHE, euint64} from "@fhevm/solidity/lib/FHE.sol";

contract MockConfidentialToken is ERC7984, ZamaEthereumConfig {
    constructor() ERC7984("Mock Confidential", "MOCK", "") {}

    /// @dev Test/dev mint of a cleartext amount into an encrypted balance.
    function mint(address to, uint64 amount) external {
        euint64 a = FHE.asEuint64(amount);
        FHE.allowThis(a);
        _mint(to, a);
    }
}
```

- [ ] **Step 2: Write the failing harness test**

`test/EndowmentNFT.t.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FhevmTest} from "forge-fhevm/FhevmTest.sol";
import {FHE, euint64, externalEuint64} from "@fhevm/solidity/lib/FHE.sol";
import "encrypted-types/EncryptedTypes.sol";
import {MockConfidentialToken} from "./mocks/MockConfidentialToken.sol";

contract EndowmentNFTTest is FhevmTest {
    MockConfidentialToken internal token;
    address internal creator = address(0xC0FFEE);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public override {
        super.setUp();
        token = new MockConfidentialToken();
    }

    function test_harness_mintAndDecryptBalance() public {
        token.mint(creator, 1_000);
        euint64 bal = token.confidentialBalanceOf(creator);
        assertEq(decrypt(bal), 1_000);
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `forge test --match-test test_harness_mintAndDecryptBalance -vv`
Expected: FAIL initially if `decrypt` usage or imports are off, OR a compile error on `ERC7984` signatures (then apply the verification note in this task).

- [ ] **Step 4: Make it pass**

Fix any signature mismatches per the verification note until the test passes.

Run: `forge test --match-test test_harness_mintAndDecryptBalance -vv`
Expected: PASS — confirms host contracts deploy, encryption/decryption work.

- [ ] **Step 5: Commit**

```bash
git add test/mocks/MockConfidentialToken.sol test/EndowmentNFT.t.sol
git commit -m "test: mock ERC7984 token and forge-fhevm harness sanity check"
```

---

## Task 4: `EndowmentNFT` skeleton — state, constructor, `mint` + funding

**Files:**
- Create: `src/EndowmentNFT.sol`
- Test: extend `test/EndowmentNFT.t.sol`

**Interfaces:**
- Consumes: `Segment`/`Schedule` (Task 2), `IERC7984`, `FHE`, `CONFIG_BASE`, `ERC721`, `ReentrancyGuard`.
- Produces:
  - `constructor(IERC7984 token_)`
  - `mint(address to, externalEuint64 encEndowment, bytes calldata inputProof, Segment[] calldata segments, uint64 scheduleStart, bool topUpsAllowed) external returns (uint256 tokenId)`
  - `distributionHandle(uint256 tokenId) external view returns (euint64)`
  - `endowmentHandle(uint256 tokenId) external view returns (euint64)`
  - `topUpsAllowedOf(uint256 tokenId) external view returns (bool)`
  - internal `struct Endowment` and `mapping(uint256 => Endowment) _endowments`.

> **Verification note:** `IERC7984.confidentialTransferFrom(address from, address to, euint64 amount) returns (euint64 transferred)` returns the *actually transferred* encrypted amount (clamped to balance). We always store the returned handle, never the requested amount. `setOperator(address operator, uint48 until)` is the operator-approval call the funder makes first.

- [ ] **Step 1: Write the failing tests**

Add to `test/EndowmentNFT.t.sol`:
```solidity
import {EndowmentNFT} from "../src/EndowmentNFT.sol";
import {Schedule, Segment} from "../src/libraries/Schedule.sol";
import {IERC7984} from "@openzeppelin/confidential-contracts/interfaces/IERC7984.sol";

// add as a field:
//   EndowmentNFT internal nft;
// and in setUp() after token creation:
//   nft = new EndowmentNFT(IERC7984(address(token)));

function _segments() internal pure returns (Segment[] memory s) {
    s = new Segment[](1);
    s[0] = Segment({duration: 1_000, ratePerSec: 1}); // 1 unit/sec for 1000s
}

function _mintEndowment(address to, uint64 amount, bool topUps) internal returns (uint256 id) {
    token.mint(creator, amount);
    vm.prank(creator);
    token.setOperator(address(nft), uint48(block.timestamp + 365 days));
    (externalEuint64 handle, bytes memory proof) = encryptUint64(amount, creator, address(nft));
    vm.prank(creator);
    id = nft.mint(to, handle, proof, _segments(), uint64(block.timestamp), topUps);
}

function test_mint_distributionStartsZeroAndOwnerReadable() public {
    uint256 id = _mintEndowment(alice, 500, false);
    assertEq(nft.ownerOf(id), alice);
    // distribution starts at 0 and alice has ACL to read it
    euint64 dist = nft.distributionHandle(id);
    assertTrue(_acl.isAllowed(euint64.unwrap(dist), alice));
    assertEq(decrypt(dist), 0);
}

function test_mint_ownerCannotReadEndowment() public {
    uint256 id = _mintEndowment(alice, 500, false);
    euint64 endow = nft.endowmentHandle(id);
    // HEADLINE PROPERTY: owner has no ACL on the endowment handle
    assertFalse(_acl.isAllowed(euint64.unwrap(endow), alice));
    // contract itself does have access (for homomorphic ops)
    assertTrue(_acl.isAllowed(euint64.unwrap(endow), address(nft)));
}

function test_mint_pullsFundsIntoContract() public {
    uint256 id = _mintEndowment(alice, 500, false);
    id; // silence unused
    assertEq(decrypt(token.confidentialBalanceOf(address(nft))), 500);
    assertEq(decrypt(token.confidentialBalanceOf(creator)), 0);
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `forge test --match-test test_mint -vv`
Expected: FAIL — `EndowmentNFT` not found.

- [ ] **Step 3: Write `src/EndowmentNFT.sol` (skeleton + mint)**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {FHE, euint64, externalEuint64} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol"; // CONFIG_BASE (Task 1)
import {IERC7984} from "@openzeppelin/confidential-contracts/interfaces/IERC7984.sol";
import {Schedule, Segment} from "./libraries/Schedule.sol";

contract EndowmentNFT is ERC721, ReentrancyGuard, ZamaEthereumConfig {
    using Schedule for Segment[];

    struct Endowment {
        euint64 endowmentRemaining; // SECRET: ACL = contract only
        euint64 distribution;       // owner-readable: ACL = contract + current owner
        uint64 lastAccrualAt;
        uint64 scheduleStart;
        bool topUpsAllowed;
        Segment[] schedule;
    }

    IERC7984 public immutable token;
    uint256 internal _nextId;
    mapping(uint256 => Endowment) internal _endowments;

    error EmptySchedule();
    error ZeroDurationSegment();
    error TopUpsDisabled();
    error NonexistentToken();
    error NotOwner();

    constructor(IERC7984 token_) ERC721("Endowment NFT", "ENDOW") {
        token = token_;
    }

    function mint(
        address to,
        externalEuint64 encEndowment,
        bytes calldata inputProof,
        Segment[] calldata segments,
        uint64 scheduleStart,
        bool topUpsAllowed
    ) external returns (uint256 tokenId) {
        if (segments.length == 0) revert EmptySchedule();

        uint64 start = scheduleStart == 0 ? uint64(block.timestamp) : scheduleStart;

        euint64 amount = FHE.fromExternal(encEndowment, inputProof);
        FHE.allowTransient(amount, address(token));
        euint64 received = token.confidentialTransferFrom(msg.sender, address(this), amount);

        tokenId = ++_nextId;
        Endowment storage e = _endowments[tokenId];
        e.endowmentRemaining = received;
        e.distribution = FHE.asEuint64(0);
        e.lastAccrualAt = start;
        e.scheduleStart = start;
        e.topUpsAllowed = topUpsAllowed;
        for (uint256 i = 0; i < segments.length; i++) {
            if (segments[i].duration == 0) revert ZeroDurationSegment();
            e.schedule.push(segments[i]);
        }

        FHE.allowThis(e.endowmentRemaining);
        FHE.allowThis(e.distribution);
        FHE.allow(e.distribution, to);

        _safeMint(to, tokenId);
    }

    function distributionHandle(uint256 tokenId) external view returns (euint64) {
        return _endowments[tokenId].distribution;
    }

    /// @notice Exposed for transparency/tests. The returned handle is NOT decryptable
    ///         by anyone except the contract — no ACL grant is ever made to owners.
    function endowmentHandle(uint256 tokenId) external view returns (euint64) {
        return _endowments[tokenId].endowmentRemaining;
    }

    function topUpsAllowedOf(uint256 tokenId) external view returns (bool) {
        return _endowments[tokenId].topUpsAllowed;
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `forge test --match-test test_mint -vv`
Expected: PASS. If `FHE.allowTransient` is unavailable for the installed version, use `FHE.allow(amount, address(token))` instead (persistent, also correct).

- [ ] **Step 5: Commit**

```bash
git add src/EndowmentNFT.sol test/EndowmentNFT.t.sol
git commit -m "feat: EndowmentNFT mint with secret endowment funding"
```

---

## Task 5: Lazy accrual (`accrue`) with endowment cap

**Files:**
- Modify: `src/EndowmentNFT.sol`
- Test: extend `test/EndowmentNFT.t.sol`

**Interfaces:**
- Consumes: Task 4 state.
- Produces:
  - `accrue(uint256 tokenId) external` (public poke)
  - internal `_accrue(uint256 tokenId)`

- [ ] **Step 1: Write the failing tests**

```solidity
function test_accrue_movesScheduledAmount() public {
    uint256 id = _mintEndowment(alice, 500, false);
    vm.warp(block.timestamp + 100); // 100s @ 1/sec = 100
    nft.accrue(id);
    assertEq(decrypt(nft.distributionHandle(id)), 100);
}

function test_accrue_capsAtEndowmentAndExhausts() public {
    uint256 id = _mintEndowment(alice, 500, false); // endowment 500, rate 1/s, 1000s schedule
    vm.warp(block.timestamp + 1_000); // schedule would yield 1000, but endowment is 500
    nft.accrue(id);
    assertEq(decrypt(nft.distributionHandle(id)), 500); // capped
    // further accrual is a no-op (endowment exhausted)
    vm.warp(block.timestamp + 1_000);
    nft.accrue(id);
    assertEq(decrypt(nft.distributionHandle(id)), 500);
}

function test_accrue_zeroElapsedIsNoop() public {
    uint256 id = _mintEndowment(alice, 500, false);
    nft.accrue(id); // same block
    assertEq(decrypt(nft.distributionHandle(id)), 0);
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `forge test --match-test test_accrue -vv`
Expected: FAIL — `accrue` not defined.

- [ ] **Step 3: Add accrual to `src/EndowmentNFT.sol`**

```solidity
function accrue(uint256 tokenId) external {
    if (_ownerOf(tokenId) == address(0)) revert NonexistentToken();
    _accrue(tokenId);
}

function _accrue(uint256 tokenId) internal {
    Endowment storage e = _endowments[tokenId];
    uint64 nowTs = uint64(block.timestamp);
    uint64 owed = Schedule.integrate(e.schedule, e.scheduleStart, e.lastAccrualAt, nowTs);
    if (owed == 0) return;

    euint64 actual = FHE.min(FHE.asEuint64(owed), e.endowmentRemaining);
    e.endowmentRemaining = FHE.sub(e.endowmentRemaining, actual);
    e.distribution = FHE.add(e.distribution, actual);

    FHE.allowThis(e.endowmentRemaining);
    FHE.allowThis(e.distribution);
    FHE.allow(e.distribution, ownerOf(tokenId));

    uint64 end = Schedule.scheduleEnd(e.schedule, e.scheduleStart);
    e.lastAccrualAt = nowTs < end ? nowTs : end;
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `forge test --match-test test_accrue -vv`
Expected: PASS (including the exhaustion cap — proves `FHE.min` capping works and never reveals plaintext).

- [ ] **Step 5: Commit**

```bash
git add src/EndowmentNFT.sol test/EndowmentNFT.t.sol
git commit -m "feat: lazy accrual capped by encrypted endowment"
```

---

## Task 6: `claim` payout

**Files:**
- Modify: `src/EndowmentNFT.sol`
- Test: extend `test/EndowmentNFT.t.sol`

**Interfaces:**
- Consumes: Tasks 4–5.
- Produces: `claim(uint256 tokenId) external nonReentrant`.

- [ ] **Step 1: Write the failing tests**

```solidity
function test_claim_transfersAndResets() public {
    uint256 id = _mintEndowment(alice, 500, false);
    vm.warp(block.timestamp + 100); // accrue 100
    vm.prank(alice);
    nft.claim(id);
    assertEq(decrypt(token.confidentialBalanceOf(alice)), 100);
    assertEq(decrypt(token.confidentialBalanceOf(address(nft))), 400); // 500 - 100
    assertEq(decrypt(nft.distributionHandle(id)), 0); // reset
}

function test_claim_onlyOwner() public {
    uint256 id = _mintEndowment(alice, 500, false);
    vm.warp(block.timestamp + 100);
    vm.expectRevert(EndowmentNFT.NotOwner.selector);
    vm.prank(bob);
    nft.claim(id);
}

function test_claim_emptyDistributionIsNoopTransfer() public {
    uint256 id = _mintEndowment(alice, 500, false);
    vm.prank(alice);
    nft.claim(id); // nothing accrued yet
    assertEq(decrypt(token.confidentialBalanceOf(alice)), 0);
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `forge test --match-test test_claim -vv`
Expected: FAIL — `claim` not defined.

- [ ] **Step 3: Add `claim` to `src/EndowmentNFT.sol`**

```solidity
function claim(uint256 tokenId) external nonReentrant {
    if (msg.sender != ownerOf(tokenId)) revert NotOwner();
    _accrue(tokenId);

    Endowment storage e = _endowments[tokenId];
    euint64 amt = e.distribution;

    // checks-effects-interactions: zero out before the external transfer
    e.distribution = FHE.asEuint64(0);
    FHE.allowThis(e.distribution);
    FHE.allow(e.distribution, msg.sender);

    FHE.allowTransient(amt, address(token));
    token.confidentialTransfer(msg.sender, amt);
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `forge test --match-test test_claim -vv`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/EndowmentNFT.sol test/EndowmentNFT.t.sol
git commit -m "feat: owner claim payout with reentrancy guard"
```

---

## Task 7: Transfer hook — ACL handoff to new owner

**Files:**
- Modify: `src/EndowmentNFT.sol`
- Test: extend `test/EndowmentNFT.t.sol`

**Interfaces:**
- Consumes: Tasks 4–6.
- Produces: override `_update(address to, uint256 tokenId, address auth) internal returns (address)`.

- [ ] **Step 1: Write the failing tests**

```solidity
function test_transfer_newOwnerCanReadOldOwnerCannot() public {
    uint256 id = _mintEndowment(alice, 500, false);
    vm.warp(block.timestamp + 100); // accrue 100 under alice
    nft.accrue(id);

    vm.prank(alice);
    nft.transferFrom(alice, bob, id);

    euint64 dist = nft.distributionHandle(id);
    assertTrue(_acl.isAllowed(euint64.unwrap(dist), bob));   // new owner can read
    assertFalse(_acl.isAllowed(euint64.unwrap(dist), alice)); // old owner cannot read post-transfer handle
    assertEq(nft.ownerOf(id), bob);
}

function test_transfer_unclaimedTravelsAndAccrualContinues() public {
    uint256 id = _mintEndowment(alice, 500, false);
    vm.warp(block.timestamp + 100); // 100 accrued
    nft.accrue(id);
    vm.prank(alice);
    nft.transferFrom(alice, bob, id);

    vm.warp(block.timestamp + 50); // +50 more under bob
    vm.prank(bob);
    nft.claim(id);
    // bob receives the 100 that traveled + 50 new = 150
    assertEq(decrypt(token.confidentialBalanceOf(bob)), 150);
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `forge test --match-test test_transfer -vv`
Expected: FAIL — old owner still allowed (no hook yet) / accounting wrong.

- [ ] **Step 3: Add the `_update` override to `src/EndowmentNFT.sol`**

```solidity
function _update(address to, uint256 tokenId, address auth)
    internal
    override
    returns (address from)
{
    from = super._update(to, tokenId, auth);

    // Only on real transfers (skip mint from==0 and burn to==0).
    if (from != address(0) && to != address(0)) {
        _accrue(tokenId); // settle the clock before the handoff
        Endowment storage e = _endowments[tokenId];
        // Refresh the distribution handle so the prior owner's ACL no longer applies,
        // then grant read access to the new owner only. (Covers the no-op accrue case too.)
        e.distribution = FHE.add(e.distribution, FHE.asEuint64(0));
        FHE.allowThis(e.distribution);
        FHE.allow(e.distribution, to);
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `forge test --match-test test_transfer -vv`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/EndowmentNFT.sol test/EndowmentNFT.t.sol
git commit -m "feat: ACL handoff to new owner on transfer"
```

---

## Task 8: `topUp` + mode enforcement

**Files:**
- Modify: `src/EndowmentNFT.sol`
- Test: extend `test/EndowmentNFT.t.sol`

**Interfaces:**
- Consumes: Tasks 4–7.
- Produces: `topUp(uint256 tokenId, externalEuint64 encAmount, bytes calldata inputProof) external`.

- [ ] **Step 1: Write the failing tests**

```solidity
function _topUp(uint256 id, address funder, uint64 amount) internal {
    token.mint(funder, amount);
    vm.prank(funder);
    token.setOperator(address(nft), uint48(block.timestamp + 365 days));
    (externalEuint64 h, bytes memory p) = encryptUint64(amount, funder, address(nft));
    vm.prank(funder);
    nft.topUp(id, h, p);
}

function test_topUp_extendsPayoutLifetime() public {
    uint256 id = _mintEndowment(alice, 500, true); // top-ups allowed
    _topUp(id, bob, 300); // anyone (bob) can top up -> endowment now 800
    vm.warp(block.timestamp + 1_000); // schedule yields 1000, capped by 800
    nft.accrue(id);
    assertEq(decrypt(nft.distributionHandle(id)), 800);
}

function test_topUp_revertsWhenDisabled() public {
    uint256 id = _mintEndowment(alice, 500, false); // immutable mode
    token.mint(bob, 100);
    vm.prank(bob);
    token.setOperator(address(nft), uint48(block.timestamp + 365 days));
    (externalEuint64 h, bytes memory p) = encryptUint64(100, bob, address(nft));
    vm.expectRevert(EndowmentNFT.TopUpsDisabled.selector);
    vm.prank(bob);
    nft.topUp(id, h, p);
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `forge test --match-test test_topUp -vv`
Expected: FAIL — `topUp` not defined.

- [ ] **Step 3: Add `topUp` to `src/EndowmentNFT.sol`**

```solidity
function topUp(uint256 tokenId, externalEuint64 encAmount, bytes calldata inputProof) external {
    Endowment storage e = _endowments[tokenId];
    if (_ownerOf(tokenId) == address(0)) revert NonexistentToken();
    if (!e.topUpsAllowed) revert TopUpsDisabled();

    euint64 amount = FHE.fromExternal(encAmount, inputProof);
    FHE.allowTransient(amount, address(token));
    euint64 received = token.confidentialTransferFrom(msg.sender, address(this), amount);

    e.endowmentRemaining = FHE.add(e.endowmentRemaining, received);
    FHE.allowThis(e.endowmentRemaining); // never granted to any owner
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `forge test --match-test test_topUp -vv`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/EndowmentNFT.sol test/EndowmentNFT.t.sol
git commit -m "feat: top-up mode for adding secret funds"
```

---

## Task 9: Conservation invariant test

**Files:**
- Test: extend `test/EndowmentNFT.t.sol`

**Interfaces:**
- Consumes: full contract.
- Produces: a fuzz test asserting `claimed + distribution + remaining == initial + toppedUp`.

- [ ] **Step 1: Write the failing/again-green test**

```solidity
function testFuzz_conservation(uint64 endowAmt, uint64 topAmt, uint32 warp1, uint32 warp2) public {
    endowAmt = uint64(bound(endowAmt, 1, 1_000_000));
    topAmt = uint64(bound(topAmt, 0, 1_000_000));
    uint256 id = _mintEndowment(alice, endowAmt, true);
    if (topAmt > 0) _topUp(id, bob, topAmt);

    vm.warp(block.timestamp + bound(warp1, 0, 2_000));
    nft.accrue(id);
    vm.prank(alice);
    nft.claim(id);
    uint64 claimed1 = decrypt(token.confidentialBalanceOf(alice));

    vm.warp(block.timestamp + bound(warp2, 0, 2_000));
    nft.accrue(id);

    uint64 dist = decrypt(nft.distributionHandle(id));
    uint64 remaining = decrypt(nft.endowmentHandle(id)); // test-only: decrypt() bypasses ACL
    assertEq(uint256(claimed1) + dist + remaining, uint256(endowAmt) + topAmt);
}
```

- [ ] **Step 2: Run it**

Run: `forge test --match-test testFuzz_conservation -vv`
Expected: PASS (exercises mint+topUp+accrue+claim+accrue while conserving total). `decrypt()` is the no-ACL test helper, so it can read the endowment even though no owner could.

- [ ] **Step 3: Run the full suite**

Run: `forge test -vv`
Expected: ALL pass.

- [ ] **Step 4: Commit**

```bash
git add test/EndowmentNFT.t.sol
git commit -m "test: conservation invariant fuzz"
```

---

## Task 10: Deploy script (local + Sepolia)

**Files:**
- Create: `script/Deploy.s.sol`

**Interfaces:**
- Consumes: `MockConfidentialToken`, `EndowmentNFT`.
- Produces: a Forge script deploying the token (optional) + `EndowmentNFT`.

> **Network-config note:** `script/Deploy.s.sol` and the deployed contracts inherit `CONFIG_BASE` (Task 1). Confirm `CONFIG_BASE` matches the **Sepolia** network in your pinned `@fhevm/solidity` version. For local (`forge-fhevm` / Anvil) tests the config is cosmetic; for live Sepolia it selects the real host-contract addresses, so it must be correct.

- [ ] **Step 1: Move the mock to a deployable location**

The deploy script needs a concrete token. Either deploy an existing Sepolia confidential token (set `TOKEN_ADDRESS` env) or deploy `MockConfidentialToken`. To deploy the mock outside tests, copy it to `src/`:

```bash
mkdir -p src/mocks
cp test/mocks/MockConfidentialToken.sol src/mocks/MockConfidentialToken.sol
```
(Update the test import in `test/EndowmentNFT.t.sol` to `import {MockConfidentialToken} from "../src/mocks/MockConfidentialToken.sol";` and re-run `forge test` to confirm green.)

- [ ] **Step 2: Write `script/Deploy.s.sol`**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {EndowmentNFT} from "../src/EndowmentNFT.sol";
import {MockConfidentialToken} from "../src/mocks/MockConfidentialToken.sol";
import {IERC7984} from "@openzeppelin/confidential-contracts/interfaces/IERC7984.sol";

contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address existingToken = vm.envOr("TOKEN_ADDRESS", address(0));

        vm.startBroadcast(pk);
        address tokenAddr = existingToken;
        if (tokenAddr == address(0)) {
            MockConfidentialToken token = new MockConfidentialToken();
            tokenAddr = address(token);
            console.log("MockConfidentialToken:", tokenAddr);
        }
        EndowmentNFT nft = new EndowmentNFT(IERC7984(tokenAddr));
        console.log("EndowmentNFT:", address(nft));
        vm.stopBroadcast();
    }
}
```

- [ ] **Step 3: Dry-run locally**

Run: `forge script script/Deploy.s.sol --sig "run()"`
Expected: compiles and simulates, logging two addresses.

- [ ] **Step 4: Document the live Sepolia command (no broadcast in this step)**

The live command (run later, by the operator, with a funded key) is:
```bash
forge script script/Deploy.s.sol --rpc-url sepolia --broadcast --private-key $PRIVATE_KEY
```

- [ ] **Step 5: Commit**

```bash
git add script/Deploy.s.sol src/mocks/MockConfidentialToken.sol test/EndowmentNFT.t.sol
git commit -m "feat: deploy script for token + EndowmentNFT"
```

---

## Task 11: TypeScript client for Sepolia (relayer-sdk)

**Files:**
- Create: `client/package.json`, `client/tsconfig.json`, `client/.env.example`, `client/src/instance.ts`, `client/src/mint.ts`, `client/src/accrue.ts`, `client/src/claim.ts`, `client/src/decryptDistribution.ts`, `client/src/tryDecryptEndowment.ts`

**Interfaces:**
- Consumes: deployed `EndowmentNFT` + token addresses (env), the contract ABI (from `out/`).
- Produces: runnable scripts for the live Sepolia flow + the negative-decrypt proof.

> These scripts are exercised manually on Sepolia (no `vm.warp` on a live chain — use small real-time rates). They are not part of `forge test`.

- [ ] **Step 1: Write `client/package.json`**

```json
{
  "name": "endowment-nft-client",
  "private": true,
  "type": "module",
  "scripts": {
    "mint": "tsx src/mint.ts",
    "accrue": "tsx src/accrue.ts",
    "claim": "tsx src/claim.ts",
    "decrypt": "tsx src/decryptDistribution.ts",
    "try-endow": "tsx src/tryDecryptEndowment.ts"
  },
  "dependencies": {
    "@zama-fhe/relayer-sdk": "0.4.4",
    "ethers": "^6.13.0"
  },
  "devDependencies": { "tsx": "^4.16.0", "typescript": "^5.5.0" }
}
```

- [ ] **Step 2: Write `client/.env.example` and `client/tsconfig.json`**

`.env.example`:
```
SEPOLIA_RPC_URL=
PRIVATE_KEY=
NFT_ADDRESS=
TOKEN_ADDRESS=
TOKEN_ID=
```
`tsconfig.json`:
```json
{ "compilerOptions": { "target": "ES2022", "module": "ESNext", "moduleResolution": "bundler", "strict": true, "esModuleInterop": true, "skipLibCheck": true } }
```

- [ ] **Step 3: Write `client/src/instance.ts` (shared setup)**

```ts
import { createInstance } from "@zama-fhe/relayer-sdk/node";
import { JsonRpcProvider, Wallet } from "ethers";

export async function setup() {
  const provider = new JsonRpcProvider(process.env.SEPOLIA_RPC_URL!);
  const wallet = new Wallet(process.env.PRIVATE_KEY!, provider);
  // The SDK ships a Sepolia preset config object; load it per the installed
  // @zama-fhe/relayer-sdk@0.4.4 docs (e.g. `import { SepoliaConfig } from
  // "@zama-fhe/relayer-sdk/node"`), then:
  const instance = await createInstance(/* SepoliaConfig */ {} as any);
  return { provider, wallet, instance };
}
```
> Replace the placeholder config with the exact preset exported by the installed SDK (confirm the export name in `node_modules/@zama-fhe/relayer-sdk`). This is the one client-side value not pinned verbatim in this plan.

- [ ] **Step 4: Write `client/src/mint.ts`**

```ts
import { Contract } from "ethers";
import { setup } from "./instance.js";

const ABI = [
  "function mint(address to, bytes32 encEndowment, bytes inputProof, (uint64 duration, uint64 ratePerSec)[] segments, uint64 scheduleStart, bool topUpsAllowed) returns (uint256)"
];
const TOKEN_ABI = ["function setOperator(address operator, uint48 until)"];

async function main() {
  const { wallet, instance } = await setup();
  const nft = process.env.NFT_ADDRESS!;
  const amount = 1_000_000n; // base units of endowment

  // 1) approve the NFT as operator on the confidential token
  const token = new Contract(process.env.TOKEN_ADDRESS!, TOKEN_ABI, wallet);
  const until = Math.floor(Date.now() / 1000) + 365 * 24 * 3600;
  await (await token.setOperator(nft, until)).wait();

  // 2) build the encrypted endowment input bound to (nft, funder)
  const enc = await instance
    .createEncryptedInput(nft, wallet.address)
    .add64(amount)
    .encrypt();

  // 3) mint: 1 unit/sec for 1 hour
  const segments = [{ duration: 3600n, ratePerSec: 1n }];
  const c = new Contract(nft, ABI, wallet);
  const tx = await c.mint(
    wallet.address, enc.handles[0], enc.inputProof, segments, 0n, true
  );
  console.log("mint tx:", (await tx.wait())?.hash);
}
main();
```

- [ ] **Step 5: Write `client/src/accrue.ts` and `client/src/claim.ts`**

`accrue.ts`:
```ts
import { Contract } from "ethers";
import { setup } from "./instance.js";
const ABI = ["function accrue(uint256 tokenId)"];
async function main() {
  const { wallet } = await setup();
  const c = new Contract(process.env.NFT_ADDRESS!, ABI, wallet);
  console.log("accrue:", (await (await c.accrue(BigInt(process.env.TOKEN_ID!))).wait())?.hash);
}
main();
```
`claim.ts`:
```ts
import { Contract } from "ethers";
import { setup } from "./instance.js";
const ABI = ["function claim(uint256 tokenId)"];
async function main() {
  const { wallet } = await setup();
  const c = new Contract(process.env.NFT_ADDRESS!, ABI, wallet);
  console.log("claim:", (await (await c.claim(BigInt(process.env.TOKEN_ID!))).wait())?.hash);
}
main();
```

- [ ] **Step 6: Write `client/src/decryptDistribution.ts` (user-decryption)**

```ts
import { Contract } from "ethers";
import { setup } from "./instance.js";
const ABI = ["function distributionHandle(uint256 tokenId) view returns (bytes32)"];

async function main() {
  const { wallet, instance } = await setup();
  const nft = process.env.NFT_ADDRESS!;
  const c = new Contract(nft, ABI, wallet);
  const handle: string = await c.distributionHandle(BigInt(process.env.TOKEN_ID!));

  const { publicKey, privateKey } = instance.generateKeypair();
  const start = Math.floor(Date.now() / 1000);
  const days = 1;
  const eip712 = instance.createEIP712(publicKey, [nft], start, days);
  const signature = await wallet.signTypedData(
    eip712.domain, { [eip712.primaryType]: eip712.types[eip712.primaryType] }, eip712.message
  );
  const res = await instance.userDecrypt(
    [{ handle, contractAddress: nft }],
    privateKey, publicKey, signature, [nft], wallet.address, start, days
  );
  console.log("distribution =", res[handle]);
}
main();
```
> Confirm the exact `userDecrypt` argument order and the EIP-712 typed-data shape against the installed `@zama-fhe/relayer-sdk@0.4.4` types (`node_modules/@zama-fhe/relayer-sdk/lib/node.d.ts`); adjust if the SDK differs.

- [ ] **Step 7: Write `client/src/tryDecryptEndowment.ts` (negative proof)**

```ts
import { Contract } from "ethers";
import { setup } from "./instance.js";
const ABI = ["function endowmentHandle(uint256 tokenId) view returns (bytes32)"];

async function main() {
  const { wallet, instance } = await setup();
  const nft = process.env.NFT_ADDRESS!;
  const c = new Contract(nft, ABI, wallet);
  const handle: string = await c.endowmentHandle(BigInt(process.env.TOKEN_ID!));
  const { publicKey, privateKey } = instance.generateKeypair();
  const start = Math.floor(Date.now() / 1000);
  const eip712 = instance.createEIP712(publicKey, [nft], start, 1);
  const signature = await wallet.signTypedData(
    eip712.domain, { [eip712.primaryType]: eip712.types[eip712.primaryType] }, eip712.message
  );
  try {
    await instance.userDecrypt(
      [{ handle, contractAddress: nft }],
      privateKey, publicKey, signature, [nft], wallet.address, start, 1
    );
    console.error("FAIL: endowment was decryptable — privacy broken!");
    process.exit(1);
  } catch {
    console.log("PASS: endowment is NOT decryptable by the owner (as designed).");
  }
}
main();
```

- [ ] **Step 8: Type-check the client**

Run:
```bash
cd client && npm install && npx tsc --noEmit ; cd ..
```
Expected: type-checks (after filling the SDK config in `instance.ts`). Note any `any` left for the config preset.

- [ ] **Step 9: Commit**

```bash
git add client
git commit -m "feat: TypeScript relayer-sdk client for Sepolia flows"
```

---

## Task 12: README & final verification

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: everything.
- Produces: build/test/deploy/run docs.

- [ ] **Step 1: Write `README.md`**

Include: overview (link the spec), prerequisites (Foundry, Node, an FHEVM-compatible Sepolia RPC), `forge build`, `forge test`, the local deploy dry-run, the live Sepolia deploy command, and the client flow (`setOperator` → `mint` → wait → `accrue` → `decrypt` → `claim` → `try-endow`). Document the operator precondition and the two creator modes (immutable / top-ups-allowed). State the privacy model: endowment hidden from owner and public; exhaustion observable only retroactively by the owner; original creator knows the initial amount in immutable mode.

- [ ] **Step 2: Run the full Foundry suite one last time**

Run: `forge test -vvv`
Expected: ALL tests pass.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: README with build, test, deploy, and client usage"
```

---

## Self-Review (completed by plan author)

**Spec coverage:** ERC-721 ✓(T4,T7), confidential-token value medium ✓(T3,T4), secret endowment + ACL discipline ✓(T4 headline test), owner-readable distribution ✓(T4), piecewise-linear accrual ✓(T2,T5), endowment cap/exhaustion via `FHE.min` ✓(T5), claim payout ✓(T6), everything-travels-on-transfer + ACL handoff ✓(T7), permissionless mint ✓(T4), two creator modes / top-ups-by-anyone ✓(T8), under-funding safety (use returned handle) ✓(T4,T8), conservation invariant ✓(T9), local Anvil/forge-fhevm testing ✓(T3–T9), Sepolia deploy + relayer-sdk client + negative-decrypt proof ✓(T10,T11). All spec sections map to tasks.

**Placeholder scan:** No "TBD/TODO". The three genuinely version-dependent values (FHE config base-contract name, OZ `ERC7984` constructor/`_mint` signatures, relayer-sdk Sepolia config preset) are each handled with an explicit "read the installed file and adjust" verification step rather than a vague placeholder, because they vary by patch version and must be confirmed against `node_modules` at implementation time.

**Type consistency:** `Segment{uint64 duration; uint64 ratePerSec}` consistent across Schedule, contract, tests, script, client. `euint64` handles throughout. `confidentialTransferFrom`/`confidentialTransfer` return handles captured as `received`/used as `amt`. Function names (`mint`, `accrue`, `claim`, `topUp`, `distributionHandle`, `endowmentHandle`, `topUpsAllowedOf`) consistent across tasks and client ABIs. Errors (`EmptySchedule`, `ZeroDurationSegment`, `TopUpsDisabled`, `NonexistentToken`, `NotOwner`) defined in T4 and referenced in T6/T8 tests.
