// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FhevmTest} from "forge-fhevm/FhevmTest.sol";
import {FHE, euint64, externalEuint64} from "@fhevm/solidity/lib/FHE.sol";
import "encrypted-types/EncryptedTypes.sol";
import {MockConfidentialToken} from "./mocks/MockConfidentialToken.sol";
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
}
