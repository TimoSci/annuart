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
