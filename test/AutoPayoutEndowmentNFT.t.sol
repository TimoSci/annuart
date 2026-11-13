// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FhevmTest} from "forge-fhevm/FhevmTest.sol";
import {externalEuint64} from "@fhevm/solidity/lib/FHE.sol";
import "encrypted-types/EncryptedTypes.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC7984ERC20Wrapper} from "@openzeppelin/confidential-contracts/token/ERC7984/extensions/ERC7984ERC20Wrapper.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
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

/// @dev Accepts the NFT; has no receive or fallback, so any ETH sent to it fails.
contract RejectingReceiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function requestPayout(AutoPayoutEndowmentNFT nft, uint256 id) external returns (bytes32) {
        return nft.requestPayout(id, 0);
    }
}

/// @dev Accepts the NFT; its receive never returns, burning all the gas it is given.
contract GasBurner {
    uint256 internal counter;

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {
        while (true) {
            counter++;
        }
    }
}

/// @dev Accepts the NFT; on receiving ETH it tries to re-enter the payout functions
///      and records the error each attempt reverted with.
contract ReentrantReceiver {
    AutoPayoutEndowmentNFT internal immutable nft;
    uint256 public tokenId;
    bytes4 public finalizeError;
    bytes4 public requestError;

    constructor(AutoPayoutEndowmentNFT nft_) {
        nft = nft_;
    }

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        tokenId = id;
        return this.onERC721Received.selector;
    }

    receive() external payable {
        try nft.finalizePayout(tokenId, 0, "") {} catch (bytes memory err) {
            // casting to bytes4 is safe: only the error selector is wanted
            // forge-lint: disable-next-line(unsafe-typecast)
            finalizeError = bytes4(err);
        }
        try nft.requestPayout(tokenId, 0) {} catch (bytes memory err) {
            // casting to bytes4 is safe: only the error selector is wanted
            // forge-lint: disable-next-line(unsafe-typecast)
            requestError = bytes4(err);
        }
    }
}

/// @dev Accepts the NFT; accepts ETH only when given nearly all of the payment gas, and
///      otherwise fails at once, leaving the caller most of its gas.
contract GasHungryReceiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function requestPayout(AutoPayoutEndowmentNFT nft, uint256 id) external returns (bytes32) {
        return nft.requestPayout(id, 0);
    }

    receive() external payable {
        require(gasleft() > 95000, "starved");
    }
}

