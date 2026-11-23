// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface ILaunchpad {
    struct Auction {
        string name;
        string symbol;
        bytes32 salt;
        address highestBidder;
        uint256 highestBid;
        uint256 endTime;
        uint256 extension;
        uint256 minBidIncrementBps;
        uint256 airdropBps;
        int24 startTick;
    }

    struct Handle {
        Auction auction;
        address token;
        address launcher;
        uint256 totalPrebuy;
        uint256 prebuyTokens;
        uint256 airdropTokens;
        uint256 calledAt;
        mapping(address buyer => uint256 amount) prebuys;
        mapping(bytes32 userId => uint256 amount) airdropClaims;
    }

    event ProofSignerUpdated(address proofSigner);
    event TreasuryUpdated(address treasury);
    event AuctionSettingsUpdated(uint256 auctionDuration, uint256 auctionExtension, uint256 auctionMinBidIncrementBps);
    event LaunchSettingsUpdated(uint256 airdropBps, int24 startTick);
    event AuctionStarted(bytes32 indexed handleId, address indexed token, string name, string symbol);
    event BidPlaced(bytes32 indexed handleId, address indexed bidder, uint256 amount, uint256 endTime);
    event AuctionCancelled(bytes32 indexed handleId, address indexed bidder, uint256 refund);
    event Prebought(bytes32 indexed handleId, address indexed buyer, uint256 amount);
    event PrebuyClaimed(bytes32 indexed handleId, address indexed buyer, uint256 tokens);
    event AirdropClaimed(bytes32 indexed handleId, bytes32 indexed userId, address indexed account, uint256 tokens);
    event CallConfirmed(bytes32 indexed handleId);
    event Launched(
        bytes32 indexed handleId,
        address indexed token,
        address indexed launcher,
        string name,
        string symbol,
        uint256 airdropTokens,
        int24 startTick
    );

    error AirdropCapExceeded();
    error AlreadyCalled();
    error AlreadyLaunched();
    error AuctionAlreadyExists();
    error AuctionNotActive();
    error AuctionNotEnded();
    error BidTooLow(uint256 minBid);
    error InvalidSalt();
    error NotCalled();
    error NotLaunched();
    error NothingToClaim();
}
