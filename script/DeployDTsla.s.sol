// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Script} from "forge-std/Script.sol";
import {dTSLA} from "../src/dTSLA.sol";
import {console2} from "forge-std/console2.sol";

contract DeployDTesla is Script {
    string constant alpacaMintSource = "./functions/sources/alpacaBalance.js";
    string constant alpacaRedeemSource = "";
    uint64 subId = 0;

    function run() public {
        string memory mintSource = vm.readFile(alpacaMintSource);

        vm.startBroadcast();
        dTSLA dTsla = new dTSLA(mintSource, alpacaRedeemSource, subId);
        vm.stopBroadcast();
    }
}
