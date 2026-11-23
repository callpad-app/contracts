// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SafeCallback} from "v4-periphery/src/base/SafeCallback.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Hook} from "./Hook.sol";
import {ILaunchpad} from "./interfaces/ILaunchpad.sol";
import {Proofs} from "./Proofs.sol";
import {Token} from "./Token.sol";

contract Launchpad is ILaunchpad, EIP712Upgradeable, OwnableUpgradeable, UUPSUpgradeable, SafeCallback {
    using SafeERC20 for IERC20;

    uint256 public constant TOKEN_SUPPLY = 1_000_000_000e18;
    uint256 public constant AIRDROP_CAP = 1_000_000e18;
    uint256 public constant AIRDROP_UNLOCK_PERIOD = 7 days;
    int24 public constant TICK_SPACING = 200;
    uint256 internal constant BPS = 10_000;

    address public immutable usd;
    Hook public immutable hook;
    address public tokenImplementation;
    address public proofSigner;
    address public treasury;
    uint256 public auctionDuration;
    uint256 public auctionExtension;
    uint256 public auctionMinBidIncrementBps;
    uint256 public airdropBps;
    int24 public startTick;
    mapping(bytes32 handleId => Handle) public handles;

    constructor(address usd_, IPoolManager poolManager_, Hook hook_) SafeCallback(poolManager_) {
        usd = usd_;
        hook = hook_;
        _disableInitializers();
    }

    function initialize(address proofSigner_, address treasury_) external initializer {
        __EIP712_init("Callpad", "1");
        __Ownable_init(msg.sender);
        tokenImplementation = address(new Token());
        proofSigner = proofSigner_;
        treasury = treasury_;
        auctionDuration = 24 hours;
        auctionExtension = 5 minutes;
        auctionMinBidIncrementBps = 1000;
        airdropBps = 100;
        startTick = 391_400;
    }

    function setProofSigner(address proofSigner_) external onlyOwner {
        proofSigner = proofSigner_;
        emit ProofSignerUpdated(proofSigner_);
    }

    function setTreasury(address treasury_) external onlyOwner {
        treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }

    function setAuctionSettings(uint256 auctionDuration_, uint256 auctionExtension_, uint256 auctionMinBidIncrementBps_)
        external
        onlyOwner
    {
        auctionDuration = auctionDuration_;
        auctionExtension = auctionExtension_;
        auctionMinBidIncrementBps = auctionMinBidIncrementBps_;
        emit AuctionSettingsUpdated(auctionDuration_, auctionExtension_, auctionMinBidIncrementBps_);
    }

    function setLaunchSettings(uint256 airdropBps_, int24 startTick_) external onlyOwner {
        airdropBps = airdropBps_;
        startTick = startTick_;
        emit LaunchSettingsUpdated(airdropBps_, startTick_);
    }

    function startAuction(
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        uint256 minBid,
        uint256 amount,
        uint256 buyAmount,
        uint256 proofDeadline,
        bytes calldata proof
    ) external returns (bytes32 handleId) {
        _verifyProof(Proofs.startAuctionHash(name, symbol, minBid, proofDeadline), proofDeadline, proof);
        require(amount >= minBid, BidTooLow(minBid));

        handleId = handleIdOf(symbol);
        require(handles[handleId].token == address(0), AlreadyLaunched());

        _startAuction(handleId, name, symbol, salt);
        _bidAuction(handleId, amount, buyAmount);
    }

    function bid(bytes32 handleId, uint256 amount, uint256 buyAmount) external {
        _bidAuction(handleId, amount, buyAmount);
    }

    function launch(bytes32 handleId) external returns (address token) {
        Handle storage handle = handles[handleId];
        Auction storage auction = handle.auction;
        uint256 endTime = auction.endTime;
        require(endTime != 0 && block.timestamp >= endTime, AuctionNotEnded());

        token = _launch(
            handle,
            handleId,
            auction.name,
            auction.symbol,
            auction.salt,
            auction.highestBidder,
            address(0),
            auction.buyAmount,
            auction.startTick
        );
    }

    function launchOwn(
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        uint256 proofDeadline,
        uint256 buyAmount,
        bytes calldata proof
    ) external returns (address token) {
        _verifyProof(Proofs.launchOwnHash(name, symbol, msg.sender, proofDeadline), proofDeadline, proof);

        bytes32 handleId = handleIdOf(symbol);
        Handle storage handle = handles[handleId];
        int24 tick = startTick;
        if (handle.auction.endTime != 0) {
            salt = handle.auction.salt;
            tick = handle.auction.startTick;
            _cancelAuction(handleId);
        }

        IERC20(usd).safeTransferFrom(msg.sender, address(this), buyAmount);
        token = _launch(handle, handleId, name, symbol, salt, msg.sender, msg.sender, buyAmount, tick);
    }

    function confirmCall(bytes32 handleId, uint256 proofDeadline, bytes calldata proof) external {
        _verifyProof(Proofs.confirmCallHash(handleId, proofDeadline), proofDeadline, proof);

        Handle storage handle = handles[handleId];
        require(handle.token != address(0), NotLaunched());
        require(handle.calledAt == 0, AlreadyCalled());

        handle.calledAt = block.timestamp;

        emit CallConfirmed(handleId);
    }

    function setAccount(bytes32 handleId, uint256 proofDeadline, bytes calldata proof) external {
        _verifyProof(Proofs.setAccountHash(handleId, msg.sender, proofDeadline), proofDeadline, proof);

        Handle storage handle = handles[handleId];
        require(handle.calledAt != 0, NotCalled());

        hook.setAccount(handle.token, msg.sender);
    }

    function claimAirdrop(bytes32 handleId, bytes32 userId, uint256 amount, uint256 proofDeadline, bytes calldata proof)
        external
        returns (uint256 tokens)
    {
        _verifyProof(Proofs.claimAirdropHash(handleId, userId, msg.sender, amount, proofDeadline), proofDeadline, proof);

        require(amount <= AIRDROP_CAP, AirdropCapExceeded());

        Handle storage handle = handles[handleId];
        uint256 calledAt = handle.calledAt;
        require(calledAt != 0, NotCalled());

        uint256 unlocked = amount * Math.min(block.timestamp - calledAt, AIRDROP_UNLOCK_PERIOD) / AIRDROP_UNLOCK_PERIOD;
        uint256 claimed = handle.airdropClaims[userId];
        require(unlocked > claimed, NothingToClaim());

        tokens = unlocked - claimed;
        handle.airdropClaims[userId] = unlocked;
        handle.airdropTokens -= tokens;

        emit AirdropClaimed(handleId, userId, msg.sender, tokens);

        IERC20(handle.token).safeTransfer(msg.sender, tokens);
    }

    function airdropClaimOf(bytes32 handleId, bytes32 userId) external view returns (uint256) {
        return handles[handleId].airdropClaims[userId];
    }

    function handleIdOf(string memory symbol) public pure returns (bytes32) {
        bytes memory handle = bytes(symbol);
        for (uint256 i; i < handle.length; ++i) {
            if (handle[i] >= "A" && handle[i] <= "Z") handle[i] = bytes1(uint8(handle[i]) + 32);
        }
        return keccak256(handle);
    }

    function predictToken(bytes32 handleId, bytes32 salt) public view returns (address token) {
        token = Clones.predictDeterministicAddress(tokenImplementation, keccak256(abi.encode(handleId, salt)));
        require(token > usd, InvalidSalt());
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function _verifyProof(bytes32 structHash, uint256 proofDeadline, bytes calldata proof) internal view {
        Proofs.verify(proofSigner, _hashTypedDataV4(structHash), proofDeadline, proof);
    }

    function _startAuction(bytes32 handleId, string calldata name, string calldata symbol, bytes32 salt) internal {
        Auction storage auction = handles[handleId].auction;
        require(auction.endTime == 0, AuctionAlreadyExists());

        auction.name = name;
        auction.symbol = symbol;
        auction.salt = salt;
        auction.endTime = block.timestamp + auctionDuration;
        auction.extension = auctionExtension;
        auction.minBidIncrementBps = auctionMinBidIncrementBps;
        auction.airdropBps = airdropBps;
        auction.startTick = startTick;

        emit AuctionStarted(handleId, predictToken(handleId, salt), name, symbol);
    }

    function _bidAuction(bytes32 handleId, uint256 amount, uint256 buyAmount) internal {
        Auction storage auction = handles[handleId].auction;
        uint256 endTime = auction.endTime;
        require(block.timestamp < endTime, AuctionNotActive());

        address previousBidder = auction.highestBidder;
        uint256 previousBid = auction.highestBid;
        uint256 previousBuyAmount = auction.buyAmount;
        uint256 minBid = previousBid + (previousBid * auction.minBidIncrementBps) / BPS;
        require(amount >= minBid, BidTooLow(minBid));

        uint256 extension = auction.extension;
        if (endTime - block.timestamp <= extension) {
            endTime += extension;
            auction.endTime = endTime;
        }
        auction.highestBidder = msg.sender;
        auction.highestBid = amount;
        auction.buyAmount = buyAmount;

        emit BidPlaced(handleId, msg.sender, amount, buyAmount, endTime);

        IERC20(usd).safeTransferFrom(msg.sender, address(this), amount + buyAmount);
        if (previousBid != 0) IERC20(usd).safeTransfer(previousBidder, previousBid + previousBuyAmount);
    }

    function _cancelAuction(bytes32 handleId) internal {
        Auction storage auction = handles[handleId].auction;
        address bidder = auction.highestBidder;
        uint256 refund = auction.highestBid + auction.buyAmount;
        delete handles[handleId].auction;

        emit AuctionCancelled(handleId, bidder, refund);

        IERC20(usd).safeTransfer(bidder, refund);
    }

    function _launch(
        Handle storage handle,
        bytes32 handleId,
        string memory name,
        string memory symbol,
        bytes32 salt,
        address launcher,
        address account,
        uint256 buyAmount,
        int24 tick
    ) internal returns (address token) {
        require(handle.token == address(0), AlreadyLaunched());

        token = predictToken(handleId, salt);
        Clones.cloneDeterministic(tokenImplementation, keccak256(abi.encode(handleId, salt)));
        Token(token).initialize(name, symbol, TOKEN_SUPPLY);
        uint256 bid = handle.auction.highestBid;
        hook.register(token, launcher, account, bid);

        uint256 airdropTokens;
        if (account == address(0)) airdropTokens = TOKEN_SUPPLY * handle.auction.airdropBps / BPS;
        else handle.calledAt = block.timestamp;
        handle.token = token;
        handle.launcher = launcher;
        handle.airdropTokens = airdropTokens;

        emit Launched(handleId, token, launcher, name, symbol, airdropTokens, buyAmount, tick);

        uint256 boughtTokens = _provideLiquidity(token, tick, TOKEN_SUPPLY - airdropTokens, buyAmount, bid);
        if (boughtTokens != 0) IERC20(token).safeTransfer(launcher, boughtTokens);
    }

    function _provideLiquidity(address token, int24 tick, uint256 liquidityTokens, uint256 prebuyUsd, uint256 bid)
        internal
        returns (uint256 prebuyTokens)
    {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(usd),
            currency1: Currency.wrap(token),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: hook
        });
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(tick));

        return abi.decode(poolManager.unlock(abi.encode(key, tick, liquidityTokens, prebuyUsd, bid)), (uint256));
    }

    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        (PoolKey memory key, int24 tick, uint256 liquidityTokens, uint256 prebuyUsd, uint256 owedUsd) =
            abi.decode(data, (PoolKey, int24, uint256, uint256, uint256));
        if (owedUsd != 0) poolManager.mint(address(hook), key.currency0.toId(), owedUsd);

        int24 tickLower = TickMath.minUsableTick(TICK_SPACING);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tick), liquidityTokens
        );
        (BalanceDelta liquidityDelta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tick, liquidityDelta: int256(uint256(liquidity)), salt: 0
            }),
            ""
        );
        uint256 owedTokens = uint128(-liquidityDelta.amount1());

        uint256 prebuyTokens;
        if (prebuyUsd != 0) {
            BalanceDelta swapDelta = poolManager.swap(
                key,
                SwapParams({
                    zeroForOne: true,
                    amountSpecified: -int256(prebuyUsd),
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                ""
            );
            owedUsd += uint128(-swapDelta.amount0());
            prebuyTokens = uint128(swapDelta.amount1());
        }
        if (owedUsd != 0) _settle(key.currency0, owedUsd);
        _settle(key.currency1, owedTokens - prebuyTokens);

        return abi.encode(prebuyTokens);
    }

    function _settle(Currency currency, uint256 amount) internal {
        poolManager.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), amount);
        poolManager.settle();
    }
}
