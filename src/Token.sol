// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "solady/tokens/ERC20.sol";
import {Initializable} from "solady/utils/Initializable.sol";

contract Token is ERC20, Initializable {
    string private _name;
    string private _symbol;

    constructor() {
        _disableInitializers();
    }

    function initialize(string calldata name_, string calldata symbol_, uint256 supply) external initializer {
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
