// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FHE, euint64, externalEuint64} from "@fhevm/solidity/lib/FHE.sol";
import {IERC7984} from "@openzeppelin/confidential-contracts/interfaces/IERC7984.sol";
import {ERC7984ERC20Wrapper} from "@openzeppelin/confidential-contracts/token/ERC7984/extensions/ERC7984ERC20Wrapper.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EndowmentNFT} from "./EndowmentNFT.sol";
import {Schedule, Segment} from "./libraries/Schedule.sol";

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @notice An EndowmentNFT whose token is an ERC-7984 wrapper over WETH, and whose owner
///         can let anyone pay out the claimable balance to them as ETH, at most once per
///         interval, for a fee. With automatic payouts off it behaves exactly like an
///         EndowmentNFT. There are no admin functions and no contract-owner role.
contract AutoPayoutEndowmentNFT is EndowmentNFT {
    uint32 public constant DEFAULT_INTERVAL = 1 days;
    uint32 public constant MIN_INTERVAL = 1 hours;
    uint32 public constant MAX_INTERVAL = 365 days;
    /// @notice Gas given to each ETH payment, so a recipient cannot exhaust the finaliser's gas.
    uint256 public constant SEND_GAS = 100000;

    struct AutoPayout {
        bool enabled;
        uint32 interval;      // seconds; zero only before the token is minted
        uint128 fee;          // wei of ETH offered to whoever requests a payout
        uint64 lastRequestAt; // time of the last payout request; zero when none
    }

    /// @dev A payout requested but not yet finalised. requestId is zero when there is none.
    struct PendingPayout {
        bytes32 requestId; // the wrapper's unwrap request id, which is the handle of the amount
        address recipient; // the owner when the payout was requested
        address requester;
        uint128 fee;       // the fee when the payout was requested
    }

    struct LastPayout {
        uint64 paidAt;
        uint256 amountWei;
    }

    ERC7984ERC20Wrapper internal immutable _wrapper;
    /// @notice The wrapper's underlying token (WETH).
    address public immutable weth;
    /// @notice Units of WETH per unit of the wrapper token.
    uint256 public immutable rate;

    mapping(uint256 => AutoPayout) internal _autoPayouts;
    mapping(uint256 => PendingPayout) internal _pendingPayouts;
    mapping(uint256 => LastPayout) internal _lastPayouts;

    /// @dev Emitted on every change, including the settings given at mint and the
    ///      reset of `enabled` on transfer.
    event AutoPayoutSet(uint256 indexed tokenId, bool enabled, uint32 interval, uint128 fee);

    event PayoutRequested(
        uint256 indexed tokenId, bytes32 indexed requestId, address indexed recipient, address requester, uint128 fee
    );
    /// @param amountWei the whole payout, fee included.
    /// @param feeWei the fee actually paid to the requester; zero when it went to the recipient.
    /// @param paidInWeth the recipient's share was paid in WETH because the ETH payment failed.
    event PayoutPaid(
        uint256 indexed tokenId, bytes32 indexed requestId, uint256 amountWei, uint256 feeWei, bool paidInWeth
    );

    error InvalidInterval();
    error NotWethWrapper();
    error MintIdMismatch();
    error AutoPayoutDisabled();
    error PayoutPending();
    error PayoutTooSoon(uint64 notBefore);
    error ScheduleNotStarted();
    error NothingLeft();
    error FeeTooLow(uint128 fee);
    error NoPendingPayout();
    error OnlyWeth();
    error InsufficientGas();

    constructor(ERC7984ERC20Wrapper wrapper_) EndowmentNFT(IERC7984(address(wrapper_))) {
        address underlying = wrapper_.underlying();
        if (underlying == address(0)) revert NotWethWrapper();
        _wrapper = wrapper_;
        weth = underlying;
        rate = wrapper_.rate();
    }

    /// @notice Accepts ETH only from WETH, when a payout is converted.
    receive() external payable {
        if (msg.sender != weth) revert OnlyWeth();
    }

    /// @notice As mint, with the token's automatic payout settings given up front.
    function mintAuto(
        address to,
        externalEuint64 encEndowment,
        bytes calldata inputProof,
        Segment[] calldata segments,
        uint64 scheduleStart,
        bool topUpsAllowed,
        bytes32 name_,
        bool enabled,
        uint32 interval,
        uint128 fee
    ) external nonReentrant returns (uint256 tokenId) {
        _checkInterval(interval);
        // Stage the settings on the id about to be minted; _update announces them when
        // the token comes into existence. mint and mintAuto are nonReentrant, so that id
        // cannot be taken in between.
        uint256 expectedId = _nextId + 1;
        AutoPayout storage s = _autoPayouts[expectedId];
        s.enabled = enabled;
        s.interval = interval;
        s.fee = fee;
        tokenId = _mintEndowment(to, encEndowment, inputProof, segments, scheduleStart, topUpsAllowed, name_);
        if (tokenId != expectedId) revert MintIdMismatch();
    }

    /// @notice Sets all three settings. Current owner only.
    function setAutoPayout(uint256 tokenId, bool enabled, uint32 interval, uint128 fee) external {
        _requireMinted(tokenId);
        if (msg.sender != ownerOf(tokenId)) revert NotOwner();
        _checkInterval(interval);
        AutoPayout storage s = _autoPayouts[tokenId];
        s.enabled = enabled;
        s.interval = interval;
        s.fee = fee;
        emit AutoPayoutSet(tokenId, enabled, interval, fee);
    }

    function autoPayoutOf(uint256 tokenId)
        external
        view
        returns (bool enabled, uint32 interval, uint128 fee, uint64 lastRequestAt)
    {
        _requireMinted(tokenId);
        AutoPayout storage s = _autoPayouts[tokenId];
        return (s.enabled, s.interval, s.fee, s.lastRequestAt);
    }

    /// @notice Takes the token's whole claimable balance and asks the wrapper to unwrap it,
    ///         to be paid to the current owner by finalizePayout. Anyone may call this, at
    ///         most once per interval. The recipient and fee are fixed now.
    /// @param minFee reverts if the token's fee is below this, so a lowered fee cannot
    ///        catch the caller out.
    function requestPayout(uint256 tokenId, uint128 minFee) external nonReentrant returns (bytes32 requestId) {
        _requireMinted(tokenId);
        AutoPayout storage s = _autoPayouts[tokenId];
        if (!s.enabled) revert AutoPayoutDisabled();
        if (_pendingPayouts[tokenId].requestId != bytes32(0)) revert PayoutPending();
        if (s.fee < minFee) revert FeeTooLow(s.fee);
        uint64 last = s.lastRequestAt;
        // Intervals are an hour or more, so a validator's few seconds of leeway do not matter.
        // forge-lint: disable-next-line(block-timestamp)
        if (last != 0 && block.timestamp < uint256(last) + s.interval) {
            revert PayoutTooSoon(last + s.interval);
        }
        Endowment storage e = _endowments[tokenId];
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < e.scheduleStart) revert ScheduleNotStarted();
        if (last != 0 && last >= Schedule.scheduleEnd(e.schedule, e.scheduleStart)) revert NothingLeft();

        address recipient = ownerOf(tokenId);
        euint64 amt = _takeDistribution(tokenId, recipient);
        FHE.allowTransient(amt, address(_wrapper));
        requestId = _wrapper.unwrap(address(this), address(this), amt);

        _pendingPayouts[tokenId] =
            PendingPayout({requestId: requestId, recipient: recipient, requester: msg.sender, fee: s.fee});
        s.lastRequestAt = uint64(block.timestamp);
        emit PayoutRequested(tokenId, requestId, recipient, msg.sender, s.fee);
    }

    /// @notice Pays out the pending payout once its amount has been publicly decrypted.
    ///         Anyone may call this. The fee, at most a tenth of the payout, goes to the
    ///         requester and the rest to the recipient, in ETH.
    function finalizePayout(uint256 tokenId, uint64 cleartextAmount, bytes calldata decryptionProof)
        external
        nonReentrant
    {
        PendingPayout memory p = _pendingPayouts[tokenId];
        if (p.requestId == bytes32(0)) revert NoPendingPayout();

        // Verified here, not left to the wrapper: anyone may finalise the unwrap there first.
        bytes32[] memory handles = new bytes32[](1);
        handles[0] = p.requestId;
        FHE.checkSignatures(handles, abi.encode(cleartextAmount), decryptionProof);

        uint256 amountWei = uint256(cleartextAmount) * rate;
        delete _pendingPayouts[tokenId];
        _lastPayouts[tokenId] = LastPayout({paidAt: uint64(block.timestamp), amountWei: amountWei});

        // If the unwrap is still open, finish it; otherwise someone already did and the
        // WETH is already here.
        if (_wrapper.unwrapRequester(p.requestId) == address(this)) {
            _wrapper.finalizeUnwrap(p.requestId, cleartextAmount, decryptionProof);
        }

        uint256 feeWei;
        bool paidInWeth;
        if (amountWei != 0) {
            IWETH(weth).withdraw(amountWei);
            feeWei = p.fee < amountWei / 10 ? p.fee : amountWei / 10;
            uint256 share = amountWei - feeWei;
            if (feeWei != 0 && !_sendEth(p.requester, feeWei)) {
                share += feeWei;
                feeWei = 0;
            }
            if (!_sendEth(p.recipient, share)) {
                IWETH(weth).deposit{value: share}();
                SafeERC20.safeTransfer(IERC20(weth), p.recipient, share);
                paidInWeth = true;
            }
        }
        emit PayoutPaid(tokenId, p.requestId, amountWei, feeWei, paidInWeth);
    }

    /// @return requestId zero, with every other field zero, when no payout is pending.
    function pendingPayoutOf(uint256 tokenId)
        external
        view
        returns (bytes32 requestId, address recipient, address requester, uint128 fee)
    {
        PendingPayout storage p = _pendingPayouts[tokenId];
        return (p.requestId, p.recipient, p.requester, p.fee);
    }

    /// @return whether requestPayout(tokenId, 0) would be accepted now; false for a
    ///         nonexistent token.
    function payoutDue(uint256 tokenId) external view returns (bool) {
        if (_ownerOf(tokenId) == address(0)) return false;
        AutoPayout storage s = _autoPayouts[tokenId];
        if (!s.enabled) return false;
        if (_pendingPayouts[tokenId].requestId != bytes32(0)) return false;
        uint64 last = s.lastRequestAt;
        // forge-lint: disable-next-line(block-timestamp)
        if (last != 0 && block.timestamp < uint256(last) + s.interval) return false;
        Endowment storage e = _endowments[tokenId];
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < e.scheduleStart) return false;
        if (last != 0 && last >= Schedule.scheduleEnd(e.schedule, e.scheduleStart)) return false;
        return true;
    }

    /// @return paidAt zero, and amountWei zero, before the first finalised payout.
    function lastPayoutOf(uint256 tokenId) external view returns (uint64 paidAt, uint256 amountWei) {
        LastPayout storage l = _lastPayouts[tokenId];
        return (l.paidAt, l.amountWei);
    }

    /// @notice The number of tokens minted so far; ids run from 1 to this number.
    function totalMinted() external view returns (uint256) {
        return _nextId;
    }

    /// @dev Sends ETH with SEND_GAS and copies no return data, so the recipient can neither
    ///      exhaust the caller's gas nor bloat its memory. Reverts unless enough gas is left
    ///      for the recipient to get all of SEND_GAS (after the 63/64 rule and the call's
    ///      own cost), so a finaliser cannot starve a payment on purpose to force a WETH
    ///      payment or move the fee away from the requester.
    function _sendEth(address to, uint256 amount) internal returns (bool ok) {
        uint256 gasLimit = SEND_GAS;
        if (gasleft() < (gasLimit * 64) / 63 + 40_000) revert InsufficientGas();
        assembly ("memory-safe") {
            ok := call(gasLimit, to, amount, 0, 0, 0, 0)
        }
    }

    function _checkInterval(uint32 interval) internal pure {
        if (interval < MIN_INTERVAL || interval > MAX_INTERVAL) revert InvalidInterval();
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = super._update(to, tokenId, auth);

        AutoPayout storage s = _autoPayouts[tokenId];
        if (from == address(0)) {
            // Mint. A plain mint staged nothing, so it gets the defaults: off, one day, no fee.
            if (s.interval == 0) s.interval = DEFAULT_INTERVAL;
            // Emitted here, before _safeMint's receiver callback, and after EndowmentMinted.
            emit AutoPayoutSet(tokenId, s.enabled, s.interval, s.fee);
        } else if (to != address(0) && to != from) {
            // A new owner never inherits public payouts they did not choose.
            s.enabled = false;
            emit AutoPayoutSet(tokenId, false, s.interval, s.fee);
        }
    }
}
