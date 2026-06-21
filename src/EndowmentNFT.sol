// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {FHE, euint64, externalEuint64} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {IERC7984} from "@openzeppelin/confidential-contracts/interfaces/IERC7984.sol";
import {Schedule, Segment} from "./libraries/Schedule.sol";

contract EndowmentNFT is ERC721, ReentrancyGuard, ZamaEthereumConfig {
    using Schedule for Segment[];

    struct Endowment {
        euint64 endowmentRemaining; // SECRET: ACL = contract only
        euint64 distribution;       // owner-readable: ACL = contract + current owner
        uint64 lastAccrualAt;
        uint64 scheduleStart;
        bool topUpsAllowed;
        Segment[] schedule;
    }

    IERC7984 public immutable token;
    uint256 internal _nextId;
    mapping(uint256 => Endowment) internal _endowments;

    error EmptySchedule();
    error ZeroDurationSegment();
    error TopUpsDisabled();
    error NonexistentToken();
    error NotOwner();

    constructor(IERC7984 token_) ERC721("Endowment NFT", "ENDOW") {
        token = token_;
    }

    function mint(
        address to,
        externalEuint64 encEndowment,
        bytes calldata inputProof,
        Segment[] calldata segments,
        uint64 scheduleStart,
        bool topUpsAllowed
    ) external nonReentrant returns (uint256 tokenId) {
        if (segments.length == 0) revert EmptySchedule();

        uint64 start = scheduleStart == 0 ? uint64(block.timestamp) : scheduleStart;

        euint64 amount = FHE.fromExternal(encEndowment, inputProof);
        FHE.allowTransient(amount, address(token));
        euint64 received = token.confidentialTransferFrom(msg.sender, address(this), amount);

        tokenId = ++_nextId;
        Endowment storage e = _endowments[tokenId];
        e.endowmentRemaining = received;
        e.distribution = FHE.asEuint64(0);
        e.lastAccrualAt = start;
        e.scheduleStart = start;
        e.topUpsAllowed = topUpsAllowed;
        for (uint256 i = 0; i < segments.length; i++) {
            if (segments[i].duration == 0) revert ZeroDurationSegment();
            e.schedule.push(segments[i]);
        }

        FHE.allowThis(e.endowmentRemaining);
        FHE.allowThis(e.distribution);
        FHE.allow(e.distribution, to);

        _safeMint(to, tokenId);
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
        _accrue(tokenId);

        Endowment storage e = _endowments[tokenId];
        euint64 amt = e.distribution;

        // checks-effects-interactions: zero out before the external transfer
        e.distribution = FHE.asEuint64(0);
        FHE.allowThis(e.distribution);
        FHE.allow(e.distribution, msg.sender);

        FHE.allowTransient(amt, address(token));
        token.confidentialTransfer(msg.sender, amt);
    }

    function _update(address to, uint256 tokenId, address auth)
        internal
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
        uint64 nowTs = uint64(block.timestamp);
        uint64 owed = Schedule.integrate(e.schedule, e.scheduleStart, e.lastAccrualAt, nowTs);
        if (owed == 0) return;

        euint64 actual = FHE.min(FHE.asEuint64(owed), e.endowmentRemaining);
        e.endowmentRemaining = FHE.sub(e.endowmentRemaining, actual);
        e.distribution = FHE.add(e.distribution, actual);

        FHE.allowThis(e.endowmentRemaining);
        FHE.allowThis(e.distribution);
        FHE.allow(e.distribution, ownerOf(tokenId));

        uint64 end = Schedule.scheduleEnd(e.schedule, e.scheduleStart);
        e.lastAccrualAt = nowTs < end ? nowTs : end;
    }
}
