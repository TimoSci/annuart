// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FHE, euint64, euint128, externalEuint64} from "@fhevm/solidity/lib/FHE.sol";
import {IERC7984} from "@openzeppelin/confidential-contracts/interfaces/IERC7984.sol";
import {EndowmentNFT} from "./EndowmentNFT.sol";
import {Schedule, Segment} from "./libraries/Schedule.sol";

/// @notice An EndowmentNFT whose payout rate is encrypted. Each segment's `ratePerSec`
///         is read as a public weight, not an amount: a token pays
///         unit * weight * seconds / 2**UNIT_SHIFT, where `unit` is encrypted at mint and
///         readable by the creator and the first owner only.
///
///         What stays public: the schedule's shape (durations and weights), its start and
///         end, the name, and when the token is accrued, claimed or transferred. The
///         endowment, the unit and so the absolute rate, and the distribution stay encrypted.
///
///         The unit is encrypted, so the contract cannot refuse a zero unit: such a token
///         pays nothing until a fixed-end schedule ends and releases the whole endowment
///         (an indefinite one then pays nothing at all). Mint only through mintPrivate;
///         the inherited mint always reverts.
contract PrivateRateEndowmentNFT is EndowmentNFT {
    /// @notice The unit is a fixed-point number of token base units with this many fractional bits.
    uint8 public constant UNIT_SHIFT = 32;
    /// @notice The largest weight a segment may have.
    uint64 public constant MAX_WEIGHT = type(uint32).max;

    struct Rate {
        euint128 unit;  // base units per weight-second, times 2**UNIT_SHIFT; ACL = contract, creator, first owner
        euint128 carry; // the fractional part not yet paid, below 2**UNIT_SHIFT; ACL = contract only
    }

    mapping(uint256 => Rate) internal _rates;

    error WeightTooLarge();
    error RateRequired();

    constructor(IERC7984 token_) EndowmentNFT(token_) {}

    /// @notice As mint, with the unit encrypted under the same input proof as the endowment.
    function mintPrivate(
        address to,
        externalEuint64 encEndowment,
        externalEuint64 encUnit,
        bytes calldata inputProof,
        Segment[] calldata segments,
        uint64 scheduleStart,
        bool topUpsAllowed,
        bytes32 name_
    ) external nonReentrant returns (uint256 tokenId) {
        if (inputProof.length == 0) revert EmptyInputProof();
        for (uint256 i = 0; i < segments.length; i++) {
            if (segments[i].ratePerSec > MAX_WEIGHT) revert WeightTooLarge();
        }

        // Stage the rate on the id about to be minted. mint is disabled and mintPrivate is
        // nonReentrant, so that id cannot be taken in between.
        uint256 id = _nextId + 1;
        Rate storage r = _rates[id];
        r.unit = FHE.asEuint128(FHE.fromExternal(encUnit, inputProof));
        FHE.allowThis(r.unit);
        FHE.allow(r.unit, msg.sender);
        FHE.allow(r.unit, to);
        r.carry = FHE.asEuint128(0);
        FHE.allowThis(r.carry);

        tokenId = _mintEndowment(to, encEndowment, inputProof, segments, scheduleStart, topUpsAllowed, name_);
        assert(tokenId == id);
    }

    /// @notice Disabled: a token of this contract needs an encrypted unit. Use mintPrivate.
    function mint(address, externalEuint64, bytes calldata, Segment[] calldata, uint64, bool, bytes32)
        external
        pure
        override
        returns (uint256)
    {
        revert RateRequired();
    }

    /// @return the handle of the token's encrypted unit.
    function unitHandle(uint256 tokenId) external view returns (euint128) {
        return _rates[tokenId].unit;
    }

    /// @dev The settled and past-the-end cases are the base's. Before the end, pays
    ///      unit * weighted seconds, carrying the fraction below 2**UNIT_SHIFT to the next
    ///      accrual. unit < 2**64 and the weighted seconds < 2**64, so acc cannot overflow.
    function _accrue(uint256 tokenId) internal override {
        Endowment storage e = _endowments[tokenId];
        // Same comparison as the base's: a validator's leeway of seconds moves the end by as much.
        // forge-lint: disable-next-line(block-timestamp)
        if (e.settled || block.timestamp >= Schedule.scheduleEnd(e.schedule, e.scheduleStart)) {
            super._accrue(tokenId);
            return;
        }
        uint64 nowTs = uint64(block.timestamp);

        uint64 w = Schedule.integrate(e.schedule, e.scheduleStart, e.lastAccrualAt, nowTs);
        if (w == 0) return;
        Rate storage r = _rates[tokenId];
        euint128 acc = FHE.add(FHE.mul(r.unit, uint128(w)), r.carry);
        r.carry = FHE.and(acc, uint128(type(uint32).max));
        euint64 actual = FHE.asEuint64(FHE.min(FHE.shr(acc, UNIT_SHIFT), FHE.asEuint128(e.endowmentRemaining)));
        e.endowmentRemaining = FHE.sub(e.endowmentRemaining, actual);
        e.distribution = FHE.add(e.distribution, actual);
        FHE.allowThis(r.carry);
        FHE.allowThis(e.endowmentRemaining);
        FHE.allowThis(e.distribution);
        FHE.allow(e.distribution, ownerOf(tokenId));
        e.lastAccrualAt = nowTs;
    }
}
