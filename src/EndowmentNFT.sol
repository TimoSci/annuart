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
}
