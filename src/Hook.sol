// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {BaseHook} from "uniswap-hooks/base/BaseHook.sol";
import {IHookEvents} from "uniswap-hooks/interfaces/IHookEvents.sol";
import {Launchpad} from "./Launchpad.sol";

contract Hook is BaseHook, IHookEvents {
    struct Recipients {
        address creator;
        address account;
    }

    uint256 public constant FEE_BPS = 100;
    uint256 public constant TREASURY_SHARE_BPS = 3000;
    uint256 public constant CREATOR_SHARE_BPS = 3500;
    uint256 internal constant BPS = 10_000;

    Launchpad public immutable launchpad;
    uint256 public treasuryFees;
    mapping(address token => Recipients) public recipients;
    mapping(address token => uint256) public escrowedFees;
    mapping(address recipient => uint256) public fees;

    event AccountSet(address indexed token, address indexed account);
    event FeesTaken(address indexed recipient, uint256 amount);

    error AccountAlreadySet();
    error NotLaunchpad();
    error NothingToTake();

    modifier onlyLaunchpad() {
        require(msg.sender == address(launchpad), NotLaunchpad());
        _;
    }

    constructor(IPoolManager poolManager_, Launchpad launchpad_) BaseHook(poolManager_) {
        launchpad = launchpad_;
    }

    function register(address token, address creator, address account, uint256 bid) external onlyLaunchpad {
        recipients[token] = Recipients(creator, account);
        uint256 treasuryAmount = bid * TREASURY_SHARE_BPS / BPS;
        treasuryFees += treasuryAmount;
        _creditAccount(token, account, bid - treasuryAmount);
    }

    function setAccount(address token, address account) external onlyLaunchpad {
        require(recipients[token].account == address(0), AccountAlreadySet());
        recipients[token].account = account;
        fees[account] += escrowedFees[token];
        delete escrowedFees[token];
        emit AccountSet(token, account);
    }

    function takeFees() external returns (uint256 amount) {
        amount = fees[msg.sender];
        delete fees[msg.sender];
        if (msg.sender == launchpad.treasury()) (amount, treasuryFees) = (amount + treasuryFees, 0);
        require(amount != 0, NothingToTake());

        emit FeesTaken(msg.sender, amount);

        poolManager.unlock(abi.encode(msg.sender, amount));
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (address recipient, uint256 amount) = abi.decode(data, (address, uint256));
        Currency usd = Currency.wrap(launchpad.usd());
        poolManager.burn(address(this), usd.toId(), amount);
        poolManager.take(usd, recipient, amount);
        return "";
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.beforeInitialize = true;
        permissions.beforeSwap = true;
        permissions.afterSwap = true;
        permissions.beforeSwapReturnDelta = true;
        permissions.afterSwapReturnDelta = true;
    }

    function _beforeInitialize(address sender, PoolKey calldata, uint160) internal view override returns (bytes4) {
        require(sender == address(launchpad), NotLaunchpad());
        return this.beforeInitialize.selector;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        int128 fee;
        if (_isUsdSpecified(params)) fee = _takeUsdFee(sender, key, params.amountSpecified);
        return (this.beforeSwap.selector, toBeforeSwapDelta(fee, 0), 0);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128 fee) {
        if (!_isUsdSpecified(params)) fee = _takeUsdFee(sender, key, delta.amount0());
        return (this.afterSwap.selector, fee);
    }

    function _isUsdSpecified(SwapParams calldata params) internal pure returns (bool) {
        return params.zeroForOne == (params.amountSpecified < 0);
    }

    function _takeUsdFee(address sender, PoolKey calldata key, int256 usdAmount) internal returns (int128 fee) {
        uint256 amount = FixedPointMathLib.abs(usdAmount) * FEE_BPS / BPS;
        fee = SafeCast.toInt128(amount);
        poolManager.mint(address(this), key.currency0.toId(), amount);

        address token = Currency.unwrap(key.currency1);
        Recipients memory tokenRecipients = recipients[token];
        uint256 treasuryAmount = amount * TREASURY_SHARE_BPS / BPS;
        uint256 creatorAmount = amount * CREATOR_SHARE_BPS / BPS;
        uint256 accountAmount = amount - treasuryAmount - creatorAmount;
        treasuryFees += treasuryAmount;
        fees[tokenRecipients.creator] += creatorAmount;
        _creditAccount(token, tokenRecipients.account, accountAmount);

        emit HookFee(PoolId.unwrap(key.toId()), sender, uint128(fee), 0);
    }

    function _creditAccount(address token, address account, uint256 amount) internal {
        if (account == address(0)) escrowedFees[token] += amount;
        else fees[account] += amount;
    }
}
