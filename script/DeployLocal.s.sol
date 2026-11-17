// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Script} from "forge-std/Script.sol";
import {Hook} from "../src/Hook.sol";
import {Launchpad} from "../src/Launchpad.sol";

contract DeployLocal is Script {
    uint160 internal constant HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    function run() external {
        vm.startBroadcast();

        IPoolManager manager = IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(msg.sender)));
        ERC20Mock usd = new ERC20Mock();
        usd.mint(msg.sender, 1_000_000e18);

        address launchpad = vm.computeCreateAddress(msg.sender, vm.getNonce(msg.sender));
        (address hook, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, HOOK_FLAGS, type(Hook).creationCode, abi.encode(manager, launchpad));
        new Launchpad(msg.sender, msg.sender, address(usd), manager, Hook(hook));
        new Hook{salt: salt}(manager, Launchpad(launchpad));

        vm.stopBroadcast();
    }
}
