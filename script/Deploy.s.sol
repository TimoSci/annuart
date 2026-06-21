// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {EndowmentNFT} from "../src/EndowmentNFT.sol";
import {MockConfidentialToken} from "../src/mocks/MockConfidentialToken.sol";
import {IERC7984} from "@openzeppelin/confidential-contracts/interfaces/IERC7984.sol";

contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address existingToken = vm.envOr("TOKEN_ADDRESS", address(0));

        vm.startBroadcast(pk);
        address tokenAddr = existingToken;
        if (tokenAddr == address(0)) {
            MockConfidentialToken token = new MockConfidentialToken();
            tokenAddr = address(token);
            console.log("MockConfidentialToken:", tokenAddr);
        }
        EndowmentNFT nft = new EndowmentNFT(IERC7984(tokenAddr));
        console.log("EndowmentNFT:", address(nft));
        vm.stopBroadcast();
    }
}
