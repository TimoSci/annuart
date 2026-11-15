// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RedTeamBase} from "./RedTeamBase.sol";
import {AutoPayoutEndowmentNFT} from "../../src/AutoPayoutEndowmentNFT.sol";
import {MockConfidentialToken} from "../../src/mocks/MockConfidentialToken.sol";
import {MockWETH} from "../../src/mocks/MockWETH.sol";
import {MockWETH9} from "../../src/mocks/MockWETH9.sol";

/// @dev Task 9 (C5-4) of the red team: the real WETH9 pays with `payable(msg.sender).transfer(wad)`,
///      which forwards a 2300-gas stipend. In a payout, `finalizePayout` calls `weth.withdraw`, so
///      the contract that receives that ETH is the AutoPayoutEndowmentNFT itself, and the code that
///      has to fit in 2300 gas is its `receive()` (a sender check). The payout recipient's own
///      `receive()` is called later, with SEND_GAS (100,000), not 2300 (see test_C5_4_*_recipient).
///      MockWETH9 is a copy of WETH9's `withdraw`, so the round trip below is the real path.
///      The canonical Sepolia WETH cannot be forked here (SEPOLIA_RPC_URL is unset): that repeat
///      is listed under Sepolia-only checks in the report.
contract WethGasTest is RedTeamBase {
    uint256 internal constant STIPEND = 2300;

    /// @dev Gas `address(apnft).receive()` really executes with `sender` as msg.sender and value 0
    ///      (no stipend added): the smallest forwarded gas for which the call succeeds.
    function _minGasForReceive(address sender) internal returns (uint256 lo, bool okAtStipend) {
        lo = 0;
        uint256 hi = STIPEND; // a call succeeding with the whole stipend is the pass condition
        bool ok;
        vm.startPrank(sender);
        (ok,) = address(apnft).call{gas: hi}("");
        okAtStipend = ok;
        while (okAtStipend && lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            (ok,) = address(apnft).call{gas: mid}("");
            if (ok) hi = mid;
            else lo = mid;
        }
        vm.stopPrank();
        lo = hi; // smallest gas that succeeds
    }

    /// WETH9's exact call: value > 0 and gas argument 0, so the callee gets only the 2300 stipend.
    function test_C5_4_wethWithdrawStipend_receiveSucceeds() public {
        vm.deal(address(weth), 1 ether);
        vm.prank(address(weth));
        (bool ok,) = address(apnft).call{value: 1 ether, gas: 0}("");
        assertTrue(ok, "receive() must fit in the 2300 stipend");
        assertEq(address(apnft).balance, 1 ether, "ETH arrived");
    }

    /// The sender check is the only thing receive() does; any other sender is refused, also
    /// within the stipend (so the refusal itself does not run out of gas, it reverts OnlyWeth).
    function test_C5_4_receive_nonWethSender_revertsOnlyWeth() public {
        vm.deal(mallory, 1 ether);
        vm.prank(mallory);
        vm.expectRevert(AutoPayoutEndowmentNFT.OnlyWeth.selector);
        payable(address(apnft)).transfer(1 ether);
    }

    /// Bound the gas receive() uses and require a wide margin below the 2300 stipend.
    function test_C5_4_receiveGas_fitsStipendWithMargin() public {
        (uint256 used, bool ok) = _minGasForReceive(address(weth));
        assertTrue(ok, "succeeds with 2300 forwarded");
        emit log_named_uint("receive() minimum forwarded gas (success path)", used);
        // The sender check loads an immutable and compares: a few hundred gas at most.
        // Require at least 50% of the stipend free, so a repricing of ~2x still fits.
        assertLe(used, STIPEND / 2, "receive() uses more than half the stipend");
        // A sanity check that the measurement means something: with 0 gas it fails.
        vm.prank(address(weth));
        (bool okZero,) = address(apnft).call{gas: 0}("");
        assertFalse(okZero, "zero gas cannot run receive()");
    }

    /// The full path: request, decrypt, finalise through MockWETH9.withdraw's 2300-gas transfer.
    /// The payout is paid in ETH (not the WETH fallback), the NFT contract keeps no ETH, and the
    /// whole payout (here fee 0) reaches the recipient.
    function test_C5_4_finalizePayout_throughWeth9Transfer_paysEth() public {
        uint256 id = _mintAutoSimple(alice, 1000, true, 3600, 0);
        vm.warp(block.timestamp + 500);
        uint256 aliceEthBefore = alice.balance;
        uint256 wethEthBefore = address(weth).balance;
        _requestPayout(id, keeper);
        uint64 units = _finalizePayout(id, keeper);
        assertGt(units, 0, "something to pay");
        assertEq(alice.balance - aliceEthBefore, uint256(units) * WEI_PER_UNIT, "recipient paid in ETH");
        assertEq(weth.balanceOf(alice), 0, "no WETH fallback");
        assertEq(address(apnft).balance, 0, "NFT contract holds no ETH");
        assertEq(wethEthBefore - address(weth).balance, uint256(units) * WEI_PER_UNIT, "WETH released exactly the payout");
    }

    /// The recipient's own receive() is NOT on the 2300 path: it is called with SEND_GAS
    /// (100,000) by `_sendEth`. A recipient that needs more than the stipend (here a storage
    /// write, ~22k gas) is paid in ETH, which is what makes smart-contract wallets workable.
    function test_C5_4_recipientReceive_runsWithSendGas_notStipend() public {
        SstoreReceiver r = new SstoreReceiver();
        uint256 id = _mintAutoSimple(address(r), 1000, true, 3600, 0);
        vm.warp(block.timestamp + 500);
        _requestPayout(id, keeper);
        uint64 units = _finalizePayout(id, keeper);
        assertGt(units, 0, "something to pay");
        assertEq(address(r).balance, uint256(units) * WEI_PER_UNIT, "paid in ETH, not WETH");
        assertEq(weth.balanceOf(address(r)), 0, "no WETH fallback");
        assertEq(r.hits(), 1, "its receive() ran a storage write, far above 2300 gas");
    }

    // ---- C5-1: the mock tokens refuse production chains on their own ----

    /// A deploy of any mock on chain 1 (Ethereum), 56 (BNB) or 999 reverts in its constructor, so the
    /// transaction cannot even be estimated, let alone sent. (On 56 and 999 the Zama config of
    /// MockConfidentialToken reverts first, ZamaProtocolUnsupported; the mocks' own require is the guard
    /// on chain 1.) Sepolia (11155111) is allowed: a mock token is a valid testnet deployment.
    function test_C5_1_mocksRefuseProductionChains() public {
        vm.chainId(1);
        vm.expectRevert(bytes("MockConfidentialToken: test/dev only"));
        new MockConfidentialToken();
        vm.expectRevert(bytes("MockWETH: test/dev only"));
        new MockWETH();
        vm.expectRevert(bytes("MockWETH9: test/dev only"));
        new MockWETH9();

        uint256[2] memory others = [uint256(56), uint256(999)];
        for (uint256 i = 0; i < others.length; i++) {
            vm.chainId(others[i]);
            vm.expectRevert();
            new MockConfidentialToken();
            vm.expectRevert(bytes("MockWETH: test/dev only"));
            new MockWETH();
            vm.expectRevert(bytes("MockWETH9: test/dev only"));
            new MockWETH9();
        }

        vm.chainId(11155111);
        new MockWETH();
        new MockWETH9();
    }
}

/// @dev Accepts the NFT and ETH; receive() writes storage (about 22,000 gas), which a 2300 stipend could not pay.
contract SstoreReceiver {
    uint256 public hits;

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {
        hits += 1;
    }
}
