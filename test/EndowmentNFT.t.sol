// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FhevmTest} from "forge-fhevm/FhevmTest.sol";
import {FHE, euint64, externalEuint64} from "@fhevm/solidity/lib/FHE.sol";
import "encrypted-types/EncryptedTypes.sol";
import {MockConfidentialToken} from "../src/mocks/MockConfidentialToken.sol";
import {EndowmentNFT} from "../src/EndowmentNFT.sol";
import {Schedule, Segment, INDEFINITE} from "../src/libraries/Schedule.sol";
import {IERC7984} from "@openzeppelin/confidential-contracts/interfaces/IERC7984.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev Receives an endowment NFT and immediately forwards it to `next`.
contract ForwardingReceiver {
    address internal immutable next;

    constructor(address next_) {
        next = next_;
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        EndowmentNFT(msg.sender).transferFrom(address(this), next, tokenId);
        return this.onERC721Received.selector;
    }
}

contract EndowmentNFTTest is FhevmTest {
    MockConfidentialToken internal token;
    EndowmentNFT internal nft;
    address internal creator = address(0xC0FFEE);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public override {
        super.setUp();
        token = new MockConfidentialToken();
        nft = new EndowmentNFT(IERC7984(address(token)));
    }

    function test_harness_mintAndDecryptBalance() public {
        token.mint(creator, 1_000);
        euint64 bal = token.confidentialBalanceOf(creator);
        assertEq(decrypt(bal), 1_000);
    }

    function _segments() internal pure returns (Segment[] memory s) {
        s = new Segment[](1);
        s[0] = Segment({duration: 1_000, ratePerSec: 1}); // 1 unit/sec for 1000s
    }

    function _mintWith(address to, uint64 amount, bool topUps, Segment[] memory segs, uint64 start)
        internal
        returns (uint256 id)
    {
        token.mint(creator, amount);
        vm.prank(creator);
        token.setOperator(address(nft), uint48(block.timestamp + 365 days));
        (externalEuint64 handle, bytes memory proof) = encryptUint64(amount, creator, address(nft));
        vm.prank(creator);
        id = nft.mint(to, handle, proof, segs, start, topUps);
    }

    function _mintEndowment(address to, uint64 amount, bool topUps) internal returns (uint256 id) {
        id = _mintWith(to, amount, topUps, _segments(), uint64(block.timestamp));
    }

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
        Segment[] memory s = _open(0);
        token.mint(creator, 10);
        vm.prank(creator);
        token.setOperator(address(nft), uint48(block.timestamp + 365 days));
        (externalEuint64 h, bytes memory p) = encryptUint64(10, creator, address(nft));
        vm.expectRevert(EndowmentNFT.ZeroRateIndefiniteSegment.selector);
        vm.prank(creator);
        nft.mint(alice, h, p, s, uint64(block.timestamp), false);
    }

    function test_indefinite_paysUntilEndowmentRunsOut() public {
        uint256 id = _mintWith(alice, 1_000, false, _open(2), uint64(block.timestamp));
        vm.warp(block.timestamp + 200); // 100*1 + 100*2 = 300
        nft.accrue(id);
        assertEq(decrypt(nft.distributionHandle(id)), 300);
        vm.warp(block.timestamp + 10_000); // would be far more than 1000
        nft.accrue(id);
        assertEq(decrypt(nft.distributionHandle(id)), 1_000);
    }

    // A rate so large that integration saturates uint64 must cap at the endowment, not revert.
    function test_indefinite_saturatedIntegrationDoesNotRevert() public {
        uint256 id = _mintWith(alice, 1_000, false, _open(type(uint64).max), uint64(block.timestamp));
        vm.warp(block.timestamp + 365 days);
        nft.accrue(id);
        assertEq(decrypt(nft.distributionHandle(id)), 1_000);
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

    function test_accrue_endowmentStaysSecretAfterAccrue() public {
        uint256 id = _mintEndowment(alice, 500, false);
        vm.warp(block.timestamp + 100);
        nft.accrue(id);
        // The endowment handle is freshly produced by FHE.sub during accrual;
        // the owner must NOT have ACL access to the new handle.
        assertFalse(_acl.isAllowed(euint64.unwrap(nft.endowmentHandle(id)), alice));
        // The contract itself must still have access (for future homomorphic ops).
        assertTrue(_acl.isAllowed(euint64.unwrap(nft.endowmentHandle(id)), address(nft)));
    }

    function test_claim_emptyDoesNotDrainContract() public {
        uint256 id = _mintEndowment(alice, 500, false);
        // Claim with nothing accrued — distribution is zero.
        vm.prank(alice);
        nft.claim(id);
        // Alice receives nothing.
        assertEq(decrypt(token.confidentialBalanceOf(alice)), 0);
        // Contract still holds the full endowment.
        assertEq(decrypt(token.confidentialBalanceOf(address(nft))), 500);
    }

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
        vm.expectRevert(EndowmentNFT.NonexistentToken.selector);
        nft.scheduleStartOf(99);
        vm.expectRevert(EndowmentNFT.NonexistentToken.selector);
        nft.scheduleEndOf(99);
        vm.expectRevert(EndowmentNFT.NonexistentToken.selector);
        nft.lastAccrualAtOf(99);
        vm.expectRevert(EndowmentNFT.NonexistentToken.selector);
        nft.settledOf(99);
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

    function test_sweep_releasesLeftoverAtEnd() public {
        uint256 id = _mintEndowment(alice, 5_000, false); // schedule total is 1000
        vm.warp(block.timestamp + 999);
        nft.accrue(id);
        assertEq(decrypt(nft.distributionHandle(id)), 999);
        assertFalse(nft.settledOf(id));
        vm.warp(block.timestamp + 1); // exactly the end
        nft.accrue(id);
        assertEq(decrypt(nft.distributionHandle(id)), 5_000);
        assertEq(decrypt(nft.endowmentHandle(id)), 0); // test-only: decrypt() bypasses ACL
        assertTrue(nft.settledOf(id));
        assertEq(nft.lastAccrualAtOf(id), nft.scheduleEndOf(id));
        // the swept distribution is readable by the owner; the zeroed endowment is not
        assertTrue(_acl.isAllowed(euint64.unwrap(nft.distributionHandle(id)), alice));
        assertFalse(_acl.isAllowed(euint64.unwrap(nft.endowmentHandle(id)), alice));
        assertTrue(_acl.isAllowed(euint64.unwrap(nft.endowmentHandle(id)), address(nft)));
    }

    function test_sweep_claimPaysEverything() public {
        uint256 id = _mintEndowment(alice, 5_000, false);
        vm.warp(block.timestamp + 2_000);
        vm.prank(alice);
        nft.claim(id);
        assertEq(decrypt(token.confidentialBalanceOf(alice)), 5_000);
        assertEq(decrypt(token.confidentialBalanceOf(address(nft))), 0);
    }

    // A settled endowment stays settled: later accruals and claims move nothing.
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
        assertEq(decrypt(token.confidentialBalanceOf(address(nft))), 0);
    }

    // A schedule whose end is already in the past at mint is swept on first accrual
    // and refuses top-ups.
    function test_sweep_scheduleAlreadyOverAtMint() public {
        vm.warp(1_000_000);
        uint256 id = _mintWith(alice, 700, true, _segments(), uint64(block.timestamp - 5_000));
        nft.accrue(id);
        assertEq(decrypt(nft.distributionHandle(id)), 700);
        assertTrue(nft.settledOf(id));
        token.mint(bob, 100);
        vm.prank(bob);
        token.setOperator(address(nft), uint48(block.timestamp + 365 days));
        (externalEuint64 h, bytes memory p) = encryptUint64(100, bob, address(nft));
        vm.expectRevert(EndowmentNFT.ScheduleEnded.selector);
        vm.prank(bob);
        nft.topUp(id, h, p);
    }

    // A transfer after the end settles the leftover onto the new owner's handle only.
    function test_sweep_transferAfterEndGivesLeftoverToNewOwner() public {
        uint256 id = _mintEndowment(alice, 5_000, false);
        vm.warp(block.timestamp + 2_000);
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        assertTrue(nft.settledOf(id));

        euint64 dist = nft.distributionHandle(id);
        assertTrue(_acl.isAllowed(euint64.unwrap(dist), bob));    // new owner can read
        assertFalse(_acl.isAllowed(euint64.unwrap(dist), alice)); // old owner cannot read post-transfer handle
        assertEq(decrypt(dist), 5_000);

        vm.prank(bob);
        nft.claim(id);
        assertEq(decrypt(token.confidentialBalanceOf(bob)), 5_000);
        assertEq(decrypt(token.confidentialBalanceOf(alice)), 0);
        assertFalse(_acl.isAllowed(euint64.unwrap(nft.distributionHandle(id)), alice));
    }

    function test_topUp_allowedBeforeEndRejectedAtEnd() public {
        uint256 id = _mintEndowment(alice, 500, true);
        vm.warp(block.timestamp + 999);
        _topUp(id, bob, 10); // one second before the end: fine
        vm.warp(block.timestamp + 1);
        token.mint(bob, 100);
        vm.prank(bob);
        token.setOperator(address(nft), uint48(block.timestamp + 365 days));
        (externalEuint64 h, bytes memory p) = encryptUint64(100, bob, address(nft));
        vm.expectRevert(EndowmentNFT.ScheduleEnded.selector);
        vm.prank(bob);
        nft.topUp(id, h, p);
        // the accepted top-up is part of what the sweep releases
        nft.accrue(id);
        assertEq(decrypt(nft.distributionHandle(id)), 510);
    }

    function test_topUp_neverRejectedOnIndefinite() public {
        uint256 id = _mintWith(alice, 500, true, _open(1), uint64(block.timestamp));
        vm.warp(block.timestamp + 10 * 365 days);
        _topUp(id, bob, 10); // must not revert
        assertFalse(nft.settledOf(id));
    }

    // --- F1: schedules that would lock the endowment forever are rejected ---

    function _expectMintRevert(Segment[] memory s, uint64 start, bytes4 selector) internal {
        token.mint(creator, 10);
        vm.prank(creator);
        token.setOperator(address(nft), uint48(block.timestamp + 365 days));
        (externalEuint64 h, bytes memory p) = encryptUint64(10, creator, address(nft));
        vm.expectRevert(selector);
        vm.prank(creator);
        nft.mint(alice, h, p, s, start, false);
    }

    function test_mint_revertsWhenFixedScheduleSaturates() public {
        Segment[] memory s = new Segment[](1);
        s[0] = Segment({duration: type(uint64).max - 1, ratePerSec: 0});
        _expectMintRevert(s, uint64(block.timestamp), EndowmentNFT.ScheduleTooLong.selector);
    }

    function test_mint_revertsWhenIndefiniteTailUnreachable() public {
        Segment[] memory s = new Segment[](2);
        s[0] = Segment({duration: type(uint64).max - 1, ratePerSec: 0});
        s[1] = Segment({duration: INDEFINITE, ratePerSec: 1});
        _expectMintRevert(s, uint64(block.timestamp), EndowmentNFT.ScheduleTooLong.selector);
    }

    function test_mint_revertsWhenIndefiniteTailUnreachableAcrossSegments() public {
        Segment[] memory s = new Segment[](3);
        s[0] = Segment({duration: uint64(1) << 63, ratePerSec: 0});
        s[1] = Segment({duration: uint64(1) << 63, ratePerSec: 0});
        s[2] = Segment({duration: INDEFINITE, ratePerSec: 1});
        _expectMintRevert(s, uint64(block.timestamp), EndowmentNFT.ScheduleTooLong.selector);
    }

    function test_mint_revertsWhenStartAtMaxWithFixedSchedule() public {
        _expectMintRevert(_segments(), type(uint64).max - 1, EndowmentNFT.ScheduleTooLong.selector);
    }

    function test_mint_revertsWhenStartAtMaxWithIndefiniteSchedule() public {
        Segment[] memory s = new Segment[](1);
        s[0] = Segment({duration: INDEFINITE, ratePerSec: 1});
        _expectMintRevert(s, type(uint64).max, EndowmentNFT.ScheduleTooLong.selector);
    }

    function test_mint_acceptsScheduleEndingOneBelowMax() public {
        uint64 start = uint64(block.timestamp);
        Segment[] memory s = new Segment[](2);
        s[0] = Segment({duration: 100, ratePerSec: 1});
        s[1] = Segment({duration: type(uint64).max - 1 - start - 100, ratePerSec: 1});
        uint256 id = _mintWith(alice, 500, false, s, start);
        assertEq(nft.scheduleEndOf(id), type(uint64).max - 1);
        assertEq(nft.ownerOf(id), alice);
    }

    // --- F3: EndowmentMinted is logged before the receiver callback runs ---

    function test_mint_eventPrecedesReceiverForwarding() public {
        ForwardingReceiver recv = new ForwardingReceiver(bob);
        vm.recordLogs();
        uint256 id = _mintWith(address(recv), 500, false, _segments(), uint64(block.timestamp));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(nft.ownerOf(id), bob);

        bytes32 transferSig = keccak256("Transfer(address,address,uint256)");
        bytes32 mintedSig = EndowmentNFT.EndowmentMinted.selector;
        uint256 mintedAt = type(uint256).max;
        uint256 firstTransferAt = type(uint256).max;
        uint256 forwardAt = type(uint256).max;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(nft)) continue;
            bytes32 sig = logs[i].topics[0];
            if (sig == mintedSig && uint256(logs[i].topics[1]) == id) {
                mintedAt = i;
            } else if (sig == transferSig && uint256(logs[i].topics[3]) == id) {
                if (firstTransferAt == type(uint256).max) firstTransferAt = i;
                if (address(uint160(uint256(logs[i].topics[1]))) == address(recv)) forwardAt = i;
            }
        }
        assertTrue(mintedAt != type(uint256).max, "EndowmentMinted not logged");
        assertTrue(forwardAt != type(uint256).max, "forwarding Transfer not logged");
        assertLt(mintedAt, firstTransferAt, "EndowmentMinted must precede the mint Transfer");
        assertLt(mintedAt, forwardAt, "EndowmentMinted must precede the forwarding Transfer");
    }

    // --- F4: a sweep triggered by claim never leaves the owner allowed on the remainder ---

    function test_sweep_viaClaimEndowmentHandleStaysSecret() public {
        uint256 id = _mintEndowment(alice, 5_000, false);
        vm.warp(block.timestamp + 2_000);
        vm.prank(alice);
        nft.claim(id);
        assertTrue(nft.settledOf(id));
        euint64 endow = nft.endowmentHandle(id);
        assertTrue(
            euint64.unwrap(endow) != euint64.unwrap(nft.distributionHandle(id)), "endowment handle == distribution handle"
        );
        assertFalse(_acl.isAllowed(euint64.unwrap(endow), alice), "owner allowed on endowment handle");
        assertTrue(_acl.isAllowed(euint64.unwrap(endow), address(nft)), "contract not allowed on endowment handle");
        assertEq(decrypt(endow), 0); // test-only: decrypt() bypasses ACL
    }

    // --- F5: a self-minting creator gets no ACL on the remaining endowment ---

    function test_mint_selfMintCreatorCannotReadEndowment() public {
        uint256 id = _mintEndowment(creator, 500, false);
        assertEq(nft.ownerOf(id), creator);
        euint64 endow = nft.endowmentHandle(id);
        assertFalse(_acl.isAllowed(euint64.unwrap(endow), creator), "creator allowed on endowment handle");
        assertTrue(_acl.isAllowed(euint64.unwrap(endow), address(nft)), "contract not allowed on endowment handle");
        assertEq(decrypt(endow), 500); // test-only: decrypt() bypasses ACL
    }

    // --- F7: a schedule made of a single indefinite segment ---

    function test_indefinite_singleSegmentAccruesForever() public {
        Segment[] memory s = new Segment[](1);
        s[0] = Segment({duration: INDEFINITE, ratePerSec: 3});
        uint64 t0 = uint64(block.timestamp);
        uint256 id = _mintWith(alice, 1_000_000, false, s, t0);
        assertEq(nft.scheduleEndOf(id), type(uint64).max);
        vm.warp(t0 + 100);
        nft.accrue(id);
        assertEq(decrypt(nft.distributionHandle(id)), 300);
        vm.warp(t0 + 1_000);
        nft.accrue(id);
        assertEq(decrypt(nft.distributionHandle(id)), 3_000);
        assertFalse(nft.settledOf(id));
    }
}
