// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC7984} from "@openzeppelin/confidential-contracts/token/ERC7984/ERC7984.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol"; // CONFIG_BASE (Task 1)
import {FHE, euint64} from "@fhevm/solidity/lib/FHE.sol";

contract MockConfidentialToken is ERC7984, ZamaEthereumConfig {
    constructor() ERC7984("Mock Confidential", "MOCK", "") {}

    /// @dev Test/dev mint of a cleartext amount into an encrypted balance.
    function mint(address to, uint64 amount) external {
        euint64 a = FHE.asEuint64(amount);
        FHE.allowThis(a);
        _mint(to, a);
    }
}
