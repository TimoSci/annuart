// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev TEST/DEV ONLY - stand-in for WETH on chains without one. NEVER deploy to a production host chain.
contract MockWETH is ERC20("Wrapped Ether", "WETH") {
    constructor() {
        require(block.chainid != 1 && block.chainid != 56 && block.chainid != 999, "MockWETH: test/dev only");
    }

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "MockWETH: ETH transfer failed");
    }
}
