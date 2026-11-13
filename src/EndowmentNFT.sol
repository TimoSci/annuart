// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {FHE, euint64, externalEuint64} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {IERC7984} from "@openzeppelin/confidential-contracts/interfaces/IERC7984.sol";
import {Schedule, Segment, INDEFINITE} from "./libraries/Schedule.sol";

contract EndowmentNFT is ERC721, ReentrancyGuard, ZamaEthereumConfig {
    using Schedule for Segment[];

    struct Endowment {
        euint64 endowmentRemaining; // SECRET: ACL = contract only
        euint64 distribution;       // owner-readable: ACL = contract + current owner
        uint64 lastAccrualAt;
        uint64 scheduleStart;
        bool topUpsAllowed;
        bool settled;               // fixed-end schedule is over and the leftover was released
        bytes32 name;               // public, set once at mint; zero when unnamed
        Segment[] schedule;
    }

    IERC7984 public immutable token;
    uint256 internal _nextId;
    mapping(uint256 => Endowment) internal _endowments;

    /// @dev Deliberately omits the schedule; read it via scheduleOf.
    event EndowmentMinted(
        uint256 indexed tokenId,
        address indexed creator,
        address indexed to,
        uint64 scheduleStart,
        bool topUpsAllowed,
        bytes32 name
    );

    error EmptySchedule();
    error ZeroDurationSegment();
    error IndefiniteSegmentNotLast();
    error ZeroRateIndefiniteSegment();
    error TopUpsDisabled();
    error NonexistentToken();
    error NotOwner();
    error ScheduleEnded();
    error ScheduleTooLong();
    error InvalidName();

    constructor(IERC7984 token_) ERC721("Endowment NFT", "ENDOW") {
        token = token_;
    }

    function mint(
        address to,
        externalEuint64 encEndowment,
        bytes calldata inputProof,
        Segment[] calldata segments,
        uint64 scheduleStart,
        bool topUpsAllowed,
        bytes32 name_
    ) external nonReentrant returns (uint256 tokenId) {
        return _mintEndowment(to, encEndowment, inputProof, segments, scheduleStart, topUpsAllowed, name_);
    }

    /// @dev The body of mint: pulls the endowment from the caller, stores the token's
    ///      state, emits EndowmentMinted and safe-mints the token to `to`.
    function _mintEndowment(
        address to,
        externalEuint64 encEndowment,
        bytes calldata inputProof,
        Segment[] calldata segments,
        uint64 scheduleStart,
        bool topUpsAllowed,
        bytes32 name_
    ) internal returns (uint256 tokenId) {
        if (segments.length == 0) revert EmptySchedule();
        if (!_validName(name_)) revert InvalidName();

        uint64 start = scheduleStart == 0 ? uint64(block.timestamp) : scheduleStart;

        euint64 amount = FHE.fromExternal(encEndowment, inputProof);
        FHE.allowTransient(amount, address(token));
        euint64 received = token.confidentialTransferFrom(msg.sender, address(this), amount);

        tokenId = ++_nextId;
        Endowment storage e = _endowments[tokenId];
        // Re-derive the handle: the token leaves `received` allowed to the sender (the creator).
        e.endowmentRemaining = FHE.add(received, FHE.asEuint64(0));
        e.distribution = FHE.asEuint64(0);
        e.lastAccrualAt = start;
        e.scheduleStart = start;
        e.topUpsAllowed = topUpsAllowed;
        e.name = name_;
        _storeSchedule(e, segments, start);

        FHE.allowThis(e.endowmentRemaining);
        FHE.allowThis(e.distribution);
        FHE.allow(e.distribution, to);

        // Emit before _safeMint so the event precedes anything the receiver callback does.
        emit EndowmentMinted(tokenId, msg.sender, to, start, topUpsAllowed, name_);
        _safeMint(to, tokenId);
    }

    /// @dev Validates the segments and copies them into storage.
    function _storeSchedule(Endowment storage e, Segment[] calldata segments, uint64 start) internal {
        // start + every fixed duration must stay below type(uint64).max, so that
        // scheduleEnd == type(uint64).max means "indefinite" and nothing else.
        uint256 fixedEnd = start;
        for (uint256 i = 0; i < segments.length; i++) {
            if (segments[i].duration == 0) revert ZeroDurationSegment();
            if (segments[i].duration == INDEFINITE) {
                if (i != segments.length - 1) revert IndefiniteSegmentNotLast();
                if (segments[i].ratePerSec == 0) revert ZeroRateIndefiniteSegment();
            } else {
                fixedEnd += segments[i].duration;
            }
            e.schedule.push(segments[i]);
        }
        if (fixedEnd >= type(uint64).max) revert ScheduleTooLong();
    }

    /// @dev A name is optional (zero), public, and can never be changed. It is up to
    ///      31 ASCII characters, zero-padded on the right (so the last byte is always
    ///      zero, the usual bytes32-string convention): letters, digits, space and
    ///      - _ . ' only, with no space at either end. Names are not unique; a token
    ///      is identified by its id and creator, never by its name.
    function _validName(bytes32 n) internal pure returns (bool) {
        if (n == bytes32(0)) return true;
        if (n[31] != 0) return false;
        uint256 len = 31;
        while (n[len - 1] == 0) len--;
        if (n[0] == 0x20 || n[len - 1] == 0x20) return false;
        for (uint256 i = 0; i < len; i++) {
            bytes1 c = n[i];
            bool ok = (c >= 0x30 && c <= 0x39) // 0-9
                || (c >= 0x41 && c <= 0x5A) // A-Z
                || (c >= 0x61 && c <= 0x7A) // a-z
                || c == 0x20 || c == 0x2D || c == 0x5F || c == 0x2E || c == 0x27; // space - _ . '
            if (!ok) return false;
        }
        return true;
    }

    /// @return the token's name as zero-padded ASCII, or zero when it has none.
    function nameOf(uint256 tokenId) external view returns (bytes32) {
        _requireMinted(tokenId);
        return _endowments[tokenId].name;
    }

    function scheduleOf(uint256 tokenId) external view returns (Segment[] memory) {
        _requireMinted(tokenId);
        return _endowments[tokenId].schedule;
    }

    function scheduleStartOf(uint256 tokenId) external view returns (uint64) {
        _requireMinted(tokenId);
        return _endowments[tokenId].scheduleStart;
    }

    /// @return type(uint64).max when the schedule has no end.
    function scheduleEndOf(uint256 tokenId) external view returns (uint64) {
        _requireMinted(tokenId);
        Endowment storage e = _endowments[tokenId];
        return Schedule.scheduleEnd(e.schedule, e.scheduleStart);
    }

    function lastAccrualAtOf(uint256 tokenId) external view returns (uint64) {
        _requireMinted(tokenId);
        return _endowments[tokenId].lastAccrualAt;
    }

    /// @return true once the schedule has ended and the whole endowment was released.
    function settledOf(uint256 tokenId) external view returns (bool) {
        _requireMinted(tokenId);
        return _endowments[tokenId].settled;
    }

    function _requireMinted(uint256 tokenId) internal view {
        if (_ownerOf(tokenId) == address(0)) revert NonexistentToken();
    }

    function distributionHandle(uint256 tokenId) external view returns (euint64) {
        return _endowments[tokenId].distribution;
    }

    /// @notice Exposed for transparency/tests. The returned handle is NOT decryptable
    ///         by anyone except the contract — no ACL grant is ever made to owners.
    function endowmentHandle(uint256 tokenId) external view returns (euint64) {
        return _endowments[tokenId].endowmentRemaining;
    }

    function topUpsAllowedOf(uint256 tokenId) external view returns (bool) {
        return _endowments[tokenId].topUpsAllowed;
    }

    function accrue(uint256 tokenId) external {
        if (_ownerOf(tokenId) == address(0)) revert NonexistentToken();
        _accrue(tokenId);
    }

    function claim(uint256 tokenId) external nonReentrant {
        if (msg.sender != ownerOf(tokenId)) revert NotOwner();
        // checks-effects-interactions: the distribution is zeroed before the external transfer
        euint64 amt = _takeDistribution(tokenId, msg.sender);

        FHE.allowTransient(amt, address(token));
        token.confidentialTransfer(msg.sender, amt);
    }

    function topUp(uint256 tokenId, externalEuint64 encAmount, bytes calldata inputProof) external nonReentrant {
        Endowment storage e = _endowments[tokenId];
        if (_ownerOf(tokenId) == address(0)) revert NonexistentToken();
        if (!e.topUpsAllowed) revert TopUpsDisabled();
        // Funds added after the end could never be scheduled, so refuse them.
        if (block.timestamp >= Schedule.scheduleEnd(e.schedule, e.scheduleStart)) revert ScheduleEnded();

        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        FHE.allowTransient(amount, address(token));
        euint64 received = token.confidentialTransferFrom(msg.sender, address(this), amount);

        e.endowmentRemaining = FHE.add(e.endowmentRemaining, received);
        FHE.allowThis(e.endowmentRemaining); // never granted to any owner
    }

    /// @dev Accrues, then takes the whole distribution and leaves a zero in its place,
    ///      readable by the contract and by `reader`. Returns the amount taken; the
    ///      caller decides where it goes.
    function _takeDistribution(uint256 tokenId, address reader) internal returns (euint64 amt) {
        _accrue(tokenId);

        Endowment storage e = _endowments[tokenId];
        amt = e.distribution;

        e.distribution = FHE.asEuint64(0);
        FHE.allowThis(e.distribution);
        FHE.allow(e.distribution, reader);
    }

    function _update(address to, uint256 tokenId, address auth)
        internal
        virtual
        override
        returns (address from)
    {
        from = super._update(to, tokenId, auth);

        // Only on real transfers (skip mint from==0 and burn to==0).
        if (from != address(0) && to != address(0)) {
            _accrue(tokenId); // settle the clock before the handoff
            Endowment storage e = _endowments[tokenId];
            // Refresh the distribution handle so the prior owner's ACL no longer applies,
            // then grant read access to the new owner only. (Covers the no-op accrue case too.)
            e.distribution = FHE.add(e.distribution, FHE.asEuint64(0));
            FHE.allowThis(e.distribution);
            FHE.allow(e.distribution, to);
        }
    }

    function _accrue(uint256 tokenId) internal {
        Endowment storage e = _endowments[tokenId];
        if (e.settled) return;
        uint64 nowTs = uint64(block.timestamp);
        uint64 end = Schedule.scheduleEnd(e.schedule, e.scheduleStart);

        if (nowTs >= end) {
            // Fixed-end schedule is over: release everything that is left to the owner.
            // An indefinite schedule's end is type(uint64).max, so it never gets here.
            e.distribution = FHE.add(e.distribution, e.endowmentRemaining);
            // A computed zero, not FHE.asEuint64(0): trivial encryptions are deterministic and
            // claim stores the same handle as the owner-allowed distribution.
            e.endowmentRemaining = FHE.sub(e.endowmentRemaining, e.endowmentRemaining);
            e.settled = true;
            e.lastAccrualAt = end;
            FHE.allowThis(e.endowmentRemaining); // never granted to any owner
            FHE.allowThis(e.distribution);
            FHE.allow(e.distribution, ownerOf(tokenId));
            return;
        }

        uint64 owed = Schedule.integrate(e.schedule, e.scheduleStart, e.lastAccrualAt, nowTs);
        if (owed == 0) return;

        euint64 actual = FHE.min(FHE.asEuint64(owed), e.endowmentRemaining);
        e.endowmentRemaining = FHE.sub(e.endowmentRemaining, actual);
        e.distribution = FHE.add(e.distribution, actual);

        FHE.allowThis(e.endowmentRemaining);
        FHE.allowThis(e.distribution);
        FHE.allow(e.distribution, ownerOf(tokenId));

        e.lastAccrualAt = nowTs;
    }
}
