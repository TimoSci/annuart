// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {FHE, euint64, externalEuint64} from "@fhevm/solidity/lib/FHE.sol";
import {IERC7984} from "@openzeppelin/confidential-contracts/interfaces/IERC7984.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {RedTeamBase} from "./RedTeamBase.sol";
import {EndowmentNFT} from "../../src/EndowmentNFT.sol";
import {AutoPayoutEndowmentNFT} from "../../src/AutoPayoutEndowmentNFT.sol";
import {Segment, INDEFINITE} from "../../src/libraries/Schedule.sol";

/// @dev Task 7: breaking the contracts. Gas bombs (C4-1), stuck payouts (C4-3), time edges
///      (C4-5), ERC-721 corner cases (C4-6) and donation order dependence (C4-8).
contract GriefingTest is RedTeamBase {
    // Block gas limits to report against (Sepolia could not be pinned to one number; see report).
    uint256 internal constant LIMIT_30M = 30_000_000;
    uint256 internal constant LIMIT_60M = 60_000_000;

    /// @dev An N-segment schedule, each segment 1e6 s at 1 unit/s. Finite end = start + N*1e6,
    ///      which stays far below type(uint64).max for any N a block can mint.
    function _bigSchedule(uint64 n) internal pure returns (Segment[] memory s) {
        s = new Segment[](n);
        for (uint64 i = 0; i < n; i++) {
            s[i] = Segment({duration: 1_000_000, ratePerSec: 1});
        }
    }

    // =====================================================================================
    // C4-1  Gas bombs: unbounded schedule length
    // =====================================================================================

    struct Row {
        uint64 n;
        uint256 mint;
        uint256 accrue;
        uint256 claim;
        uint256 transfer;
        uint256 mintAuto;
        uint256 request;
    }

    /// @dev Mints an N-segment token on `enft` to `creator`, then measures accrue, claim and
    ///      transferFrom on it. Returns the gas each call used.
    function _measureEnft(uint64 n) internal returns (uint256 gMint, uint256 gAccrue, uint256 gClaim, uint256 gTransfer) {
        uint64 amount = 1_000_000; // >> anything that accrues over 10s, so FHE.min never caps
        _fundMock(creator, amount);
        _authorise(creator, enft);
        Segment[] memory s = _bigSchedule(n);
        (externalEuint64 h, bytes memory p) = _enc(amount, creator, address(enft));

        vm.prank(creator);
        uint256 g0 = gasleft();
        uint256 id = enft.mint(creator, h, p, s, uint64(block.timestamp), false, bytes32(0));
        gMint = g0 - gasleft();

        vm.warp(block.timestamp + 10); // 10s into the first segment: streaming, owed = 10

        g0 = gasleft();
        enft.accrue(id);
        gAccrue = g0 - gasleft();

        vm.prank(creator);
        g0 = gasleft();
        enft.claim(id);
        gClaim = g0 - gasleft();

        vm.prank(creator);
        g0 = gasleft();
        enft.transferFrom(creator, alice, id);
        gTransfer = g0 - gasleft();
    }

    /// @dev Mints an N-segment auto token on `apnft` to `creator`, then measures requestPayout.
    function _measureAuto(uint64 n) internal returns (uint256 gMintAuto, uint256 gRequest) {
        uint64 units = 1_000_000;
        _fundCweth(creator, units);
        _authorise(creator, apnft);
        Segment[] memory s = _bigSchedule(n);
        (externalEuint64 h, bytes memory p) = _enc(units, creator, address(apnft));

        vm.prank(creator);
        uint256 g0 = gasleft();
        uint256 id = apnft.mintAuto(creator, h, p, s, uint64(block.timestamp), false, bytes32(0), true, 3600, 0);
        gMintAuto = g0 - gasleft();

        vm.warp(block.timestamp + 10);

        vm.prank(creator);
        g0 = gasleft();
        apnft.requestPayout(id, 0);
        gRequest = g0 - gasleft();
    }

    /// C4-1: measure every looping operation at 1/10/100/1000 segments, and show mint is the
    ///       gas ceiling: at 1000 segments mint costs more than accrue, claim, transfer and
    ///       requestPayout, so any token a single mint can create stays operable.
    function test_C4_1_gasScaling_mintIsTheCeiling() public {
        // Harness relaxation (mock only, not a contract property): this one test runs many
        // logical transactions in a single test tx, which trips the mock's per-tx HCU depth
        // cap. A real mint/accrue/claim does a constant handful of FHE ops regardless of N --
        // the schedule maths is plaintext -- so schedule length does not raise HCU cost; only
        // plaintext gas. Lifting the depth cap here (forge-fhevm's own helper, as Task 4 did)
        // lets the measurement proceed. Per-call HCU on Sepolia is C5-3.
        disableHCUDepthLimit();

        uint64[4] memory ns = [uint64(1), 10, 100, 1000];
        Row memory last;
        for (uint256 i = 0; i < ns.length; i++) {
            Row memory r;
            r.n = ns[i];
            (r.mint, r.accrue, r.claim, r.transfer) = _measureEnft(r.n);
            (r.mintAuto, r.request) = _measureAuto(r.n);
            console2.log("N", r.n);
            console2.log("  mint      ", r.mint);
            console2.log("  accrue    ", r.accrue);
            console2.log("  claim     ", r.claim);
            console2.log("  transfer  ", r.transfer);
            console2.log("  mintAuto  ", r.mintAuto);
            console2.log("  request   ", r.request);
            if (r.n == 1000) last = r;
        }

        // SECURE EXPECTATION: a fixed per-token segment cap (e.g. a few hundred) would keep
        // these O(1). Unbounded, they grow linearly -- but mint, which SSTOREs every segment,
        // grows ~10x faster per segment than the SLOAD-bound read operations, so mint is the
        // binding constraint. A token small enough to mint is small enough to use.
        assertGt(last.mint, last.accrue, "mint must cost more than accrue at N=1000");
        assertGt(last.mint, last.claim, "mint must cost more than claim at N=1000");
        assertGt(last.mint, last.transfer, "mint must cost more than transfer at N=1000");
        assertGt(last.mintAuto, last.request, "mintAuto must cost more than requestPayout at N=1000");
    }

    /// @dev Mints an N-segment token on `enft` to `creator` and returns only the mint gas.
    function _mintGasOnly(uint64 n) internal returns (uint256 gMint) {
        uint64 amount = 1_000_000;
        _fundMock(creator, amount);
        _authorise(creator, enft);
        Segment[] memory s = _bigSchedule(n);
        (externalEuint64 h, bytes memory p) = _enc(amount, creator, address(enft));
        vm.prank(creator);
        uint256 g0 = gasleft();
        enft.mint(creator, h, p, s, uint64(block.timestamp), false, bytes32(0));
        gMint = g0 - gasleft();
    }

    /// C4-1: find the largest schedule one mint fits in a block, mint it (handing it to a
    ///       victim), and prove the token is still claimable and transferable within the same
    ///       block limit -- i.e. a mintable token can never be bricked by its own length.
    function test_C4_1_largestMintableToken_staysClaimableAndTransferable() public {
        // Derive the mint-gas slope from two measured points on the same deployment.
        uint256 gMint100 = _mintGasOnly(100);
        uint256 gMint1000 = _mintGasOnly(1000);
        uint256 slope = (gMint1000 - gMint100) / 900; // gas per extra segment
        uint256 intercept = gMint100 - slope * 100;
        // casts are safe: the quotients are ~1200 and ~2500, far within uint64.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 nMax30 = uint64((LIMIT_30M - intercept) / slope);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 nMax60 = uint64((LIMIT_60M - intercept) / slope);
        console2.log("mint gas/segment", slope);
        console2.log("largest mint <= 30M block, segments", nMax30);
        console2.log("largest mint <= 60M block, segments", nMax60);

        // Mint the largest 30M-block token straight into a victim's wallet (to = alice),
        // with a safety margin so the measured mint stays under 30M.
        uint64 n = nMax30 - 20;
        uint64 amount = 1_000_000;
        _fundMock(creator, amount);
        _authorise(creator, enft);
        Segment[] memory s = _bigSchedule(n);
        (externalEuint64 h, bytes memory p) = _enc(amount, creator, address(enft));
        vm.prank(creator);
        uint256 g0 = gasleft();
        uint256 id = enft.mint(alice, h, p, s, uint64(block.timestamp), false, bytes32(0));
        uint256 gMint = g0 - gasleft();
        console2.log("minted segments", n);
        console2.log("mint gas", gMint);
        assertLt(gMint, LIMIT_30M, "largest token must mint within a 30M block");

        // The victim can use it. Warp so there is something to claim.
        vm.warp(block.timestamp + 10);

        vm.prank(alice);
        g0 = gasleft();
        enft.accrue(id);
        uint256 gAccrue = g0 - gasleft();

        vm.prank(alice);
        g0 = gasleft();
        enft.claim(id);
        uint256 gClaim = g0 - gasleft();

        vm.prank(alice);
        g0 = gasleft();
        enft.transferFrom(alice, bob, id);
        uint256 gTransfer = g0 - gasleft();

        console2.log("accrue gas", gAccrue);
        console2.log("claim gas", gClaim);
        console2.log("transfer gas", gTransfer);

        // SECURE EXPECTATION: unchanged -- these already hold. The point is the proof: the
        // most expensive operation on the largest mintable token is far under the block limit
        // that minted it, so neither the owner nor a victim can be locked out.
        assertLt(gAccrue, LIMIT_30M, "accrue must fit a 30M block");
        assertLt(gClaim, LIMIT_30M, "claim must fit a 30M block");
        assertLt(gTransfer, LIMIT_30M, "transfer must fit a 30M block");
        assertTrue(_bal(IERC7984(address(mock)), alice) >= 10, "victim actually received the claim");
        assertEq(enft.ownerOf(id), bob, "victim could pass the token on");

        // Record scheduleOf's return size at this length (the web indexer reads it).
        uint256 scheduleBytes = abi.encode(enft.scheduleOf(id)).length;
        console2.log("scheduleOf return bytes at N", n);
        console2.log("scheduleOf return bytes", scheduleBytes);
    }

    // =====================================================================================
    // C4-3  Stuck payouts: a payout requested and never finalised
    // =====================================================================================

    /// C4-3: while a payout is pending, the owner's manual claim, settings and transfer all
    ///       keep working; a second request is refused (PayoutPending); and anyone -- not just
    ///       the requester -- can finish the stuck payout, which pays the recipient fixed at
    ///       request time. A griefer who requests with fee zero and walks away locks nothing.
    function test_C4_3_pendingPayout_ownerKeepsWorking_anyoneFinalises() public {
        uint256 id = _mintAutoSimple(alice, 1000, true, 1 days, 0); // enabled, interval 1 day, fee 0
        vm.warp(block.timestamp + 100); // 100 accrued

        // A griefer requests (fee 0) and never finalises: the claimable 100 is taken into a
        // pending unwrap, and automatic payouts pause (spec section 9 accepts the pause).
        _requestPayout(id, mallory);
        (bytes32 rid,, address requester,) = apnft.pendingPayoutOf(id);
        assertTrue(rid != bytes32(0), "a payout is pending");
        assertEq(requester, mallory, "griefer is the requester");

        // A second request is refused while one is pending.
        vm.expectRevert(AutoPayoutEndowmentNFT.PayoutPending.selector);
        vm.prank(bob);
        apnft.requestPayout(id, 0);

        // The owner's manual claim still works for everything that accrues afterwards.
        vm.warp(block.timestamp + 100); // another 100 accrues
        uint64 beforeClaim = _bal(IERC7984(address(cweth)), alice);
        vm.prank(alice);
        apnft.claim(id);
        assertEq(_bal(IERC7984(address(cweth)), alice), beforeClaim + 100, "owner claim not blocked by pending");

        // Settings still work.
        vm.prank(alice);
        apnft.setAutoPayout(id, true, 2 days, 0);
        (, uint32 interval,,) = apnft.autoPayoutOf(id);
        assertEq(interval, 2 days, "owner can still change settings");

        // Transfer still works (and resets enabled for the new owner).
        vm.prank(alice);
        apnft.transferFrom(alice, bob, id);
        assertEq(apnft.ownerOf(id), bob, "owner can still transfer");

        // SECURE EXPECTATION: unchanged -- this is the accepted behaviour (spec section 9). The
        // test proves the pause never becomes a lock: anyone finishes the stuck payout, and it
        // pays the recipient snapshotted at request time (alice), not the griefer, with fee 0.
        uint256 aliceEthBefore = alice.balance;
        uint64 paid = _finalizePayout(id, keeper); // a third party, neither owner nor requester
        assertEq(paid, 100, "the stuck payout is exactly the amount taken at request");
        assertEq(alice.balance - aliceEthBefore, uint256(100) * apnft.rate(), "recipient (not griefer) paid in ETH");
        assertEq(mallory.balance, 0, "fee-zero griefer got nothing");
        (bytes32 ridAfter,,,) = apnft.pendingPayoutOf(id);
        assertEq(ridAfter, bytes32(0), "pending cleared after anyone finalises");
    }

    // =====================================================================================
    // C4-5  Time edges
    // =====================================================================================

    /// @dev Funds `creator`, authorises, and mints a custom schedule on `enft` to `to`.
    function _mintCustom(address to, uint64 amount, Segment[] memory segs, uint64 start, bool topUps)
        internal
        returns (uint256 id)
    {
        _fundMock(creator, amount);
        _authorise(creator, enft);
        id = _mint(enft, creator, to, amount, segs, start, topUps, bytes32(0));
    }

    /// C4-5: a start in the past accrues the backlog on the first poke; a start in the future
    ///       accrues nothing until it arrives. No funds are skipped or lost either way.
    function test_C4_5_scheduleStart_pastAndFuture() public {
        // Start 500s in the past: schedule window [T0-500, T0+500], now = T0 -> 500 owed.
        uint256 past = _mintCustom(alice, 1000, _seg(1000, 1), T0 - 500, false);
        enft.accrue(past);
        assertEq(_dist(enft, past), 500, "past start accrues the backlog to now, no more");

        // Start 1000s in the future: nothing accrues before it, then it streams normally.
        uint256 future = _mintCustom(bob, 1000, _seg(1000, 1), T0 + 1000, false);
        enft.accrue(future);
        assertEq(_dist(enft, future), 0, "future start accrues nothing before it begins");
        vm.warp(T0 + 1000 + 10);
        enft.accrue(future);
        assertEq(_dist(enft, future), 10, "future start streams once it begins");
    }

    /// C4-5: accrual exactly at a segment boundary, exactly at the end (settles the leftover),
    ///       and across a zero-rate segment (which contributes nothing).
    function test_C4_5_boundaryEnd_andZeroRateSegments() public {
        // seg0 [T0,T0+100) @2, seg1 [T0+100,T0+200) @5; scheduled total 700, endowment 1000.
        Segment[] memory two = new Segment[](2);
        two[0] = Segment({duration: 100, ratePerSec: 2});
        two[1] = Segment({duration: 100, ratePerSec: 5});
        uint256 id = _mintCustom(alice, 1000, two, T0, false);

        vm.warp(T0 + 100); // exactly the segment boundary
        enft.accrue(id);
        assertEq(_dist(enft, id), 200, "boundary accrual = first segment exactly");

        vm.warp(T0 + 200); // exactly the end: settle and release the leftover
        enft.accrue(id);
        assertEq(_dist(enft, id), 1000, "end accrual releases the whole endowment (700 scheduled + 300 leftover)");
        assertEq(_endow(enft, id), 0, "endowment drained at end");
        assertTrue(enft.settledOf(id), "settled at end");

        // Zero-rate first segment contributes nothing; the next segment streams normally.
        Segment[] memory zr = new Segment[](2);
        zr[0] = Segment({duration: 100, ratePerSec: 0});
        zr[1] = Segment({duration: 100, ratePerSec: 5});
        uint256 z = _mintCustom(bob, 1000, zr, T0, false);
        vm.warp(T0 + 100);
        enft.accrue(z);
        assertEq(_dist(enft, z), 0, "zero-rate segment accrues nothing");
        vm.warp(T0 + 150);
        enft.accrue(z);
        assertEq(_dist(enft, z), 250, "the @5 segment streams: 50s * 5 = 250");
    }

    /// C4-5: accrue on a token that does not exist reverts NonexistentToken (covers ET:199,
    ///       the coverage gap assigned to Task 7).
    function test_C4_5_accrueNonexistentToken_reverts() public {
        vm.expectRevert(EndowmentNFT.NonexistentToken.selector);
        enft.accrue(999);
        // The same guard on the inheriting contract.
        vm.expectRevert(EndowmentNFT.NonexistentToken.selector);
        apnft.accrue(999);
    }

    /// C4-5: payout request timing. A request at exactly last + interval is allowed; one second
    ///       before (and 15s of proposer skew) is refused; lowering the interval lets the next
    ///       request through sooner. No interval is skipped or doubled.
    function test_C4_5_payoutTiming_boundaries_skew_intervalChange() public {
        uint32 twoHours = 2 * 3600;
        _fundCweth(creator, 1_000_000);
        _authorise(creator, apnft);
        // Indefinite schedule so there is always something to pay and NothingLeft never trips.
        uint256 id = _mintAuto(creator, alice, 1_000_000, _forever(1), T0, false, bytes32(0), true, twoHours, 0);

        vm.warp(T0 + 100);
        _payoutRoundTrip(id, keeper, keeper); // request #1 at T0+100 -> last = T0+100
        (,,, uint64 last1) = apnft.autoPayoutOf(id);
        assertEq(last1, T0 + 100, "lastRequestAt recorded at request time");

        // 15s of proposer skew cannot sneak a request through a 2h interval early.
        vm.warp(uint256(T0) + 100 + twoHours - 15);
        vm.expectRevert(abi.encodeWithSelector(AutoPayoutEndowmentNFT.PayoutTooSoon.selector, T0 + 100 + twoHours));
        vm.prank(keeper);
        apnft.requestPayout(id, 0);

        // One second before the boundary: still too soon.
        vm.warp(uint256(T0) + 100 + twoHours - 1);
        vm.expectRevert(abi.encodeWithSelector(AutoPayoutEndowmentNFT.PayoutTooSoon.selector, T0 + 100 + twoHours));
        vm.prank(keeper);
        apnft.requestPayout(id, 0);

        // Exactly at the boundary: allowed (no doubling -- it pays exactly one interval's worth).
        vm.warp(uint256(T0) + 100 + twoHours);
        uint64 paid2 = _payoutRoundTrip(id, keeper, keeper);
        assertEq(paid2, twoHours, "one interval's accrual, not two");
        (,,, uint64 last2) = apnft.autoPayoutOf(id);
        assertEq(last2, T0 + 100 + twoHours, "last advances by one interval");

        // Lower the interval to 1 hour; a request 1 hour later is now allowed (was too soon at 2h).
        vm.prank(alice);
        apnft.setAutoPayout(id, true, 3600, 0);
        vm.warp(uint256(last2) + 3600);
        uint64 paid3 = _payoutRoundTrip(id, keeper, keeper);
        assertEq(paid3, 3600, "lowered interval lets the next request through sooner, one hour's worth");
    }

    /// C4-5: a finite schedule allows exactly one request after its end (which sweeps the
    ///       leftover), then refuses further requests with NothingLeft. No funds are left
    ///       unreachable: the whole endowment is paid across the requests.
    function test_C4_5_finalRequestAfterEnd_thenNothingLeft() public {
        uint256 id = _mintAutoSimple(alice, 1000, true, 1 hours, 0); // 1 unit/s for 1000s, end = T0+1000

        vm.warp(T0 + 500);
        uint64 paidA = _payoutRoundTrip(id, keeper, keeper); // request before end
        assertEq(paidA, 500, "first request pays the first 500");

        // Past the end and past the interval: one final request sweeps the remaining 500.
        vm.warp(T0 + 1000 + 3600);
        uint64 paidB = _payoutRoundTrip(id, keeper, keeper);
        assertEq(paidB, 500, "final request sweeps the leftover 500");
        assertTrue(apnft.settledOf(id), "settled after the end");

        // SECURE EXPECTATION: unchanged. Any further request is refused: nothing is left.
        vm.warp(block.timestamp + 3600);
        vm.expectRevert(AutoPayoutEndowmentNFT.NothingLeft.selector);
        vm.prank(keeper);
        apnft.requestPayout(id, 0);

        assertEq(uint256(paidA) + paidB, 1000, "the whole endowment was paid out, nothing unreachable");
    }

    // =====================================================================================
    // C4-6  ERC-721 corner cases
    // =====================================================================================

    /// C4-6: a self-transfer keeps the claimable balance and does NOT reset automatic payouts
    ///       (to == from), so the owner loses nothing.
    function test_C4_6_transferToSelf_keepsFundsAndSettings() public {
        uint256 id = _mintAutoSimple(alice, 1000, true, 1 days, 0);
        vm.warp(block.timestamp + 100);
        apnft.accrue(id);

        vm.prank(alice);
        apnft.transferFrom(alice, alice, id); // to == from

        assertEq(apnft.ownerOf(id), alice, "still owned by alice");
        (bool enabled,,,) = apnft.autoPayoutOf(id);
        assertTrue(enabled, "self-transfer does not reset automatic payouts");
        vm.prank(alice);
        apnft.claim(id);
        assertEq(_bal(IERC7984(address(cweth)), alice), 100, "claimable survived the self-transfer");
    }

    /// C4-6: transferFrom (not safe) to the NFT contract, the token, or WETH makes that
    ///       contract the owner, with no way to call claim -- the claimable balance is stuck
    ///       for good. It is self-harm: only the owner can send the token there.
    function test_C4_6_transferToContracts_bricksClaim_selfHarmOnly() public {
        // enft over the mock token: transfer to the NFT contract itself.
        uint256 a = _mintCustom(alice, 1000, _seg(1000, 1), T0, false);
        vm.warp(T0 + 100);
        enft.accrue(a); // 100 claimable
        vm.prank(alice);
        enft.transferFrom(alice, address(enft), a);
        assertEq(enft.ownerOf(a), address(enft), "NFT contract now owns the token");
        // Nobody can claim: the previous owner is no longer the owner, and the contract has
        // no entry point to claim its own token. The 100 is permanently stuck (self-harm).
        vm.expectRevert(EndowmentNFT.NotOwner.selector);
        vm.prank(alice);
        enft.claim(a);

        // enft to the token contract: same outcome.
        uint256 b = _mintCustom(bob, 1000, _seg(1000, 1), T0, false);
        vm.prank(bob);
        enft.transferFrom(bob, address(mock), b);
        assertEq(enft.ownerOf(b), address(mock), "token contract now owns the ENFT");

        // apnft over cWETH: transfer to WETH bricks claim AND resets automatic payouts.
        uint256 c = _mintAutoSimple(alice, 1000, true, 1 days, 0);
        vm.warp(block.timestamp + 100);
        vm.prank(alice);
        apnft.transferFrom(alice, address(weth), c);
        assertEq(apnft.ownerOf(c), address(weth), "WETH now owns the auto ENFT");
        (bool enabled,,,) = apnft.autoPayoutOf(c);
        assertFalse(enabled, "automatic payouts reset on transfer to WETH");
        vm.expectRevert(EndowmentNFT.NotOwner.selector);
        vm.prank(alice);
        apnft.claim(c);
    }

    /// C4-6: an approved ERC-721 operator can move the token; the transfer settles accrual to
    ///       the new owner, who can then claim it (the operator itself cannot claim).
    function test_C4_6_approvedOperatorTransfer_settlesToNewOwner() public {
        uint256 id = _mintCustom(alice, 1000, _seg(1000, 1), T0, false);
        vm.warp(T0 + 100); // 100 pending accrual

        vm.prank(alice);
        enft.approve(mallory, id); // alice approves an operator
        vm.prank(mallory);
        enft.transferFrom(alice, bob, id); // operator moves it to bob

        assertEq(enft.ownerOf(id), bob, "operator transferred to the new owner");
        vm.prank(bob);
        enft.claim(id);
        assertEq(_bal(IERC7984(address(mock)), bob), 100, "accrual settled to the new owner, who claims it");
    }

    /// C4-6: safeTransferFrom to a receiver that re-enters accrue, transferFrom and
    ///       setAutoPayout from onERC721Received. None of these is guarded, but none moves
    ///       funds harmfully: the accrual follows the token to its final owner, claimable once.
    function test_C4_6_safeTransferReceiverReenters_accrueTransferSetAuto() public {
        TransferReenterer rcv = new TransferReenterer(apnft);
        uint256 id = _mintAutoSimple(alice, 1000, true, 1 days, 0);
        vm.warp(block.timestamp + 100); // 100 accrues

        rcv.arm(bob); // the receiver will forward the token to bob
        vm.prank(alice);
        apnft.safeTransferFrom(alice, address(rcv), id);

        // Every re-entrant call from the callback succeeded (the functions are not guarded).
        assertTrue(rcv.accrueOk(), "re-entrant accrue succeeded");
        assertTrue(rcv.setAutoOk(), "re-entrant setAutoPayout succeeded (receiver was owner)");
        assertTrue(rcv.transferOk(), "re-entrant transferFrom forwarded the token");

        // The token ended with bob, automatic payouts reset by the onward transfer, and the
        // accrued 100 is claimable exactly once by the final owner -- no double-pay, no loss.
        assertEq(apnft.ownerOf(id), bob, "token ended with the forwarded owner");
        (bool enabled,,,) = apnft.autoPayoutOf(id);
        assertFalse(enabled, "onward transfer reset automatic payouts");
        vm.prank(bob);
        apnft.claim(id);
        assertEq(_bal(IERC7984(address(cweth)), bob), 100, "accrual claimable once by the final owner");
    }

    // =====================================================================================
    // C4-8  Donation order dependence
    // =====================================================================================

    /// @dev Builds a token that has run dry with no accrual since: endowment 100 fully drained
    ///      and claimed at T0+100, clock parked there, now advanced to T0+200 (backlog 100).
    ///      Funds the donor with `donation` units and authorises it. Returns the token id.
    function _dryTokenWithDonor(uint64 donation) internal returns (uint256 id) {
        id = _mintSimple(alice, 100, true); // to alice, 1 unit/s for 1000s, endowment 100, topUps on
        vm.warp(T0 + 100);
        vm.prank(alice);
        enft.claim(id); // accrues 100, pays alice, endowment now 0, lastAccrualAt = T0+100
        assertEq(_endow(enft, id), 0, "endowment is dry");
        vm.warp(T0 + 200); // backlog of 100 elapsed, but nothing accrued since dry
        _fundMock(donor, donation);
        _authorise(donor, enft);
    }

    /// C4-8: donate THEN accrue -- the whole donation is released at once against the backlog
    ///       of elapsed time, immediately claimable.
    function test_C4_8_donateThenAccrue_wholeDonationClaimableAtOnce() public {
        uint256 id = _dryTokenWithDonor(70);

        _topUp(enft, donor, id, 70); // topUp does NOT accrue first (ET:212)
        enft.accrue(id); // owed over [T0+100, T0+200] = 100; actual = min(100, 70) = 70

        // SECURE EXPECTATION: a donor who expected their gift to stream from now would want 0
        // released at once. Because topUp does not accrue first, the full 70 is claimable now.
        assertEq(_dist(enft, id), 70, "donate-then-accrue releases the whole donation at once");
        vm.prank(alice);
        enft.claim(id);
        assertEq(_bal(IERC7984(address(mock)), alice) - 100, 70, "owner claims the whole donation immediately");
    }

    /// C4-8: accrue THEN donate -- the same donation streams forward from the moment of the
    ///       accrual; none of it is claimable at once.
    function test_C4_8_accrueThenDonate_streamsGoingForward() public {
        uint256 id = _dryTokenWithDonor(70);

        enft.accrue(id); // parks the clock at T0+200 against an empty endowment (releases 0)
        _topUp(enft, donor, id, 70);
        enft.accrue(id); // owed over [T0+200, T0+200] = 0 -> nothing released

        assertEq(_dist(enft, id), 0, "accrue-then-donate releases none of the donation at once");

        // It streams from T0+200 at the schedule rate: 30s later, only 30 of the 70 is claimable.
        vm.warp(T0 + 230);
        enft.accrue(id);
        assertEq(_dist(enft, id), 30, "the donation streams forward, not all at once");
    }
}

