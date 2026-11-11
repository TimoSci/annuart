// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC7984ERC20Wrapper, ERC7984} from "@openzeppelin/confidential-contracts/token/ERC7984/extensions/ERC7984ERC20Wrapper.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";

/// @notice Confidential wrapper over WETH. 9 decimals (rate 1e9), so a confidential
/// uint64 balance can hold roughly 18 billion ether.
contract ConfidentialWETH is ERC7984ERC20Wrapper, ZamaEthereumConfig {
    constructor(IERC20 weth) ERC7984("Confidential Wrapped Ether", "cWETH", "") ERC7984ERC20Wrapper(weth) {}

    function _maxDecimals() internal pure override returns (uint8) {
        return 9;
    }
}
