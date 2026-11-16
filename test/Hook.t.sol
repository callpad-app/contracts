// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BaseHook} from "uniswap-hooks/base/BaseHook.sol";
import {Hook} from "../src/Hook.sol";
import {LaunchFixture} from "./LaunchFixture.sol";

contract HookTest is LaunchFixture {
    function test_RevertWhen_PoolInitializedOutsideLaunchpad() public {
        key.tickSpacing = 60;

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(Hook.NotLaunchpad.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
    }

    function test_RevertWhen_RegisterCallerIsNotLaunchpad() public {
        vm.expectRevert(Hook.NotLaunchpad.selector);
        hook.register(token, address(this), address(this));
    }

    function test_RevertWhen_SetAccountCallerIsNotLaunchpad() public {
        vm.expectRevert(Hook.NotLaunchpad.selector);
        hook.setAccount(token, address(this));
    }

    function test_RevertWhen_UnlockCallbackCallerIsNotPoolManager() public {
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(address(this), PREBUY_FEE));
    }

    function test_PrebuyPaysFeeInUsd() public view {
        assertEq(_usdFees(), PREBUY_FEE);
        assertEq(_tokenFees(), 0);
    }

    function test_BuyExactUsdIn() public {
        (int256 usdDelta, int256 tokenDelta, uint256 fee) = _swap(true, -100e6);

        assertEq(usdDelta, -100e6);
        assertGt(tokenDelta, 0);
        assertEq(fee, 1e6);
    }

    function test_BuyExactTokensOut() public {
        (int256 usdDelta, int256 tokenDelta, uint256 fee) = _swap(true, 1_000_000e18);

        assertEq(tokenDelta, 1_000_000e18);
        assertGt(fee, 0);
        assertEq(fee, (uint256(-usdDelta) - fee) / 100);
    }

    function test_SellExactTokensIn() public {
        _swap(true, 1_000_000e18);
        (int256 usdDelta, int256 tokenDelta, uint256 fee) = _swap(false, -500_000e18);

        assertEq(tokenDelta, -500_000e18);
        assertGt(fee, 0);
        assertEq(fee, (uint256(usdDelta) + fee) / 100);
    }

    function test_SellExactUsdOut() public {
        _swap(true, -100e6);
        (int256 usdDelta, int256 tokenDelta, uint256 fee) = _swap(false, 50e6);

        assertEq(usdDelta, 50e6);
        assertLt(tokenDelta, 0);
        assertEq(fee, 0.5e6);
    }
}
