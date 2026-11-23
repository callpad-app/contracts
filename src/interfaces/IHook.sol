// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

interface IHook is IHooks {
    struct Recipients {
        address creator;
        address account;
    }

    event AccountSet(address indexed token, address indexed account);
    event FeesTaken(address indexed recipient, uint256 amount);
    event Swapped(address indexed token, int256 usdAmount, int256 tokenAmount, uint256 fee, uint160 sqrtPriceX96);

    error AccountAlreadySet();
    error NotLaunchpad();
    error NothingToTake();
}
