// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC7984} from "@openzeppelin/confidential-contracts/token/ERC7984/ERC7984.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol"; // CONFIG_BASE (Task 1)
import {FHE, euint64} from "@fhevm/solidity/lib/FHE.sol";

/// @dev TEST/DEV ONLY — permissionless mint. NEVER deploy to a production host chain; use a real confidential token (set TOKEN_ADDRESS) instead.
contract MockConfidentialToken is ERC7984, ZamaEthereumConfig {
    constructor() ERC7984("Mock Confidential", "MOCK", "") {
        require(
            block.chainid != 1 && block.chainid != 56 && block.chainid != 999,
            "MockConfidentialToken: test/dev only"
        );
    }

    /// @dev Test/dev mint of a cleartext amount into an encrypted balance.
    function mint(address to, uint64 amount) external {
        euint64 a = FHE.asEuint64(amount);
        FHE.allowThis(a);
        _mint(to, a);
    }
}
