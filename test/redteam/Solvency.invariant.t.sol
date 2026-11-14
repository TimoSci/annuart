// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/console.sol";
import {IERC7984} from "@openzeppelin/confidential-contracts/interfaces/IERC7984.sol";
import {externalEuint64} from "encrypted-types/EncryptedTypes.sol";
import {HCULimit} from "@fhevm/host-contracts/contracts/HCULimit.sol";
import {EmptyUUPSProxy} from "@fhevm/host-contracts/contracts/emptyProxy/EmptyUUPSProxy.sol";
import {hcuLimitAdd} from "@fhevm/host-contracts/addresses/FHEVMHostAddresses.sol";
import {RedTeamBase} from "./RedTeamBase.sol";
import {EndowmentNFT} from "../../src/EndowmentNFT.sol";
import {AutoPayoutEndowmentNFT} from "../../src/AutoPayoutEndowmentNFT.sol";
import {Segment, INDEFINITE} from "../../src/libraries/Schedule.sol";

/// @dev Test-only HCULimit that removes the per-block, per-transaction and depth HCU caps.
///      forge-fhevm already ships {HCULimitNoDepthCap} and a `disableHCUDepthLimit()` helper
///      for exactly this purpose (heavy orchestration over many ops in one transaction); this
///      goes one step further and also lifts the block/tx totals, because the solvency harness
///      drives thousands of FHE operations where a production call would do a handful. Whether
///      a single real call stays under the HCU limits on Sepolia is hypothesis C5-3, out of
///      scope for the solvency invariant. Every enforcement routes through these four virtual
///      hooks, so no-oping them disables all three caps without touching the vendored code.
contract HCUUnlimited is HCULimit {
    function _adjustAndCheckFheTransactionLimitOneOp(uint256, address, bytes32, bytes32)
        internal
        virtual
        override
    {}

    function _adjustAndCheckFheTransactionLimitTwoOps(uint256, address, bytes32, bytes32, bytes32)
        internal
        virtual
        override
    {}

    function _adjustAndCheckFheTransactionLimitThreeOps(uint256, address, bytes32, bytes32, bytes32, bytes32)
        internal
        virtual
        override
    {}

    function _updateAndVerifyHCUTransactionLimit(uint256, address) internal virtual override {}
}

