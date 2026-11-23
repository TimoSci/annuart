// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {FHE, euint64, externalEuint64} from "@fhevm/solidity/lib/FHE.sol";

/// @dev TEST ONLY. Checks, on a live network, the access rule the contracts rely on: an
///      FHE operation succeeds when this contract holds access to every operand, and
///      fails when it does not. Used with throwaway values only (see the Sepolia checks
///      in docs/security).
contract AclProbe is ZamaEthereumConfig {
    event Result(bytes32 handle, bool callerAllowed);

    /// @notice Adds two fresh inputs of the caller's and grants the caller the sum.
    function addOwn(externalEuint64 a, externalEuint64 b, bytes calldata proof) external {
        euint64 r = FHE.add(FHE.fromExternal(a, proof), FHE.fromExternal(b, proof));
        FHE.allowThis(r);
        FHE.allow(r, msg.sender);
        emit Result(euint64.unwrap(r), FHE.isAllowed(r, msg.sender));
    }

    /// @notice Adds a fresh input to a value this contract was never granted. Must revert.
    function addForeign(externalEuint64 a, bytes calldata proof, euint64 foreign) external {
        euint64 r = FHE.add(FHE.fromExternal(a, proof), foreign);
        FHE.allowThis(r);
        FHE.allow(r, msg.sender);
        emit Result(euint64.unwrap(r), FHE.isAllowed(r, msg.sender));
    }
}
