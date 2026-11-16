// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Ownable} from "solady/auth/Ownable.sol";
import {EIP712} from "solady/utils/EIP712.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Proofs} from "./Proofs.sol";
import {Token} from "./Token.sol";

struct Auction {
    string name;
    string symbol;
    address highestBidder;
    uint256 highestBid;
    uint256 endTime;
}

struct Handle {
    Auction auction;
    address token;
    address launcher;
    mapping(address buyer => uint256 amount) prebuys;
    uint256 totalPrebuy;
    uint256 prebuyTokens;
}

contract Launchpad is EIP712, Ownable {
    uint256 public constant TOKEN_SUPPLY = 1_000_000_000e18;
    uint256 internal constant BPS = 10_000;

    address public immutable usd;
    address public proofSigner;
    uint256 public auctionDuration = 24 hours;
    uint256 public auctionExtension = 5 minutes;
    uint256 public auctionMinBidIncrementBps = 1000;
    mapping(bytes32 handleId => Handle) public handles;

    event ProofSignerUpdated(address proofSigner);
    event AuctionSettingsUpdated(uint256 auctionDuration, uint256 auctionExtension, uint256 auctionMinBidIncrementBps);
    event AuctionStarted(bytes32 indexed handleId, string name, string symbol);
    event BidPlaced(bytes32 indexed handleId, address indexed bidder, uint256 amount, uint256 endTime);
    event AuctionCancelled(bytes32 indexed handleId, address indexed bidder, uint256 refund);
    event Prebought(bytes32 indexed handleId, address indexed buyer, uint256 amount);
    event Launched(
        bytes32 indexed handleId, address indexed token, address indexed launcher, string name, string symbol
    );

    error AlreadyLaunched();
    error AuctionAlreadyExists();
    error AuctionNotActive();
    error AuctionNotEnded();
    error BidTooLow(uint256 minBid);

    constructor(address proofSigner_, address usd_) {
        proofSigner = proofSigner_;
        usd = usd_;
        _initializeOwner(msg.sender);
    }

    function setProofSigner(address proofSigner_) external onlyOwner {
        proofSigner = proofSigner_;
        emit ProofSignerUpdated(proofSigner_);
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

    function startAuction(
        string calldata name,
        string calldata symbol,
        uint256 amount,
        uint256 proofDeadline,
        bytes calldata proof
    ) external returns (bytes32 handleId) {
        Proofs.verify(
            proofSigner,
            _hashTypedData(Proofs.startAuctionHash(name, symbol, amount, proofDeadline)),
            proofDeadline,
            proof
        );

        handleId = keccak256(bytes(symbol));
        require(handles[handleId].token == address(0), AlreadyLaunched());

        _startAuction(handleId, name, symbol);
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

        SafeTransferLib.safeTransferFrom(usd, msg.sender, address(this), amount);
    }

    function launch(bytes32 handleId) external returns (address token) {
        Handle storage handle = handles[handleId];
        Auction storage auction = handle.auction;
        uint256 endTime = auction.endTime;
        require(endTime != 0 && block.timestamp >= endTime, AuctionNotEnded());

        token = _launch(handle, handleId, auction.name, auction.symbol, auction.highestBidder);
    }

    function launchOwn(string calldata name, string calldata symbol, uint256 proofDeadline, bytes calldata proof)
        external
        returns (address token)
    {
        Proofs.verify(
            proofSigner,
            _hashTypedData(Proofs.launchOwnHash(name, symbol, msg.sender, proofDeadline)),
            proofDeadline,
            proof
        );

        bytes32 handleId = keccak256(bytes(symbol));
        Handle storage handle = handles[handleId];
        if (handle.auction.endTime != 0) _cancelAuction(handleId);

        token = _launch(handle, handleId, name, symbol, msg.sender);
    }

    function prebuyOf(bytes32 handleId, address buyer) external view returns (uint256) {
        return handles[handleId].prebuys[buyer];
    }

    function _startAuction(bytes32 handleId, string calldata name, string calldata symbol) internal {
        Auction storage auction = handles[handleId].auction;
        require(auction.endTime == 0, AuctionAlreadyExists());

        auction.name = name;
        auction.symbol = symbol;
        auction.endTime = block.timestamp + auctionDuration;

        emit AuctionStarted(handleId, name, symbol);
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

        SafeTransferLib.safeTransferFrom(usd, msg.sender, address(this), amount);
        if (previousBid != 0) SafeTransferLib.safeTransfer(usd, previousBidder, previousBid);
    }

    function _cancelAuction(bytes32 handleId) internal {
        Auction storage auction = handles[handleId].auction;
        address bidder = auction.highestBidder;
        uint256 refund = auction.highestBid;
        delete handles[handleId].auction;

        emit AuctionCancelled(handleId, bidder, refund);

        SafeTransferLib.safeTransfer(usd, bidder, refund);
    }

    function _launch(
        Handle storage handle,
        bytes32 handleId,
        string memory name,
        string memory symbol,
        address launcher
    ) internal returns (address token) {
        require(handle.token == address(0), AlreadyLaunched());

        token = address(new Token(name, symbol, TOKEN_SUPPLY));
        handle.token = token;
        handle.launcher = launcher;

        emit Launched(handleId, token, launcher, name, symbol);
    }

    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("Callpad", "1");
    }
}