/// @dev Task 4 of the red team: the solvency invariant. Under randomised sequences of
///      operations over BOTH NFT contracts (EndowmentNFT over the mock token, and
///      AutoPayoutEndowmentNFT over cWETH-over-WETH), neither contract may ever pay out or
///      lock more than was put in. After every call the four properties of the brief are
///      checked by decrypting all handles with the test oracle:
///
///        (P1) contract token balance >= Sum(endowmentRemaining + distribution) over its tokens;
///        (P2) deposited == paidOut + pendingPayouts + balanceHeld, per contract;
///        (P3) no token has paid out more than was deposited into it;
///        (P4) the automatic contract's ETH and WETH balances are zero when nothing pending.
///
///      "deposited" is tracked from the actual `received` each mint/topUp moved (the pool
///      balance delta), and "paidOut" from what each claim / finalised payout actually paid.
///
///      HARNESS NOTE (reported in full in task-4-report.md): the brief warned Foundry's native
///      stateful invariant runner might not drive the forge-fhevm mock. It does here: it
///      decrypts inside the invariant function and resets state between runs, so SolvencyModel
///      is driven by that runner (SolvencyInvariantTest). SolvencyCensusTest drives the same
///      handlers deterministically in one invocation to record per-handler call/revert/skip
///      counts and guard against a dead handler. The only harness relaxation is lifting the
///      mock's HCU caps (above), which belong to C5-3, not to solvency.
abstract contract SolvencyModel is RedTeamBase {
    // ---- contract selectors -------------------------------------------------
    uint256 internal constant ENFT = 0; // EndowmentNFT over the mock token
    uint256 internal constant APNFT = 1; // AutoPayoutEndowmentNFT over cWETH

    // ---- handler ids --------------------------------------------------------
    uint256 internal constant H_MINT = 0;
    uint256 internal constant H_MINTAUTO = 1;
    uint256 internal constant H_TOPUP = 2;
    uint256 internal constant H_ACCRUE = 3;
    uint256 internal constant H_CLAIM = 4;
    uint256 internal constant H_TRANSFER = 5;
    uint256 internal constant H_SETAUTO = 6;
    uint256 internal constant H_REQUEST = 7;
    uint256 internal constant H_FINALIZE = 8;
    uint256 internal constant H_WARP = 9;
    uint256 internal constant NUM_HANDLERS = 10;

    // ---- bounds (kept well under uint64 so no full-supply silent-zero noise) --
    uint64 internal constant MAX_AMOUNT = 1_000_000;
    uint64 internal constant FUND_UNITS = 2_000_000_000; // per actor, per token
    uint256 internal constant MAX_LIVE = 8; // live tokens per contract (census cap)

    address[4] internal actors;
    address[2] internal payActors; // extra requester/finaliser identities

    // ---- bookkeeping, token units -------------------------------------------
    mapping(uint256 => uint256) internal deposited; // [contract] -> units
    mapping(uint256 => uint256) internal paidOut; // [contract] -> units
    mapping(uint256 => mapping(uint256 => uint256)) internal depositedTok; // [contract][id]
    mapping(uint256 => mapping(uint256 => uint256)) internal paidOutTok; // [contract][id]
    mapping(uint256 => uint256[]) internal liveIds; // [contract] -> ids
    mapping(uint256 => mapping(uint256 => bool)) internal known; // [contract][id]

    // ---- handler census -----------------------------------------------------
    uint256[NUM_HANDLERS] internal calls;
    uint256[NUM_HANDLERS] internal reverts;
    uint256[NUM_HANDLERS] internal skips;

    // =========================================================================
    // Deployment / funding
    // =========================================================================

    function setUp() public virtual override {
        super.setUp();
        _liftHCUCaps();
        actors = [alice, bob, mallory, creator];
        payActors = [keeper, donor];
        _fundActors();
    }

    /// @dev Upgrades the mock HCULimit (behind its UUPS proxy, owned by PROXY_OWNER) to a
    ///      cap-free test implementation, the same upgrade mechanism forge-fhevm uses for
    ///      disableHCUDepthLimit(). The solvency invariant is about conservation of funds, not
    ///      per-call compute budgets (C5-3).
    function _liftHCUCaps() internal {
        address impl = address(new HCUUnlimited());
        vm.prank(PROXY_OWNER);
        EmptyUUPSProxy(payable(hcuLimitAdd)).upgradeToAndCall(impl, "");
    }

    /// @dev Funds every actor in both tokens and authorises both NFT contracts as operators.
    function _fundActors() internal {
        for (uint256 i = 0; i < actors.length; i++) {
            address a = actors[i];
            _fundMock(a, FUND_UNITS);
            _fundCweth(a, FUND_UNITS);
            _authorise(a, enft);
            _authorise(a, EndowmentNFT(address(apnft)));
        }
    }

    // =========================================================================
    // Small helpers
    // =========================================================================

    function _nft(uint256 c) internal view returns (EndowmentNFT) {
        return c == ENFT ? enft : EndowmentNFT(address(apnft));
    }

    function _token(uint256 c) internal view returns (IERC7984) {
        return c == ENFT ? IERC7984(address(mock)) : IERC7984(address(cweth));
    }

    function _pool(uint256 c) internal returns (uint64) {
        return _bal(_token(c), address(_nft(c)));
    }

    function _rng(uint256 s) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(s)));
    }

    function _between(uint256 r, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (hi <= lo) return lo;
        return lo + (r % (hi - lo + 1));
    }

    function _actor(uint256 r) internal view returns (address) {
        return actors[r % actors.length];
    }

    function _payActor(uint256 r) internal view returns (address) {
        // Any address may request/finalise; mix dedicated identities with the actors.
        uint256 k = r % (actors.length + payActors.length);
        return k < actors.length ? actors[k] : payActors[k - actors.length];
    }

    function _register(uint256 c, uint256 id) internal {
        if (!known[c][id]) {
            known[c][id] = true;
            liveIds[c].push(id);
        }
    }

    // =========================================================================
    // Core driver: run one bounded random sequence of `depth` steps, checking the
    // invariants after every call.
    // =========================================================================

    function _runSequence(uint256 seed, uint256 depth) internal {
        uint256 rng = _rng(seed);
        for (uint256 step = 0; step < depth; step++) {
            // Each step in its own block so the FHE mock's per-block HCU meter resets; an
            // individual production call stays well under the cap, it is only the stress
            // harness that piles many into one block. HCU limits are C5-3's concern, not
            // solvency's.
            vm.roll(block.number + 1);
            rng = _rng(rng);
            uint256 h = rng % NUM_HANDLERS;
            calls[h]++;
            _dispatch(h, rng);
            _checkInvariants(seed, step);
        }
    }

    /// @dev External entry so a caller can run one sequence in a fresh call frame; EVM memory
    ///      never frees within a frame, so a long census must split sequences across calls.
    ///      Storage (counters, bookkeeping) persists across these calls.
    function runSequenceExternal(uint256 seed, uint256 depth) external {
        _runSequence(seed, depth);
    }

    function _dispatch(uint256 h, uint256 rng) internal {
        if (h == H_MINT) {
            _hMint(rng);
        } else if (h == H_MINTAUTO) {
            _hMintAuto(rng);
        } else if (h == H_TOPUP) {
            _hTopUp(rng);
        } else if (h == H_ACCRUE) {
            _hAccrue(rng);
        } else if (h == H_CLAIM) {
            _hClaim(rng);
        } else if (h == H_TRANSFER) {
            _hTransfer(rng);
        } else if (h == H_SETAUTO) {
            _hSetAuto(rng);
        } else if (h == H_REQUEST) {
            _hRequest(rng);
        } else if (h == H_FINALIZE) {
            _hFinalize(rng);
        } else {
            _hWarp(rng);
        }
    }

    // =========================================================================
    // Handlers. Each guards its own reverts with try/catch so the driver never
    // reverts, and records deposits / payouts from decrypted values on success.
    // =========================================================================

    /// @dev Builds a random schedule from `r`.
    function _schedule(uint256 r) internal pure returns (Segment[] memory s) {
        if (r % 4 == 0) {
            // indefinite stream
            s = new Segment[](1);
            s[0] = Segment({duration: INDEFINITE, ratePerSec: uint64(_between(_rng(r), 1, 100))});
        } else if (r % 4 == 1) {
            // two fixed segments
            s = new Segment[](2);
            s[0] = Segment({duration: uint64(_between(_rng(r), 50, 2000)), ratePerSec: uint64(_between(_rng(r + 1), 1, 50))});
            s[1] = Segment({duration: uint64(_between(_rng(r + 2), 50, 2000)), ratePerSec: uint64(_between(_rng(r + 3), 1, 50))});
        } else {
            // one fixed segment
            s = new Segment[](1);
            s[0] = Segment({duration: uint64(_between(_rng(r), 50, 4000)), ratePerSec: uint64(_between(_rng(r + 1), 1, 100))});
        }
    }

    function _startTime(uint256 r) internal view returns (uint64) {
        // Mostly "now"; sometimes a little in the future to exercise ScheduleNotStarted.
        if (r % 8 == 0) return uint64(block.timestamp + _between(r, 1, 3000));
        return uint64(block.timestamp);
    }

    function _hMint(uint256 rng) internal {
        if (!_makeRoom(ENFT)) {
            skips[H_MINT]++;
            return;
        }
        address from = _actor(rng);
        address to = _actor(_rng(rng ^ 0x1));
        uint64 amount = uint64(_between(_rng(rng ^ 0x2), 1, MAX_AMOUNT));
        Segment[] memory segs = _schedule(_rng(rng ^ 0x3));
        uint64 start = _startTime(_rng(rng ^ 0x4));
        bool topUps = (rng & 0x20) != 0;

        uint64 before = _pool(ENFT);
        (externalEuint64 h, bytes memory p) = _enc(amount, from, address(enft));
        vm.prank(from);
        try enft.mint(to, h, p, segs, start, topUps, bytes32(0)) returns (uint256 id) {
            uint64 afterBal = _pool(ENFT);
            uint256 received = afterBal - before;
            deposited[ENFT] += received;
            depositedTok[ENFT][id] += received;
            _register(ENFT, id);
        } catch {
            reverts[H_MINT]++;
        }
    }

    function _hMintAuto(uint256 rng) internal {
        if (!_makeRoom(APNFT)) {
            skips[H_MINTAUTO]++;
            return;
        }
        address from = _actor(rng);
        address to = _actor(_rng(rng ^ 0x1));
        uint64 amount = uint64(_between(_rng(rng ^ 0x2), 1, MAX_AMOUNT));
        Segment[] memory segs = _schedule(_rng(rng ^ 0x3));
        uint64 start = _startTime(_rng(rng ^ 0x4));
        bool topUps = (rng & 0x20) != 0;
        bool enabled = (rng & 0x40) != 0;
        uint128 fee = _randFee(_rng(rng ^ 0x5));

        uint32 interval = apnft.MIN_INTERVAL();
        uint64 before = _pool(APNFT);
        (externalEuint64 h, bytes memory p) = _enc(amount, from, address(apnft));
        vm.prank(from);
        try apnft.mintAuto(to, h, p, segs, start, topUps, bytes32(0), enabled, interval, fee) returns (uint256 id) {
            uint64 afterBal = _pool(APNFT);
            uint256 received = afterBal - before;
            deposited[APNFT] += received;
            depositedTok[APNFT][id] += received;
            _register(APNFT, id);
        } catch {
            reverts[H_MINTAUTO]++;
        }
    }

    function _randFee(uint256 r) internal pure returns (uint128) {
        if (r % 3 == 0) return uint128(_between(r, 0, 1_000_000)); // small
        if (r % 3 == 1) return type(uint128).max; // force the 10% cap
        return uint128(_between(r, 0, 1e15)); // mid
    }

    function _hTopUp(uint256 rng) internal {
        uint256 c = rng & 1;
        uint256 id = _findTopUpable(c, rng);
        if (id == 0) {
            skips[H_TOPUP]++;
            return;
        }
        address from = _actor(_rng(rng ^ 0x7));
        uint64 amount = uint64(_between(_rng(rng ^ 0x8), 1, MAX_AMOUNT));

        uint64 before = _pool(c);
        (externalEuint64 h, bytes memory p) = _enc(amount, from, address(_nft(c)));
        vm.prank(from);
        try _nft(c).topUp(id, h, p) {
            uint64 afterBal = _pool(c);
            uint256 received = afterBal - before;
            deposited[c] += received;
            depositedTok[c][id] += received;
        } catch {
            reverts[H_TOPUP]++;
        }
    }

    function _hAccrue(uint256 rng) internal {
        uint256 c = rng & 1;
        uint256 id = _anyLive(c, rng);
        if (id == 0) {
            skips[H_ACCRUE]++;
            return;
        }
        try _nft(c).accrue(id) {} catch {
            reverts[H_ACCRUE]++;
        }
    }

    function _hClaim(uint256 rng) internal {
        uint256 c = rng & 1;
        uint256 id = _anyLive(c, rng);
        if (id == 0) {
            skips[H_CLAIM]++;
            return;
        }
        address owner = _nft(c).ownerOf(id);
        uint64 before = _pool(c);
        vm.prank(owner);
        try _nft(c).claim(id) {
            uint64 afterBal = _pool(c);
            uint256 paid = before - afterBal;
            paidOut[c] += paid;
            paidOutTok[c][id] += paid;
        } catch {
            reverts[H_CLAIM]++;
        }
    }

    function _hTransfer(uint256 rng) internal {
        uint256 c = rng & 1;
        uint256 id = _anyLive(c, rng);
        if (id == 0) {
            skips[H_TRANSFER]++;
            return;
        }
        address owner = _nft(c).ownerOf(id);
        address to = _actor(_rng(rng ^ 0x9));
        if (to == owner) to = _actor(_rng(rng ^ 0xA));
        vm.prank(owner);
        try _nft(c).transferFrom(owner, to, id) {} catch {
            reverts[H_TRANSFER]++;
        }
    }

    function _hSetAuto(uint256 rng) internal {
        uint256 id = _anyLive(APNFT, rng);
        if (id == 0) {
            skips[H_SETAUTO]++;
            return;
        }
        address owner = apnft.ownerOf(id);
        bool enabled = (rng & 0x80) == 0; // bias to enabled, feeds the payout path
        uint128 fee = _randFee(_rng(rng ^ 0xB));
        uint32 interval = apnft.MIN_INTERVAL();
        vm.prank(owner);
        try apnft.setAutoPayout(id, enabled, interval, fee) {} catch {
            reverts[H_SETAUTO]++;
        }
    }

    function _hRequest(uint256 rng) internal {
        uint256 id = _findDue(rng);
        if (id == 0) {
            skips[H_REQUEST]++;
            return;
        }
        // Realise any pending accrual so the unwrap burns a non-zero amount. A zero-amount
        // unwrap is pointless, and its request-id handle (the ciphertext of a zero burn) can
        // collide with another zero burn and trip the wrapper's uniqueness assert; that is
        // C2-7's territory, not solvency's, so steer clear of it here.
        apnft.accrue(id);
        if (_dist(EndowmentNFT(address(apnft)), id) == 0) {
            skips[H_REQUEST]++;
            return;
        }
        address who = _payActor(_rng(rng ^ 0xC));
        vm.prank(who);
        try apnft.requestPayout(id, 0) {} catch {
            reverts[H_REQUEST]++;
        }
    }

    function _hFinalize(uint256 rng) internal {
        uint256 id = _findPending(rng);
        if (id == 0) {
            skips[H_FINALIZE]++;
            return;
        }
        (bytes32 rid,,,) = apnft.pendingPayoutOf(id);
        uint64 cleartext = uint64(decrypt(rid));
        bytes memory proof = buildDecryptionProof(rid, abi.encode(cleartext));
        address who = _payActor(_rng(rng ^ 0xD));
        vm.prank(who);
        try apnft.finalizePayout(id, cleartext, proof) {
            // The cWETH left the pool at requestPayout; finalize converts the pending amount
            // into a realised payout, in cWETH units.
            paidOut[APNFT] += cleartext;
            paidOutTok[APNFT][id] += cleartext;
        } catch {
            reverts[H_FINALIZE]++;
        }
    }

    function _hWarp(uint256 rng) internal {
        uint256 delta;
        uint256 k = rng % 3;
        if (k == 0) {
            delta = _between(_rng(rng ^ 0xE), 1, 600); // sub-interval
        } else if (k == 1) {
            delta = _between(_rng(rng ^ 0xE), 600, 4000); // around a segment
        } else {
            delta = _between(_rng(rng ^ 0xE), 3600, 10000); // >= MIN_INTERVAL, enables payouts
        }
        vm.warp(block.timestamp + delta);
    }

    // =========================================================================
    // Token selection
    // =========================================================================

    function _anyLive(uint256 c, uint256 rng) internal view returns (uint256) {
        uint256 n = liveIds[c].length;
        if (n == 0) return 0;
        return liveIds[c][rng % n];
    }

    function _findTopUpable(uint256 c, uint256 rng) internal view returns (uint256) {
        uint256 n = liveIds[c].length;
        if (n == 0) return 0;
        uint256 off = rng % n;
        for (uint256 i = 0; i < n; i++) {
            uint256 id = liveIds[c][(off + i) % n];
            // forge-lint: disable-next-line(block-timestamp)
            if (_nft(c).topUpsAllowedOf(id) && block.timestamp < _nft(c).scheduleEndOf(id)) {
                return id;
            }
        }
        return 0;
    }

    function _findDue(uint256 rng) internal view returns (uint256) {
        uint256 n = liveIds[APNFT].length;
        if (n == 0) return 0;
        uint256 off = rng % n;
        for (uint256 i = 0; i < n; i++) {
            uint256 id = liveIds[APNFT][(off + i) % n];
            if (apnft.payoutDue(id)) return id;
        }
        return 0;
    }

    function _findPending(uint256 rng) internal view returns (uint256) {
        uint256 n = liveIds[APNFT].length;
        if (n == 0) return 0;
        uint256 off = rng % n;
        for (uint256 i = 0; i < n; i++) {
            uint256 id = liveIds[APNFT][(off + i) % n];
            (bytes32 rid,,,) = apnft.pendingPayoutOf(id);
            if (rid != bytes32(0)) return id;
        }
        return 0;
    }

    /// @dev Ensures the contract has room for one more live token, retiring a fully-settled,
    ///      fully-paid token if at the cap. A retired token contributes 0 to every property,
    ///      so dropping it from the live set leaves the global accounting unchanged.
    function _makeRoom(uint256 c) internal returns (bool) {
        if (liveIds[c].length < MAX_LIVE) return true;
        uint256 n = liveIds[c].length;
        for (uint256 i = 0; i < n; i++) {
            uint256 id = liveIds[c][i];
            bool pending = false;
            if (c == APNFT) {
                (bytes32 rid,,,) = apnft.pendingPayoutOf(id);
                pending = rid != bytes32(0);
            }
            if (!pending && _nft(c).settledOf(id) && _dist(_nft(c), id) == 0) {
                // fully drained: remaining 0, distribution 0, nothing in flight
                require(paidOutTok[c][id] == depositedTok[c][id], "retire: token not fully paid");
                liveIds[c][i] = liveIds[c][n - 1];
                liveIds[c].pop();
                return true;
            }
        }
        return false;
    }

    // =========================================================================
    // The invariant: the four properties, checked after every call.
    // =========================================================================

    function _checkInvariants(uint256 seed, uint256 step) internal {
        _checkContract(ENFT, seed, step);
        _checkContract(APNFT, seed, step);
    }

    function _checkContract(uint256 c, uint256 seed, uint256 step) internal {
        uint256 pool = _pool(c);
        uint256 sumOwed = 0;
        uint256 pending = 0;
        bool anyPending = false;

        uint256[] storage ids = liveIds[c];
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            uint256 rem = _endow(_nft(c), id);
            uint256 dist = _dist(_nft(c), id);
            sumOwed += rem + dist;

            // (P3) no token has paid out more than was deposited into it
            if (paidOutTok[c][id] > depositedTok[c][id]) {
                _fail(c, seed, step, id, "P3 over-payout per token");
            }

            if (c == APNFT) {
                (bytes32 rid,,,) = apnft.pendingPayoutOf(id);
                if (rid != bytes32(0)) {
                    anyPending = true;
                    pending += decrypt(rid);
                }
            }
        }

        // (P1) the contract's token balance backs everything it still owes
        if (pool < sumOwed) {
            _fail(c, seed, step, 0, "P1 balance below owed");
        }

        // (P2) deposited == paidOut + pendingPayouts + balanceHeld
        if (deposited[c] != paidOut[c] + pending + pool) {
            _fail(c, seed, step, 0, "P2 accounting mismatch");
        }

        // (P4) the automatic contract holds no stray ETH/WETH when nothing is pending
        if (c == APNFT && !anyPending) {
            if (address(apnft).balance != 0) {
                _fail(c, seed, step, 0, "P4 stray ETH");
            }
            if (weth.balanceOf(address(apnft)) != 0) {
                _fail(c, seed, step, 0, "P4 stray WETH");
            }
        }
    }

    function _fail(uint256 c, uint256 seed, uint256 step, uint256 id, string memory what) internal {
        console.log("SOLVENCY BROKEN:", what);
        console.log("  contract(0=enft,1=apnft):", c);
        console.log("  seed:", seed);
        console.log("  step:", step);
        console.log("  tokenId:", id);
        console.log("  deposited:", deposited[c]);
        console.log("  paidOut:", paidOut[c]);
        console.log("  poolBalance:", _pool(c));
        // SECURE EXPECTATION: a solvent contract satisfies all four properties after every
        // call; this assertion must never fire. If it does it is a Critical finding and the
        // seed above reproduces it.
        require(false, what);
    }

    function _handlerName(uint256 h) internal pure returns (string memory) {
        if (h == H_MINT) return "mint";
        if (h == H_MINTAUTO) return "mintAuto";
        if (h == H_TOPUP) return "topUp";
        if (h == H_ACCRUE) return "accrue";
        if (h == H_CLAIM) return "claim";
        if (h == H_TRANSFER) return "transferFrom";
        if (h == H_SETAUTO) return "setAutoPayout";
        if (h == H_REQUEST) return "requestPayout";
        if (h == H_FINALIZE) return "finalizePayout";
        return "warp";
    }
}

