// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SafeCallback} from "v4-periphery/src/base/SafeCallback.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Hook} from "./Hook.sol";
import {Proofs} from "./Proofs.sol";
import {Token} from "./Token.sol";

struct Auction {
    string name;
    string symbol;
    bytes32 salt;
    address highestBidder;
    uint256 highestBid;
    uint256 endTime;
}

struct Handle {
    Auction auction;
    address token;
    address launcher;
    uint256 totalPrebuy;
    uint256 prebuyTokens;
    uint256 airdropTokens;
    mapping(address buyer => uint256 amount) prebuys;
    mapping(address account => uint256 amount) airdropClaims;
}

contract Launchpad is EIP712, Ownable, SafeCallback {
    using SafeERC20 for IERC20;

    uint256 public constant TOKEN_SUPPLY = 1_000_000_000e18;
    int24 public constant TICK_SPACING = 200;
    uint256 internal constant BPS = 10_000;

    address public immutable usd;
    Hook public immutable hook;
    address public immutable tokenImplementation = address(new Token());
    address public proofSigner;
    address public treasury;
    uint256 public auctionDuration = 24 hours;
    uint256 public auctionExtension = 5 minutes;
    uint256 public auctionMinBidIncrementBps = 1000;
    uint256 public airdropBps = 100;
    int24 public startTick = 391_400;
    mapping(bytes32 handleId => Handle) public handles;

    event ProofSignerUpdated(address proofSigner);
    event TreasuryUpdated(address treasury);
    event AuctionSettingsUpdated(uint256 auctionDuration, uint256 auctionExtension, uint256 auctionMinBidIncrementBps);
    event LaunchSettingsUpdated(uint256 airdropBps, int24 startTick);
    event AuctionStarted(bytes32 indexed handleId, address indexed token, string name, string symbol);
    event BidPlaced(bytes32 indexed handleId, address indexed bidder, uint256 amount, uint256 endTime);
    event AuctionCancelled(bytes32 indexed handleId, address indexed bidder, uint256 refund);
    event Prebought(bytes32 indexed handleId, address indexed buyer, uint256 amount);
    event PrebuyClaimed(bytes32 indexed handleId, address indexed buyer, uint256 tokens);
    event AirdropClaimed(bytes32 indexed handleId, address indexed account, uint256 tokens);
    event Launched(
        bytes32 indexed handleId, address indexed token, address indexed launcher, string name, string symbol
    );

    error AlreadyLaunched();
    error AuctionAlreadyExists();
    error AuctionNotActive();
    error AuctionNotEnded();
    error BidTooLow(uint256 minBid);
    error InvalidSalt();
    error NotLaunched();
    error NothingToClaim();

    constructor(address proofSigner_, address treasury_, address usd_, IPoolManager poolManager_, Hook hook_)
        EIP712("Callpad", "1")
        Ownable(msg.sender)
        SafeCallback(poolManager_)
    {
        proofSigner = proofSigner_;
        treasury = treasury_;
        usd = usd_;
        hook = hook_;
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
        uint256 proofDeadline,
        bytes calldata proof
    ) external returns (bytes32 handleId) {
        Proofs.verify(
            proofSigner,
            _hashTypedDataV4(Proofs.startAuctionHash(name, symbol, minBid, proofDeadline)),
            proofDeadline,
            proof
        );
        require(amount >= minBid, BidTooLow(minBid));

        handleId = keccak256(bytes(symbol));
        require(handles[handleId].token == address(0), AlreadyLaunched());

        _startAuction(handleId, name, symbol, salt);
        _bidAuction(handleId, amount);
    }

    function bid(bytes32 handleId, uint256 amount) external {
        _bidAuction(handleId, amount);
    }

    function prebuy(bytes32 handleId, uint256 amount) external {
        Handle storage handle = handles[handleId];
        require(block.timestamp < handle.auction.endTime, AuctionNotActive());

        handle.prebuys[msg.sender] += amount;
        handle.totalPrebuy += amount;

        emit Prebought(handleId, msg.sender, amount);

        IERC20(usd).safeTransferFrom(msg.sender, address(this), amount);
    }

    function launch(bytes32 handleId) external returns (address token) {
        Handle storage handle = handles[handleId];
        Auction storage auction = handle.auction;
        uint256 endTime = auction.endTime;
        require(endTime != 0 && block.timestamp >= endTime, AuctionNotEnded());

        token = _launch(handle, handleId, auction.name, auction.symbol, auction.salt, auction.highestBidder, address(0));
    }

    function launchOwn(
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        uint256 proofDeadline,
        bytes calldata proof
    ) external returns (address token) {
        Proofs.verify(
            proofSigner,
            _hashTypedDataV4(Proofs.launchOwnHash(name, symbol, msg.sender, proofDeadline)),
            proofDeadline,
            proof
        );

        bytes32 handleId = keccak256(bytes(symbol));
        Handle storage handle = handles[handleId];
        if (handle.auction.endTime != 0) {
            salt = handle.auction.salt;
            _cancelAuction(handleId);
        }

        token = _launch(handle, handleId, name, symbol, salt, msg.sender, msg.sender);
    }

    function setAccount(bytes32 handleId, uint256 proofDeadline, bytes calldata proof) external {
        Proofs.verify(
            proofSigner,
            _hashTypedDataV4(Proofs.setAccountHash(handleId, msg.sender, proofDeadline)),
            proofDeadline,
            proof
        );

        address token = handles[handleId].token;
        require(token != address(0), NotLaunched());

        hook.setAccount(token, msg.sender);
    }

    function claimPrebuy(bytes32 handleId) external returns (uint256 tokens) {
        Handle storage handle = handles[handleId];
        address token = handle.token;
        require(token != address(0), NotLaunched());
        uint256 amount = handle.prebuys[msg.sender];
        require(amount != 0, NothingToClaim());

        delete handle.prebuys[msg.sender];
        tokens = amount * handle.prebuyTokens / handle.totalPrebuy;

        emit PrebuyClaimed(handleId, msg.sender, tokens);

        IERC20(token).safeTransfer(msg.sender, tokens);
    }

    function claimAirdrop(bytes32 handleId, uint256 amount, uint256 proofDeadline, bytes calldata proof)
        external
        returns (uint256 tokens)
    {
        Proofs.verify(
            proofSigner,
            _hashTypedDataV4(Proofs.claimAirdropHash(handleId, msg.sender, amount, proofDeadline)),
            proofDeadline,
            proof
        );

        Handle storage handle = handles[handleId];
        uint256 claimed = handle.airdropClaims[msg.sender];
        require(amount > claimed, NothingToClaim());

        tokens = amount - claimed;
        handle.airdropClaims[msg.sender] = amount;
        handle.airdropTokens -= tokens;

        emit AirdropClaimed(handleId, msg.sender, tokens);

        IERC20(handle.token).safeTransfer(msg.sender, tokens);
    }

    function prebuyOf(bytes32 handleId, address buyer) external view returns (uint256) {
        return handles[handleId].prebuys[buyer];
    }

    function airdropClaimOf(bytes32 handleId, address account) external view returns (uint256) {
        return handles[handleId].airdropClaims[account];
    }

    function predictToken(bytes32 handleId, bytes32 salt) public view returns (address token) {
        token = Clones.predictDeterministicAddress(tokenImplementation, keccak256(abi.encode(handleId, salt)));
        require(token > usd, InvalidSalt());
    }

    function _startAuction(bytes32 handleId, string calldata name, string calldata symbol, bytes32 salt) internal {
        Auction storage auction = handles[handleId].auction;
        require(auction.endTime == 0, AuctionAlreadyExists());

        auction.name = name;
        auction.symbol = symbol;
        auction.salt = salt;
        auction.endTime = block.timestamp + auctionDuration;

        emit AuctionStarted(handleId, predictToken(handleId, salt), name, symbol);
    }

    function _bidAuction(bytes32 handleId, uint256 amount) internal {
        Auction storage auction = handles[handleId].auction;
        uint256 endTime = auction.endTime;
        require(block.timestamp < endTime, AuctionNotActive());

        address previousBidder = auction.highestBidder;
        uint256 previousBid = auction.highestBid;
        uint256 minBid = previousBid + (previousBid * auctionMinBidIncrementBps) / BPS;
        require(amount >= minBid, BidTooLow(minBid));

        uint256 extension = auctionExtension;
        if (endTime - block.timestamp <= extension) {
            endTime += extension;
            auction.endTime = endTime;
        }
        auction.highestBidder = msg.sender;
        auction.highestBid = amount;

        emit BidPlaced(handleId, msg.sender, amount, endTime);

        IERC20(usd).safeTransferFrom(msg.sender, address(this), amount);
        if (previousBid != 0) IERC20(usd).safeTransfer(previousBidder, previousBid);
    }

    function _cancelAuction(bytes32 handleId) internal {
        Auction storage auction = handles[handleId].auction;
        address bidder = auction.highestBidder;
        uint256 refund = auction.highestBid;
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
        address account
    ) internal returns (address token) {
        require(handle.token == address(0), AlreadyLaunched());

        token = predictToken(handleId, salt);
        Clones.cloneDeterministic(tokenImplementation, keccak256(abi.encode(handleId, salt)));
        Token(token).initialize(name, symbol, TOKEN_SUPPLY);
        uint256 bid = handle.auction.highestBid;
        hook.register(token, launcher, account, bid);

        uint256 airdropTokens = TOKEN_SUPPLY * airdropBps / BPS;
        handle.token = token;
        handle.launcher = launcher;
        handle.airdropTokens = airdropTokens;
        handle.prebuyTokens = _provideLiquidity(token, TOKEN_SUPPLY - airdropTokens, handle.totalPrebuy, bid);

        emit Launched(handleId, token, launcher, name, symbol);
    }

    function _provideLiquidity(address token, uint256 liquidityTokens, uint256 prebuyUsd, uint256 bid)
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
        int24 tick = startTick;
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
