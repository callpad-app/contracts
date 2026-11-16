// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

library Auction {
    struct State {
        string name;
        string symbol;
        address highestBidder;
        uint256 highestBid;
        uint256 endTime;
    }

    uint256 internal constant BPS = 10_000;

    event AuctionStarted(bytes32 indexed auctionId, string name, string symbol);
    event BidPlaced(bytes32 indexed auctionId, address indexed bidder, uint256 amount, uint256 endTime);

    error BidTooLow(uint256 minBid);
    error AuctionAlreadyExists();
    error AuctionNotActive();

    function start(
        mapping(bytes32 auctionId => State) storage auctions,
        string calldata name,
        string calldata symbol,
        uint256 duration
    ) internal returns (bytes32 auctionId) {
        auctionId = keccak256(bytes(symbol));
        State storage auction = auctions[auctionId];
        require(auction.endTime == 0, AuctionAlreadyExists());

        auction.name = name;
        auction.symbol = symbol;
        auction.endTime = block.timestamp + duration;

        emit AuctionStarted(auctionId, name, symbol);
    }

    function bid(
        mapping(bytes32 auctionId => State) storage auctions,
        address usd,
        bytes32 auctionId,
        uint256 amount,
        uint256 extension,
        uint256 minBidIncrementBps
    ) internal {
        State storage auction = auctions[auctionId];
        uint256 endTime = auction.endTime;
        require(block.timestamp < endTime, AuctionNotActive());

        address previousBidder = auction.highestBidder;
        uint256 previousBid = auction.highestBid;
        uint256 minBid = previousBid + (previousBid * minBidIncrementBps) / BPS;
        require(amount >= minBid, BidTooLow(minBid));

        if (endTime - block.timestamp <= extension) {
            endTime += extension;
            auction.endTime = endTime;
        }
        auction.highestBidder = msg.sender;
        auction.highestBid = amount;

        emit BidPlaced(auctionId, msg.sender, amount, endTime);

        SafeTransferLib.safeTransferFrom(usd, msg.sender, address(this), amount);
        if (previousBid != 0) SafeTransferLib.safeTransfer(usd, previousBidder, previousBid);
    }
}
