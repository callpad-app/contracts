// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Ownable} from "solady/auth/Ownable.sol";
import {EIP712} from "solady/utils/EIP712.sol";
import {Auction} from "./Auction.sol";
import {Proofs} from "./Proofs.sol";
import {Token} from "./Token.sol";

contract Launchpad is EIP712, Ownable {
    uint256 public constant TOKEN_SUPPLY = 1_000_000_000e18;

    address public immutable usd;
    address public proofSigner;
    uint256 public auctionDuration = 24 hours;
    uint256 public auctionExtension = 5 minutes;
    uint256 public auctionMinBidIncrementBps = 1000;
    mapping(bytes32 auctionId => Auction.State) public auctions;
    mapping(bytes32 handleId => address token) public tokens;

    event ProofSignerUpdated(address proofSigner);
    event AuctionSettingsUpdated(uint256 auctionDuration, uint256 auctionExtension, uint256 auctionMinBidIncrementBps);
    event Launched(
        bytes32 indexed handleId, address indexed token, address indexed launcher, string name, string symbol
    );

    error AlreadyLaunched();
    error AuctionNotEnded();

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
    ) external returns (bytes32 auctionId) {
        Proofs.verify(
            proofSigner,
            _hashTypedData(Proofs.startAuctionHash(name, symbol, amount, proofDeadline)),
            proofDeadline,
            proof
        );

        auctionId = Auction.start(auctions, name, symbol, auctionDuration);
        require(tokens[auctionId] == address(0), AlreadyLaunched());
        Auction.bid(auctions, usd, auctionId, amount, auctionExtension, auctionMinBidIncrementBps);
    }

    function bid(bytes32 auctionId, uint256 amount) external {
        Auction.bid(auctions, usd, auctionId, amount, auctionExtension, auctionMinBidIncrementBps);
    }

    function launch(bytes32 auctionId) external returns (address token) {
        Auction.State storage auction = auctions[auctionId];
        uint256 endTime = auction.endTime;
        require(endTime != 0 && block.timestamp >= endTime, AuctionNotEnded());

        token = _launch(auctionId, auction.name, auction.symbol, auction.highestBidder);
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
        if (auctions[handleId].endTime != 0) Auction.cancel(auctions, usd, handleId);

        token = _launch(handleId, name, symbol, msg.sender);
    }

    function _launch(bytes32 handleId, string memory name, string memory symbol, address launcher)
        internal
        returns (address token)
    {
        require(tokens[handleId] == address(0), AlreadyLaunched());

        token = address(new Token(name, symbol, TOKEN_SUPPLY));
        tokens[handleId] = token;

        emit Launched(handleId, token, launcher, name, symbol);
    }

    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("Callpad", "1");
    }
}