/// @dev Records the token's automatic payout settings as seen inside onERC721Received.
contract SettingsReader {
    bool public enabled;
    uint32 public interval;
    uint128 public fee;

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        (enabled, interval, fee,) = AutoPayoutEndowmentNFT(payable(msg.sender)).autoPayoutOf(id);
        return this.onERC721Received.selector;
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
    address internal keeper = address(0x4EE9E4);
    address internal finisher = address(0xF1F1);

    event AutoPayoutSet(uint256 indexed tokenId, bool enabled, uint32 interval, uint128 fee);
    event PayoutRequested(
        uint256 indexed tokenId, bytes32 indexed requestId, address indexed recipient, address requester, uint128 fee
    );
    event PayoutPaid(
        uint256 indexed tokenId, bytes32 indexed requestId, uint256 amountWei, uint256 feeWei, bool paidInWeth
    );

    function setUp() public override {
        super.setUp();
        weth = new MockWETH();
        cweth = new ConfidentialWETH(IERC20(address(weth)));
        nft = new AutoPayoutEndowmentNFT(ERC7984ERC20Wrapper(address(cweth)));
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
        new AutoPayoutEndowmentNFT(ERC7984ERC20Wrapper(address(bad)));
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

    // ---- Task 1 review follow-ups ----

    function test_mintAuto_receiverSeesSettingsInCallback() public {
        SettingsReader reader = new SettingsReader();
        _mintAuto(address(reader), true, 7200, 5);
        assertTrue(reader.enabled());
        assertEq(reader.interval(), 7200);
        assertEq(reader.fee(), 5);
    }

    function test_mintAuto_disabled_storesIntervalAndFee() public {
        (externalEuint64 h, bytes memory p) = _fundCreator();
        vm.recordLogs();
        vm.prank(creator);
        uint256 id =
            nft.mintAuto(alice, h, p, _segments(), uint64(block.timestamp), false, bytes32(0), false, 7200, 5);
        _assertMintLogs(vm.getRecordedLogs(), id, false, 7200, 5);
        _assertSettings(id, false, 7200, 5);
    }

    function test_transfer_ofDisabledToken_stillEmits() public {
        uint256 id = _mintAuto(alice, false, 7200, 5);
        vm.expectEmit(true, false, false, true, address(nft));
        emit AutoPayoutSet(id, false, 7200, 5);
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        _assertSettings(id, false, 7200, 5);
    }

    // ---- payout helpers ----

    /// @dev Gives the creator `units` cWETH and makes the NFT their operator.
    function _fund(uint64 units) internal returns (externalEuint64 h, bytes memory p) {
        uint256 amountWei = uint256(units) * 1e9;
        vm.deal(creator, amountWei);
        vm.startPrank(creator);
        weth.deposit{value: amountWei}();
        weth.approve(address(cweth), amountWei);
        cweth.wrap(creator, amountWei);
        cweth.setOperator(address(nft), uint48(block.timestamp + 365 days));
        vm.stopPrank();
        (h, p) = encryptUint64(units, creator, address(nft));
    }

    function _perSec(uint64 duration) internal pure returns (Segment[] memory s) {
        s = new Segment[](1);
        s[0] = Segment({duration: duration, ratePerSec: 1});
    }

    /// @dev Mints an enabled token holding `units`, paying 1 unit/s for `duration` s from `start`.
    function _mintPayout(address to, uint64 units, uint64 duration, uint64 start, uint32 interval, uint128 fee)
        internal
        returns (uint256 id)
    {
        (externalEuint64 h, bytes memory p) = _fund(units);
        vm.prank(creator);
        id = nft.mintAuto(to, h, p, _perSec(duration), start, false, bytes32(0), true, interval, fee);
    }

    /// @dev 1 unit/s for 1000 s from now, 1000 units, interval 1 hour.
    function _mintPayout(address to, uint128 fee) internal returns (uint256 id) {
        id = _mintPayout(to, 1000, 1000, uint64(block.timestamp), 3600, fee);
    }

    function _request(uint256 id, address who) internal returns (bytes32 rid) {
        vm.prank(who);
        rid = nft.requestPayout(id, 0);
    }

    function _proof(bytes32 rid) internal returns (uint64 clear, bytes memory proof) {
        clear = uint64(decrypt(rid));
        proof = buildDecryptionProof(rid, abi.encode(clear));
    }

    function _finalize(uint256 id, address who) internal returns (uint64 clear) {
        (bytes32 rid,,,) = nft.pendingPayoutOf(id);
        bytes memory proof;
        (clear, proof) = _proof(rid);
        vm.prank(who);
        nft.finalizePayout(id, clear, proof);
    }

    function _assertNoPending(uint256 id) internal view {
        (bytes32 rid, address recipient, address requester, uint128 fee) = nft.pendingPayoutOf(id);
        assertEq(rid, bytes32(0), "pending requestId");
        assertEq(recipient, address(0), "pending recipient");
        assertEq(requester, address(0), "pending requester");
        assertEq(fee, 0, "pending fee");
    }

    // ---- requestPayout preconditions ----

    function test_request_nonexistent() public {
        vm.expectRevert(EndowmentNFT.NonexistentToken.selector);
        nft.requestPayout(1, 0);
    }

    function test_request_revertsWhenDisabled() public {
        uint256 id = _mintAuto(alice, false, 3600, 0);
        vm.warp(block.timestamp + 100);
        vm.expectRevert(AutoPayoutEndowmentNFT.AutoPayoutDisabled.selector);
        nft.requestPayout(id, 0);
    }

    function test_request_revertsWhenPending() public {
        uint256 id = _mintPayout(alice, 5);
        vm.warp(block.timestamp + 100);
        _request(id, keeper);
        vm.warp(block.timestamp + 7200);
        vm.expectRevert(AutoPayoutEndowmentNFT.PayoutPending.selector);
        nft.requestPayout(id, 0);
        // PayoutPending is checked before FeeTooLow.
        vm.expectRevert(AutoPayoutEndowmentNFT.PayoutPending.selector);
        nft.requestPayout(id, 6);
    }

    function test_request_revertsWhenFeeTooLow() public {
        uint256 id = _mintPayout(alice, 5);
        vm.warp(block.timestamp + 100);
        vm.expectRevert(abi.encodeWithSelector(AutoPayoutEndowmentNFT.FeeTooLow.selector, uint128(5)));
        nft.requestPayout(id, 6);
        vm.prank(keeper);
        nft.requestPayout(id, 5);
    }

    function test_request_revertsWhenTooSoon() public {
        uint256 id = _mintPayout(alice, 0);
        vm.warp(block.timestamp + 100);
        uint64 requestedAt = uint64(block.timestamp);
        _request(id, keeper);
        _finalize(id, keeper);
        vm.warp(block.timestamp + 10);
        vm.expectRevert(abi.encodeWithSelector(AutoPayoutEndowmentNFT.PayoutTooSoon.selector, requestedAt + 3600));
        nft.requestPayout(id, 0);
    }

    function test_request_revertsBeforeScheduleStart() public {
        uint64 start = uint64(block.timestamp + 500);
        uint256 id = _mintPayout(alice, 1000, 1000, start, 3600, 0);
        vm.expectRevert(AutoPayoutEndowmentNFT.ScheduleNotStarted.selector);
        nft.requestPayout(id, 0);
        vm.warp(start - 1);
        vm.expectRevert(AutoPayoutEndowmentNFT.ScheduleNotStarted.selector);
        nft.requestPayout(id, 0);
        vm.warp(start);
        _request(id, keeper);
    }

    function test_request_firstIsImmediate_thenWaitsInterval() public {
        uint256 id = _mintPayout(alice, 1000, 100000, uint64(block.timestamp), 3600, 0);
        uint64 t0 = uint64(block.timestamp);
        _request(id, keeper);
        (,,, uint64 last) = nft.autoPayoutOf(id);
        assertEq(last, t0);
        assertEq(_finalize(id, keeper), 0);

        vm.warp(t0 + 3599);
        vm.expectRevert(abi.encodeWithSelector(AutoPayoutEndowmentNFT.PayoutTooSoon.selector, t0 + 3600));
        nft.requestPayout(id, 0);

        vm.warp(t0 + 3600);
        _request(id, keeper);
        (,,, last) = nft.autoPayoutOf(id);
        assertEq(last, t0 + 3600);
        // 1000 units at 1 unit/s, all accrued by t0 + 1000.
        assertEq(_finalize(id, keeper), 1000);
    }

    function test_lastRequestAt_survivesTransfer() public {
        uint256 id = _mintPayout(alice, 0);
        vm.warp(block.timestamp + 100);
        uint64 requestedAt = uint64(block.timestamp);
        _request(id, keeper);
        _finalize(id, keeper);

        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        vm.prank(bob);
        nft.setAutoPayout(id, true, 3600, 0);
        (,,, uint64 last) = nft.autoPayoutOf(id);
        assertEq(last, requestedAt);

        vm.expectRevert(abi.encodeWithSelector(AutoPayoutEndowmentNFT.PayoutTooSoon.selector, requestedAt + 3600));
        nft.requestPayout(id, 0);
        assertFalse(nft.payoutDue(id));
    }

    // ---- round trip ----

    function test_roundTrip_paysOwnerEth() public {
        uint256 id = _mintPayout(alice, 0);
        vm.warp(block.timestamp + 100);
        uint256 aliceBefore = alice.balance;

        vm.expectEmit(true, false, true, true, address(nft));
        emit PayoutRequested(id, bytes32(0), alice, keeper, 0);
        bytes32 rid = _request(id, keeper);
        assertTrue(rid != bytes32(0));

        (bytes32 pRid, address pRecipient, address pRequester, uint128 pFee) = nft.pendingPayoutOf(id);
        assertEq(pRid, rid);
        assertEq(pRecipient, alice);
        assertEq(pRequester, keeper);
        assertEq(pFee, 0);
        assertFalse(nft.payoutDue(id));
        // The claimable balance was taken, and the emptied balance is still the owner's to read.
        assertEq(decrypt(nft.distributionHandle(id)), 0);

        (uint64 clear, bytes memory proof) = _proof(rid);
        assertEq(clear, 100);
        vm.expectEmit(true, true, false, true, address(nft));
        emit PayoutPaid(id, rid, 100 * 1e9, 0, false);
        vm.prank(finisher);
        nft.finalizePayout(id, clear, proof);

        assertEq(alice.balance - aliceBefore, uint256(clear) * 1e9);
        _assertNoPending(id);
        assertEq(decrypt(nft.distributionHandle(id)), 0);
        (uint64 paidAt, uint256 amountWei) = nft.lastPayoutOf(id);
        assertEq(paidAt, block.timestamp);
        assertEq(amountWei, 100 * 1e9);
        assertEq(weth.balanceOf(address(nft)), 0);
        assertEq(address(nft).balance, 0);
        assertEq(cweth.unwrapRequester(rid), address(0));
        assertEq(decrypt(cweth.confidentialBalanceOf(address(nft))), 900);
    }

    function test_fee_paidToRequester_cappedAtTenPercent() public {
        // A fee far above the payout pays 10%.
        uint256 a = _mintPayout(alice, 1 ether);
        // A tiny fee is paid in full.
        uint256 b = _mintPayout(bob, 1);
        vm.warp(block.timestamp + 100);

        _request(a, keeper);
        (bytes32 rid,,,) = nft.pendingPayoutOf(a);
        (uint64 clear, bytes memory proof) = _proof(rid);
        vm.expectEmit(true, true, false, true, address(nft));
        emit PayoutPaid(a, rid, 100 * 1e9, 10 * 1e9, false);
        vm.prank(finisher);
        nft.finalizePayout(a, clear, proof);
        assertEq(keeper.balance, 10 * 1e9);
        assertEq(alice.balance, 90 * 1e9);
        assertEq(finisher.balance, 0);

        _request(b, keeper);
        _finalize(b, finisher);
        assertEq(keeper.balance, 10 * 1e9 + 1);
        assertEq(bob.balance, 100 * 1e9 - 1);
        assertEq(finisher.balance, 0);
    }

    function test_fee_andRecipient_snapshottedAtRequest() public {
        uint256 id = _mintPayout(alice, 7);
        vm.warp(block.timestamp + 100);
        _request(id, keeper);

        vm.startPrank(alice);
        nft.setAutoPayout(id, true, 3600, 0);
        nft.transferFrom(alice, bob, id);
        vm.stopPrank();

        assertEq(_finalize(id, finisher), 100);
        assertEq(keeper.balance, 7);
        assertEq(alice.balance, 100 * 1e9 - 7);
        assertEq(bob.balance, 0);
    }

    function test_finalize_afterThirdPartyFinalizedOnWrapper() public {
        uint256 id = _mintPayout(alice, 0);
        vm.warp(block.timestamp + 100);
        bytes32 rid = _request(id, keeper);
        (uint64 clear, bytes memory proof) = _proof(rid);

        vm.prank(finisher);
        cweth.finalizeUnwrap(rid, clear, proof);
        assertEq(cweth.unwrapRequester(rid), address(0));
        assertEq(weth.balanceOf(address(nft)), 100 * 1e9);
        assertEq(alice.balance, 0);

        vm.prank(keeper);
        nft.finalizePayout(id, clear, proof);
        assertEq(alice.balance, 100 * 1e9);
        assertEq(weth.balanceOf(address(nft)), 0);
        _assertNoPending(id);

        vm.expectRevert(AutoPayoutEndowmentNFT.NoPendingPayout.selector);
        nft.finalizePayout(id, clear, proof);
        assertEq(alice.balance, 100 * 1e9);
    }

    function test_finalize_wrongCleartext_reverts() public {
        uint256 id = _mintPayout(alice, 0);
        vm.warp(block.timestamp + 100);
        bytes32 rid = _request(id, keeper);
        (uint64 clear, bytes memory proof) = _proof(rid);

        vm.expectRevert();
        nft.finalizePayout(id, clear + 1, proof);

        // A valid proof for another handle does not pass either.
        bytes32 other = euint64.unwrap(nft.distributionHandle(id));
        bytes memory otherProof = buildDecryptionProof(other, abi.encode(clear));
        vm.expectRevert();
        nft.finalizePayout(id, clear, otherProof);

        (bytes32 pRid,,,) = nft.pendingPayoutOf(id);
        assertEq(pRid, rid);
        nft.finalizePayout(id, clear, proof);
        assertEq(alice.balance, 100 * 1e9);
    }

    function test_finalize_noPending_reverts() public {
        uint256 id = _mintPayout(alice, 0);
        vm.expectRevert(AutoPayoutEndowmentNFT.NoPendingPayout.selector);
        nft.finalizePayout(id, 0, "");
        vm.expectRevert(AutoPayoutEndowmentNFT.NoPendingPayout.selector);
        nft.finalizePayout(99, 0, "");
    }

    function test_finalize_twice_reverts() public {
        uint256 id = _mintPayout(alice, 0);
        vm.warp(block.timestamp + 100);
        bytes32 rid = _request(id, keeper);
        (uint64 clear, bytes memory proof) = _proof(rid);
        nft.finalizePayout(id, clear, proof);
        vm.expectRevert(AutoPayoutEndowmentNFT.NoPendingPayout.selector);
        nft.finalizePayout(id, clear, proof);
        assertEq(alice.balance, 100 * 1e9);
    }

    function test_zeroPayout_clearsPending_paysNothing() public {
        uint256 id = _mintPayout(alice, 5);
        vm.warp(block.timestamp + 100);
        vm.prank(alice);
        nft.claim(id);

        bytes32 rid = _request(id, keeper);
        (uint64 clear, bytes memory proof) = _proof(rid);
        assertEq(clear, 0);
        vm.expectEmit(true, true, false, true, address(nft));
        emit PayoutPaid(id, rid, 0, 0, false);
        nft.finalizePayout(id, clear, proof);

        assertEq(alice.balance, 0);
        assertEq(keeper.balance, 0);
        _assertNoPending(id);
        (uint64 paidAt, uint256 amountWei) = nft.lastPayoutOf(id);
        assertEq(paidAt, block.timestamp);
        assertEq(amountWei, 0);
        assertEq(cweth.unwrapRequester(rid), address(0));
    }

    // ---- payment failures ----

    function test_recipientRejectsEth_paidInWeth() public {
        RejectingReceiver owner_ = new RejectingReceiver();
        uint256 id = _mintPayout(address(owner_), 3);
        vm.warp(block.timestamp + 100);
        bytes32 rid = _request(id, keeper);
        (uint64 clear, bytes memory proof) = _proof(rid);

        vm.expectEmit(true, true, false, true, address(nft));
        emit PayoutPaid(id, rid, 100 * 1e9, 3, true);
        nft.finalizePayout(id, clear, proof);

        assertEq(weth.balanceOf(address(owner_)), 100 * 1e9 - 3);
        assertEq(address(owner_).balance, 0);
        assertEq(keeper.balance, 3);
        assertEq(weth.balanceOf(address(nft)), 0);
        assertEq(address(nft).balance, 0);
    }

    function test_recipientBurnsGas_paidInWeth() public {
        GasBurner owner_ = new GasBurner();
        uint256 id = _mintPayout(address(owner_), 0);
        vm.warp(block.timestamp + 100);
        bytes32 rid = _request(id, keeper);
        (uint64 clear, bytes memory proof) = _proof(rid);

        vm.expectEmit(true, true, false, true, address(nft));
        emit PayoutPaid(id, rid, 100 * 1e9, 0, true);
        uint256 gasBefore = gasleft();
        nft.finalizePayout(id, clear, proof);
        assertLt(gasBefore - gasleft(), 1_000_000, "bounded gas");

        assertEq(weth.balanceOf(address(owner_)), 100 * 1e9);
        assertEq(address(owner_).balance, 0);
    }

    function test_requesterRejectsEth_feeGoesToRecipient() public {
        RejectingReceiver requester = new RejectingReceiver();
        uint256 id = _mintPayout(alice, 5);
        vm.warp(block.timestamp + 100);
        bytes32 rid = requester.requestPayout(nft, id);
        (uint64 clear, bytes memory proof) = _proof(rid);

        vm.expectEmit(true, true, false, true, address(nft));
        emit PayoutPaid(id, rid, 100 * 1e9, 0, false);
        nft.finalizePayout(id, clear, proof);

        assertEq(alice.balance, 100 * 1e9);
        assertEq(address(requester).balance, 0);
        assertEq(weth.balanceOf(address(requester)), 0);
    }

    function test_bothRejectEth_recipientGetsAllInWeth() public {
        RejectingReceiver owner_ = new RejectingReceiver();
        RejectingReceiver requester = new RejectingReceiver();
        uint256 id = _mintPayout(address(owner_), 5);
        vm.warp(block.timestamp + 100);
        bytes32 rid = requester.requestPayout(nft, id);
        (uint64 clear, bytes memory proof) = _proof(rid);

        vm.expectEmit(true, true, false, true, address(nft));
        emit PayoutPaid(id, rid, 100 * 1e9, 0, true);
        nft.finalizePayout(id, clear, proof);

        assertEq(weth.balanceOf(address(owner_)), 100 * 1e9);
        assertEq(weth.balanceOf(address(requester)), 0);
    }

    function test_reentrantRecipient_cannotReenter() public {
        ReentrantReceiver owner_ = new ReentrantReceiver(nft);
        uint256 id = _mintPayout(address(owner_), 0);
        vm.warp(block.timestamp + 7200);
        bytes32 rid = _request(id, keeper);
        (uint64 clear, bytes memory proof) = _proof(rid);

        vm.expectEmit(true, true, false, true, address(nft));
        emit PayoutPaid(id, rid, 1000 * 1e9, 0, false);
        nft.finalizePayout(id, clear, proof);

        assertEq(owner_.finalizeError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(owner_.requestError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(address(owner_).balance, 1000 * 1e9);
        _assertNoPending(id);
    }

    function test_receive_rejectsPlainEth() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok, bytes memory ret) = address(nft).call{value: 1}("");
        assertFalse(ok);
        // casting to bytes4 is safe: only the error selector is wanted
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(bytes4(ret), AutoPayoutEndowmentNFT.OnlyWeth.selector);
    }

    // ---- schedule end and shortfall ----

    function test_afterScheduleEnd_onePayoutThenNothingLeft() public {
        uint64 start = uint64(block.timestamp);
        // 10000 scheduled of 20000: the other 10000 is released at the end.
        uint256 id = _mintPayout(alice, 20000, 10000, start, 3600, 0);

        vm.warp(start + 5000);
        _request(id, keeper);
        assertEq(_finalize(id, keeper), 5000);

        // The first request at the end takes the rest of the schedule and the leftover.
        vm.warp(start + 10000);
        assertTrue(nft.payoutDue(id));
        _request(id, keeper);
        assertEq(_finalize(id, keeper), 15000);
        assertEq(alice.balance, 20000 * 1e9);
        assertTrue(nft.settledOf(id));

        vm.warp(start + 10000 + 3600);
        assertFalse(nft.payoutDue(id));
        vm.expectRevert(AutoPayoutEndowmentNFT.NothingLeft.selector);
        nft.requestPayout(id, 0);
    }

    function test_afterScheduleEnd_firstRequestLate_paysAll() public {
        uint64 start = uint64(block.timestamp);
        uint256 id = _mintPayout(alice, 2000, 1000, start, 3600, 0);
        vm.warp(start + 5000);
        _request(id, keeper);
        assertEq(_finalize(id, keeper), 2000);
        vm.warp(start + 5000 + 3600);
        vm.expectRevert(AutoPayoutEndowmentNFT.NothingLeft.selector);
        nft.requestPayout(id, 0);
    }

    function test_shortfall_paysRemainder() public {
        uint256 id = _mintPayout(alice, 50, 1000, uint64(block.timestamp), 3600, 0);
        vm.warp(block.timestamp + 100);
        _request(id, keeper);
        assertEq(_finalize(id, keeper), 50);
        assertEq(alice.balance, 50 * 1e9);
    }

    // ---- payoutDue ----

    function test_payoutDue_matchesRequest() public {
        assertFalse(nft.payoutDue(1), "nonexistent");

        uint256 id = _mintAuto(alice, false, 3600, 0);
        vm.warp(block.timestamp + 100);
        assertFalse(nft.payoutDue(id), "disabled");
        vm.expectRevert(AutoPayoutEndowmentNFT.AutoPayoutDisabled.selector);
        nft.requestPayout(id, 0);

        vm.prank(alice);
        nft.setAutoPayout(id, true, 3600, 0);
        assertTrue(nft.payoutDue(id), "due");
        _request(id, keeper);

        assertFalse(nft.payoutDue(id), "pending");
        vm.expectRevert(AutoPayoutEndowmentNFT.PayoutPending.selector);
        nft.requestPayout(id, 0);

        _finalize(id, keeper);
        assertFalse(nft.payoutDue(id), "too soon");
        vm.warp(block.timestamp + 3600);
        assertTrue(nft.payoutDue(id), "due again");

        uint256 later = _mintPayout(bob, 1000, 1000, uint64(block.timestamp + 10), 3600, 0);
        assertFalse(nft.payoutDue(later), "not started");
        vm.expectRevert(AutoPayoutEndowmentNFT.ScheduleNotStarted.selector);
        nft.requestPayout(later, 0);
    }

    function test_pendingAndLastPayout_zeroForNewToken() public {
        uint256 id = _mintPayout(alice, 0);
        _assertNoPending(id);
        (uint64 paidAt, uint256 amountWei) = nft.lastPayoutOf(id);
        assertEq(paidAt, 0);
        assertEq(amountWei, 0);
    }

    /// A finaliser who sends too little gas must not be able to make an ETH payment fail
    /// and so force a WETH payment, or move the fee away from the requester.
    function test_finalize_withTooLittleGas_cannotDivertPayments() public {
        GasHungryReceiver owner_ = new GasHungryReceiver();
        GasHungryReceiver requester = new GasHungryReceiver();
        uint256 id = _mintPayout(address(owner_), 5);
        vm.warp(block.timestamp + 100);
        bytes32 rid = requester.requestPayout(nft, id);
        (uint64 clear, bytes memory proof) = _proof(rid);
        bytes memory data = abi.encodeCall(nft.finalizePayout, (id, clear, proof));

        uint256 successes;
        for (uint256 g = 150_000; g < 800_000; g += 500) {
            uint256 snap = vm.snapshotState();
            (bool ok,) = address(nft).call{gas: g}(data);
            if (ok) {
                successes++;
                assertEq(address(requester).balance, 5, "fee paid in ETH");
                assertEq(address(owner_).balance, 100 * 1e9 - 5, "share paid in ETH");
                assertEq(weth.balanceOf(address(owner_)), 0, "no WETH");
            }
            vm.revertToState(snap);
        }
        assertGt(successes, 0, "some gas limit is enough");
    }
}
