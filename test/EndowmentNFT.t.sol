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
}
