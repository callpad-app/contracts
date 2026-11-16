// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Ownable} from "solady/auth/Ownable.sol";
import {EIP712} from "solady/utils/EIP712.sol";
import {Auction} from "./Auction.sol";
import {Proofs} from "./Proofs.sol";

contract Launchpad is EIP712, Ownable {
    address public immutable usd;
    address public proofSigner;
    uint256 public auctionDuration = 24 hours;
    uint256 public auctionExtension = 5 minutes;
    uint256 public auctionMinBidIncrementBps = 1000;
    mapping(bytes32 auctionId => Auction.State) public auctions;

    event ProofSignerUpdated(address proofSigner);
    event AuctionSettingsUpdated(uint256 auctionDuration, uint256 auctionExtension, uint256 auctionMinBidIncrementBps);

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
        Auction.bid(auctions, usd, auctionId, amount, auctionExtension, auctionMinBidIncrementBps);
    }

    function bid(bytes32 auctionId, uint256 amount) external {
        Auction.bid(auctions, usd, auctionId, amount, auctionExtension, auctionMinBidIncrementBps);
    }

    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("Callpad", "1");
    }
}
