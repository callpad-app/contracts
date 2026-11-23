// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Script} from "forge-std/Script.sol";
import {Hook} from "../src/Hook.sol";
import {Launchpad} from "../src/Launchpad.sol";

contract Deploy is Script {
    IPoolManager internal constant ROBINHOOD_POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address internal constant ROBINHOOD_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    uint160 internal constant HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    function run() external returns (Launchpad launchpad, Hook hook) {
        address proofSigner = vm.envAddress("PROOF_SIGNER");
        address treasury = vm.envAddress("TREASURY");

        vm.startBroadcast();

        (, address deployer,) = vm.readCallers();
        launchpad = Launchpad(vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1));
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_FACTORY, HOOK_FLAGS, type(Hook).creationCode, abi.encode(ROBINHOOD_POOL_MANAGER, launchpad)
        );
        address implementation = address(new Launchpad(ROBINHOOD_USDG, ROBINHOOD_POOL_MANAGER, Hook(hookAddress)));
        address proxy =
            address(new ERC1967Proxy(implementation, abi.encodeCall(Launchpad.initialize, (proofSigner, treasury))));
        hook = new Hook{salt: salt}(ROBINHOOD_POOL_MANAGER, launchpad);

        vm.stopBroadcast();

        require(proxy == address(launchpad) && address(hook) == hookAddress, "Deployed addresses differ from predicted");
    }
}