/// @dev C4-6 helper: an ERC-721 receiver that, once armed, re-enters accrue, setAutoPayout and
///      transferFrom from onERC721Received (none of which is nonReentrant). The existing
///      Reenterer (Theft.t.sol) covers claim/topUp/mint/request/finalize but not these three
///      calls, so this focused receiver extends that coverage for C4-6. One-shot, to avoid an
///      infinite loop on the forwarded transfer.
contract TransferReenterer is IERC721Receiver {
    AutoPayoutEndowmentNFT internal immutable nft;
    address internal forwardTo;
    bool internal armed;
    bool public accrueOk;
    bool public setAutoOk;
    bool public transferOk;

    constructor(AutoPayoutEndowmentNFT nft_) {
        nft = nft_;
    }

    function arm(address to) external {
        armed = true;
        forwardTo = to;
    }

    function onERC721Received(address, address, uint256 id, bytes calldata) external override returns (bytes4) {
        if (armed) {
            armed = false; // one-shot: the forwarded transfer must not re-enter again
            (accrueOk,) = address(nft).call(abi.encodeCall(EndowmentNFT.accrue, (id)));
            (setAutoOk,) = address(nft).call(abi.encodeCall(AutoPayoutEndowmentNFT.setAutoPayout, (id, true, 3600, 0)));
            (transferOk,) = address(nft).call(abi.encodeCall(IERC721.transferFrom, (address(this), forwardTo, id)));
        }
        return this.onERC721Received.selector;
    }
}
