// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FhevmTest} from "forge-fhevm/FhevmTest.sol";
import {FHE, euint64, externalEuint64} from "@fhevm/solidity/lib/FHE.sol";
import "encrypted-types/EncryptedTypes.sol";
import {MockConfidentialToken} from "../src/mocks/MockConfidentialToken.sol";
import {EndowmentNFT} from "../src/EndowmentNFT.sol";
import {Schedule, Segment} from "../src/libraries/Schedule.sol";
import {IERC7984} from "@openzeppelin/confidential-contracts/interfaces/IERC7984.sol";

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
}