/// @dev The deliverable: Foundry's native stateful invariant runner. The brief asked to try
///      this first and only fall back to a seed fuzz if it could not drive the mock; it can.
///      The runner self-targets a single `invStep` entry (so it calls one random handler per
///      step), resets to the funded baseline between runs, and invariant_C2_1_solvency decrypts
///      and checks the four properties after every call. 256 runs x depth 30 is >= 256 sequences
///      of depth 30. Each step is its own transaction, so the per-tx HCU transient and EVM
///      memory reset per step and the 2^30 single-call gas cap never binds.
contract SolvencyInvariantTest is SolvencyModel {
    function setUp() public override {
        super.setUp();
        targetContract(address(this));
        bytes4[] memory sel = new bytes4[](1);
        sel[0] = this.invStep.selector;
        targetSelector(FuzzSelector({addr: address(this), selectors: sel}));
    }

    /// @dev One random handler step. Handlers swallow their own reverts, so the runner sees
    ///      none; SolvencyCensusTest is where per-handler success/revert/skip counts are
    ///      recorded, since the runner resets this contract's counters between runs.
    function invStep(uint256 seed) external {
        vm.roll(block.number + 1);
        uint256 rng = _rng(seed);
        _dispatch(rng % NUM_HANDLERS, rng);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 30
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_C2_1_solvency() public {
        _checkInvariants(0, 0);
    }
}

/// @dev A single-invocation census that runs many sequences back to back with persistent
///      counters, so a handler that never succeeds is visible, and asserts every handler
///      both ran and succeeded at least once. The same four invariants are checked after
///      every call, so this is also a long stateful solvency run in its own right.
contract SolvencyCensusTest is SolvencyModel {
    // A continuous run (tokens accumulate, capped at MAX_LIVE and retired as they settle) in
    // ONE call, so the census counters persist. Foundry caps a single test at 2^30 gas and
    // foundry.toml is frozen, so this is sized to fit; the full 256-sequence breadth lives in
    // SolvencyInvariantTest, whose per-step transactions each get their own gas budget.
    uint256 internal constant SEQUENCES = 96;
    uint256 internal constant DEPTH = 30;

    function test_C2_1_handlerCensus() public {
        for (uint256 s = 0; s < SEQUENCES; s++) {
            // Each sequence in its own call frame so EVM memory resets between them; storage
            // (the census counters and bookkeeping) carries over. A broken invariant reverts
            // this call and fails the test, carrying the seed/step in the logged context.
            this.runSequenceExternal(uint256(keccak256(abi.encode("solvency", s))), DEPTH);
        }

        console.log("=== Solvency handler census ===");
        console.log("sequences:", SEQUENCES);
        console.log("depth:", DEPTH);
        console.log("total steps:", SEQUENCES * DEPTH);
        uint256 totalCalls;
        for (uint256 h = 0; h < NUM_HANDLERS; h++) {
            uint256 success = calls[h] - reverts[h] - skips[h];
            totalCalls += calls[h];
            console.log(_handlerName(h));
            console.log("  calls/reverts/skips:", calls[h], reverts[h], skips[h]);
            console.log("  success:", success);
            // Every handler must both be reached and succeed at least once, or the invariant
            // over that handler would be vacuous.
            assertGt(calls[h], 0, "handler never dispatched");
            assertGt(success, 0, "handler never succeeded (dead handler)");
        }
        console.log("total calls:", totalCalls);
        // Sanity: deposits and payouts actually happened on both contracts.
        assertGt(deposited[ENFT], 0, "no enft deposits");
        assertGt(deposited[APNFT], 0, "no apnft deposits");
        assertGt(paidOut[ENFT], 0, "no enft payouts");
        assertGt(paidOut[APNFT], 0, "no apnft payouts");
    }
}
