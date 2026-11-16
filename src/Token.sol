// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "solady/tokens/ERC20.sol";

contract Token is ERC20 {
    string private _name;
    string private _symbol;

    constructor(string memory name_, string memory symbol_, uint256 supply) {
        _name = name_;
        _symbol = symbol_;
        _mint(msg.sender, supply);
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }
}
