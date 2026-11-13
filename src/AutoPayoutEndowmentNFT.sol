// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {externalEuint64} from "@fhevm/solidity/lib/FHE.sol";
import {IERC7984} from "@openzeppelin/confidential-contracts/interfaces/IERC7984.sol";
import {IERC7984ERC20Wrapper} from "@openzeppelin/confidential-contracts/interfaces/IERC7984ERC20Wrapper.sol";
import {EndowmentNFT} from "./EndowmentNFT.sol";
import {Segment} from "./libraries/Schedule.sol";

/// @notice An EndowmentNFT whose token is an ERC-7984 wrapper over WETH, and whose owner
///         can let anyone pay out the claimable balance to them as ETH, at most once per
///         interval, for a fee. With automatic payouts off it behaves exactly like an
///         EndowmentNFT. There are no admin functions and no contract-owner role.
contract AutoPayoutEndowmentNFT is EndowmentNFT {
    uint32 public constant DEFAULT_INTERVAL = 1 days;
    uint32 public constant MIN_INTERVAL = 1 hours;
    uint32 public constant MAX_INTERVAL = 365 days;

    struct AutoPayout {
        bool enabled;
        uint32 interval;      // seconds; zero only before the token is minted
        uint128 fee;          // wei of ETH offered to whoever requests a payout
        uint64 lastRequestAt; // time of the last payout request; zero when none
    }

    /// @notice The wrapper's underlying token (WETH).
    address public immutable weth;
    /// @notice Units of WETH per unit of the wrapper token.
    uint256 public immutable rate;

    mapping(uint256 => AutoPayout) internal _autoPayouts;

    /// @dev Emitted on every change, including the settings given at mint and the
    ///      reset of `enabled` on transfer.
    event AutoPayoutSet(uint256 indexed tokenId, bool enabled, uint32 interval, uint128 fee);

    error InvalidInterval();
    error NotWethWrapper();

    constructor(IERC7984ERC20Wrapper wrapper_) EndowmentNFT(IERC7984(address(wrapper_))) {
        address underlying = wrapper_.underlying();
        if (underlying == address(0)) revert NotWethWrapper();
        weth = underlying;
        rate = wrapper_.rate();
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
        AutoPayout storage s = _autoPayouts[_nextId + 1];
        s.enabled = enabled;
        s.interval = interval;
        s.fee = fee;
        tokenId = _mintEndowment(to, encEndowment, inputProof, segments, scheduleStart, topUpsAllowed, name_);
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

    /// @notice The number of tokens minted so far; ids run from 1 to this number.
    function totalMinted() external view returns (uint256) {
        return _nextId;
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
