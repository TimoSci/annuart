// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FhevmTest} from "forge-fhevm/FhevmTest.sol";
import {externalEuint64} from "@fhevm/solidity/lib/FHE.sol";
import "encrypted-types/EncryptedTypes.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC7984} from "@openzeppelin/confidential-contracts/interfaces/IERC7984.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {ConfidentialWETH} from "../src/ConfidentialWETH.sol";
import {EndowmentNFT} from "../src/EndowmentNFT.sol";
import {Segment} from "../src/libraries/Schedule.sol";

contract ConfidentialWETHTest is FhevmTest {
    MockWETH internal weth;
    ConfidentialWETH internal cweth;
    EndowmentNFT internal nft;
    address internal alice = address(0xA11CE);

    function setUp() public override {
        super.setUp();
        weth = new MockWETH();
        cweth = new ConfidentialWETH(IERC20(address(weth)));
        nft = new EndowmentNFT(IERC7984(address(cweth)));
    }

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

    /// Amounts are rounded down to the 1e9 granularity; the remainder is never pulled from the sender.
    function test_wrap_dustStaysWithSender() public {
        vm.deal(alice, 2 ether);
        vm.startPrank(alice);
        weth.deposit{value: 2 ether}();
        weth.approve(address(cweth), 2 ether);
        cweth.wrap(alice, 1 ether + 1);
        vm.stopPrank();
        assertEq(decrypt(cweth.confidentialBalanceOf(alice)), 1e9);
        assertEq(weth.balanceOf(alice), 1 ether);
    }

    function test_enftOverWrapper_mintAccrueClaim() public {
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        weth.deposit{value: 1 ether}();
        weth.approve(address(cweth), 1 ether);
        cweth.wrap(alice, 1 ether);
        cweth.setOperator(address(nft), uint48(block.timestamp + 365 days));
        vm.stopPrank();

        Segment[] memory segs = new Segment[](1);
        segs[0] = Segment({duration: 1000, ratePerSec: 1e6});
        (externalEuint64 handle, bytes memory proof) = encryptUint64(1e9, alice, address(nft));
        vm.prank(alice);
        uint256 id = nft.mint(alice, handle, proof, segs, uint64(block.timestamp), false, bytes32(0));

        assertEq(decrypt(cweth.confidentialBalanceOf(alice)), 0);
        assertEq(decrypt(cweth.confidentialBalanceOf(address(nft))), 1e9);

        vm.warp(block.timestamp + 1000);
        vm.prank(alice);
        nft.claim(id);

        assertEq(decrypt(cweth.confidentialBalanceOf(alice)), 1e9);
        assertEq(decrypt(cweth.confidentialBalanceOf(address(nft))), 0);
    }
}
