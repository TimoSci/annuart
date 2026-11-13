// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FhevmTest} from "forge-fhevm/FhevmTest.sol";
import {externalEuint64} from "@fhevm/solidity/lib/FHE.sol";
import "encrypted-types/EncryptedTypes.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC7984ERC20Wrapper} from "@openzeppelin/confidential-contracts/interfaces/IERC7984ERC20Wrapper.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {ConfidentialWETH} from "../src/ConfidentialWETH.sol";
import {EndowmentNFT} from "../src/EndowmentNFT.sol";
import {AutoPayoutEndowmentNFT} from "../src/AutoPayoutEndowmentNFT.sol";
import {Segment} from "../src/libraries/Schedule.sol";

/// @dev Answers underlying() with the zero address, as no real WETH wrapper would.
contract ZeroUnderlyingWrapper {
    function underlying() external pure returns (address) {
        return address(0);
    }

    function rate() external pure returns (uint256) {
        return 1e9;
    }
}

contract AutoPayoutEndowmentNFTTest is FhevmTest {
    MockWETH internal weth;
    ConfidentialWETH internal cweth;
    AutoPayoutEndowmentNFT internal nft;
    address internal creator = address(0xC0FFEE);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal operator = address(0x0BE7);

    event AutoPayoutSet(uint256 indexed tokenId, bool enabled, uint32 interval, uint128 fee);

    function setUp() public override {
        super.setUp();
        weth = new MockWETH();
        cweth = new ConfidentialWETH(IERC20(address(weth)));
        nft = new AutoPayoutEndowmentNFT(IERC7984ERC20Wrapper(address(cweth)));
    }

    // ---- helpers ----

    function _segments() internal pure returns (Segment[] memory s) {
        s = new Segment[](1);
        s[0] = Segment({duration: 1000, ratePerSec: 1e6});
    }

    /// @dev Gives the creator 1 cWETH (1e9 units) and makes the NFT their operator.
    function _fundCreator() internal returns (externalEuint64 handle, bytes memory proof) {
        vm.deal(creator, 1 ether);
        vm.startPrank(creator);
        weth.deposit{value: 1 ether}();
        weth.approve(address(cweth), 1 ether);
        cweth.wrap(creator, 1 ether);
        cweth.setOperator(address(nft), uint48(block.timestamp + 365 days));
        vm.stopPrank();
        (handle, proof) = encryptUint64(1e9, creator, address(nft));
    }

    function _mint(address to) internal returns (uint256 id) {
        (externalEuint64 h, bytes memory p) = _fundCreator();
        vm.prank(creator);
        id = nft.mint(to, h, p, _segments(), uint64(block.timestamp), false, bytes32(0));
    }

    function _mintAuto(address to, bool enabled, uint32 interval, uint128 fee) internal returns (uint256 id) {
        (externalEuint64 h, bytes memory p) = _fundCreator();
        vm.prank(creator);
        id = nft.mintAuto(to, h, p, _segments(), uint64(block.timestamp), false, bytes32(0), enabled, interval, fee);
    }

    function _assertSettings(uint256 id, bool enabled, uint32 interval, uint128 fee) internal view {
        (bool en, uint32 iv, uint128 f, uint64 last) = nft.autoPayoutOf(id);
        assertEq(en, enabled, "enabled");
        assertEq(iv, interval, "interval");
        assertEq(f, fee, "fee");
        assertEq(last, 0, "lastRequestAt");
    }

    /// @dev Asserts the logs hold EndowmentMinted for `id`, followed later by AutoPayoutSet(id, ...).
    function _assertMintLogs(Vm.Log[] memory logs, uint256 id, bool enabled, uint32 interval, uint128 fee)
        internal
        view
    {
        bytes32 mintedSig = EndowmentNFT.EndowmentMinted.selector;
        bytes32 setSig = AutoPayoutSet.selector;
        uint256 mintedAt = type(uint256).max;
        uint256 setAt = type(uint256).max;
        uint256 setCount;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(nft)) continue;
            if (logs[i].topics[0] == mintedSig && uint256(logs[i].topics[1]) == id) mintedAt = i;
            if (logs[i].topics[0] == setSig) {
                setCount++;
                setAt = i;
                assertEq(uint256(logs[i].topics[1]), id, "AutoPayoutSet tokenId");
                (bool en, uint32 iv, uint128 f) = abi.decode(logs[i].data, (bool, uint32, uint128));
                assertEq(en, enabled, "event enabled");
                assertEq(iv, interval, "event interval");
                assertEq(f, fee, "event fee");
            }
        }
        assertEq(setCount, 1, "one AutoPayoutSet");
        assertTrue(mintedAt != type(uint256).max, "EndowmentMinted emitted");
        assertGt(setAt, mintedAt, "AutoPayoutSet after EndowmentMinted");
    }

    function _countAutoPayoutSet(Vm.Log[] memory logs) internal view returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(nft) && logs[i].topics[0] == AutoPayoutSet.selector) n++;
        }
    }

    // ---- constructor ----

    function test_constants() public view {
        assertEq(nft.DEFAULT_INTERVAL(), 86400);
        assertEq(nft.MIN_INTERVAL(), 3600);
        assertEq(nft.MAX_INTERVAL(), 31536000);
    }

    function test_constructor_readsWrapper() public view {
        assertEq(nft.weth(), address(weth));
        assertEq(nft.rate(), 1e9);
        assertEq(address(nft.token()), address(cweth));
    }

    function test_constructor_rejectsZeroUnderlying() public {
        ZeroUnderlyingWrapper bad = new ZeroUnderlyingWrapper();
        vm.expectRevert(AutoPayoutEndowmentNFT.NotWethWrapper.selector);
        new AutoPayoutEndowmentNFT(IERC7984ERC20Wrapper(address(bad)));
    }

    // ---- mint ----

    function test_mint_defaultsOffOneDayNoFee() public {
        (externalEuint64 h, bytes memory p) = _fundCreator();
        vm.recordLogs();
        vm.prank(creator);
        uint256 id = nft.mint(alice, h, p, _segments(), uint64(block.timestamp), false, bytes32(0));
        _assertMintLogs(vm.getRecordedLogs(), id, false, 86400, 0);
        _assertSettings(id, false, 86400, 0);
    }

    function test_mintAuto_storesSettings() public {
        (externalEuint64 h, bytes memory p) = _fundCreator();
        vm.recordLogs();
        vm.prank(creator);
        uint256 id =
            nft.mintAuto(alice, h, p, _segments(), uint64(block.timestamp), false, bytes32(0), true, 7200, 5);
        _assertMintLogs(vm.getRecordedLogs(), id, true, 7200, 5);
        _assertSettings(id, true, 7200, 5);
        assertEq(nft.ownerOf(id), alice);
    }

    function test_mintAuto_rejectsInterval() public {
        (externalEuint64 h, bytes memory p) = _fundCreator();
        Segment[] memory s = _segments();
        uint64 start = uint64(block.timestamp);

        vm.prank(creator);
        vm.expectRevert(AutoPayoutEndowmentNFT.InvalidInterval.selector);
        nft.mintAuto(alice, h, p, s, start, false, bytes32(0), true, 3599, 0);

        vm.prank(creator);
        vm.expectRevert(AutoPayoutEndowmentNFT.InvalidInterval.selector);
        nft.mintAuto(alice, h, p, s, start, false, bytes32(0), true, 31536001, 0);

        uint256 lo = _mintAuto(alice, true, 3600, 0);
        _assertSettings(lo, true, 3600, 0);
        uint256 hi = _mintAuto(alice, true, 31536000, 0);
        _assertSettings(hi, true, 31536000, 0);
    }

    // ---- setAutoPayout ----

    function test_setAutoPayout_ownerOnly() public {
        uint256 id = _mint(alice);

        vm.prank(bob);
        vm.expectRevert(EndowmentNFT.NotOwner.selector);
        nft.setAutoPayout(id, true, 7200, 5);

        vm.expectEmit(true, false, false, true, address(nft));
        emit AutoPayoutSet(id, true, 7200, 5);
        vm.prank(alice);
        nft.setAutoPayout(id, true, 7200, 5);
        _assertSettings(id, true, 7200, 5);
    }

    function test_setAutoPayout_rejectsInterval() public {
        uint256 id = _mint(alice);

        vm.startPrank(alice);
        vm.expectRevert(AutoPayoutEndowmentNFT.InvalidInterval.selector);
        nft.setAutoPayout(id, true, 3599, 0);
        vm.expectRevert(AutoPayoutEndowmentNFT.InvalidInterval.selector);
        nft.setAutoPayout(id, true, 31536001, 0);
        vm.expectRevert(AutoPayoutEndowmentNFT.InvalidInterval.selector);
        nft.setAutoPayout(id, false, 0, 0);

        nft.setAutoPayout(id, true, 3600, 1);
        _assertSettings(id, true, 3600, 1);
        nft.setAutoPayout(id, false, 31536000, 2);
        _assertSettings(id, false, 31536000, 2);
        vm.stopPrank();
    }

    function test_setAutoPayout_nonexistentReverts() public {
        vm.expectRevert(EndowmentNFT.NonexistentToken.selector);
        nft.setAutoPayout(1, true, 7200, 0);
    }

    function test_autoPayoutOf_nonexistentReverts() public {
        vm.expectRevert(EndowmentNFT.NonexistentToken.selector);
        nft.autoPayoutOf(1);
    }

    // ---- transfers ----

    function test_transfer_resetsEnabledKeepsIntervalAndFee() public {
        uint256 id = _mintAuto(alice, true, 7200, 5);

        vm.expectEmit(true, false, false, true, address(nft));
        emit AutoPayoutSet(id, false, 7200, 5);
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);

        _assertSettings(id, false, 7200, 5);
    }

    function test_transfer_byApprovedOperator_resets() public {
        uint256 id = _mintAuto(alice, true, 7200, 5);
        vm.prank(alice);
        nft.setApprovalForAll(operator, true);

        vm.expectEmit(true, false, false, true, address(nft));
        emit AutoPayoutSet(id, false, 7200, 5);
        vm.prank(operator);
        nft.safeTransferFrom(alice, bob, id);

        _assertSettings(id, false, 7200, 5);
        assertEq(nft.ownerOf(id), bob);
    }

    function test_transfer_toSelf_changesNothing() public {
        uint256 id = _mintAuto(alice, true, 7200, 5);

        vm.recordLogs();
        vm.prank(alice);
        nft.transferFrom(alice, alice, id);
        assertEq(_countAutoPayoutSet(vm.getRecordedLogs()), 0);

        _assertSettings(id, true, 7200, 5);
    }

    // ---- other reads ----

    function test_totalMinted() public {
        assertEq(nft.totalMinted(), 0);
        _mint(alice);
        assertEq(nft.totalMinted(), 1);
        _mintAuto(bob, true, 7200, 0);
        assertEq(nft.totalMinted(), 2);
    }

    // ---- inherited behaviour ----

    function test_claim_stillWorks() public {
        uint256 id = _mintAuto(alice, true, 7200, 5);
        vm.warp(block.timestamp + 500);
        vm.prank(alice);
        nft.claim(id);
        assertEq(decrypt(cweth.confidentialBalanceOf(alice)), 500 * 1e6);
        assertEq(decrypt(cweth.confidentialBalanceOf(address(nft))), 1e9 - 500 * 1e6);
        assertEq(decrypt(nft.distributionHandle(id)), 0);
    }
}
