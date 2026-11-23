// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {Launchpad} from "../src/Launchpad.sol";

contract Upgrade is Script {
    function run() external returns (address implementation) {
        Launchpad launchpad = Launchpad(vm.envAddress("LAUNCHPAD"));

        vm.startBroadcast();

        implementation = address(new Launchpad(launchpad.usd(), launchpad.poolManager(), launchpad.hook()));
        launchpad.upgradeToAndCall(implementation, "");

        vm.stopBroadcast();
    }
}
