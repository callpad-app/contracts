// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {MockERC20} from "solady/../test/utils/mocks/MockERC20.sol";
import {Auction} from "../src/Auction.sol";
import {Launchpad} from "../src/Launchpad.sol";
import {Proofs} from "../src/Proofs.sol";

contract LaunchpadTest is Test {
    string constant NAME = "vitalik.eth";
    string constant SYMBOL = "vitalikbuterin";
    uint256 constant FIRST_BID = 100e6;
    uint256 constant INITIAL_BALANCE = 10_000e6;

    Launchpad launchpad;
    MockERC20 usd;
    uint256 proofSignerKey;
    uint256 proofDeadline = block.timestamp + 1 hours;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    bytes32 auctionId = keccak256(bytes(SYMBOL));

    function setUp() public {
        address proofSigner;
        (proofSigner, proofSignerKey) = makeAddrAndKey("proofSigner");
        usd = new MockERC20("USD Coin", "USDC", 6);
        launchpad = new Launchpad(proofSigner, address(usd));
        fund(alice);
        fund(bob);
    }

    function fund(address bidder) internal {
        usd.mint(bidder, INITIAL_BALANCE);
        vm.prank(bidder);
        usd.approve(address(launchpad), type(uint256).max);
    }

    function sign(uint256 key, string memory name, string memory symbol, uint256 bid, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Callpad"),
                keccak256("1"),
                block.chainid,
                address(launchpad)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(Proofs.START_AUCTION_TYPEHASH, keccak256(bytes(name)), keccak256(bytes(symbol)), bid, deadline)
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(key, keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash)));
        return abi.encodePacked(r, s, v);
    }

    function startAuction(uint256 amount) internal {
        bytes memory proof = sign(proofSignerKey, NAME, SYMBOL, amount, proofDeadline);
        vm.prank(alice);
        launchpad.startAuction(NAME, SYMBOL, amount, proofDeadline, proof);
    }

    function test_StartAuctionRecordsFirstBid() public {
        startAuction(200e6);

        (string memory name, string memory symbol, address highestBidder, uint256 highestBid, uint256 endTime) =
            launchpad.auctions(auctionId);
        assertEq(name, NAME);
        assertEq(symbol, SYMBOL);
        assertEq(highestBidder, alice);
        assertEq(highestBid, 200e6);
        assertEq(endTime, block.timestamp + 24 hours);
        assertEq(usd.balanceOf(address(launchpad)), 200e6);
        assertEq(usd.balanceOf(alice), INITIAL_BALANCE - 200e6);
    }

    function test_StartAuctionRevertsWhenProofSignedByStranger() public {
        (, uint256 strangerKey) = makeAddrAndKey("stranger");
        bytes memory proof = sign(strangerKey, NAME, SYMBOL, FIRST_BID, proofDeadline);
        vm.prank(alice);
        vm.expectRevert(Proofs.InvalidProof.selector);
        launchpad.startAuction(NAME, SYMBOL, FIRST_BID, proofDeadline, proof);
    }

    function test_StartAuctionRevertsWhenNameDiffersFromProof() public {
        bytes memory proof = sign(proofSignerKey, NAME, SYMBOL, FIRST_BID, proofDeadline);
        vm.prank(alice);
        vm.expectRevert(Proofs.InvalidProof.selector);
        launchpad.startAuction("fake", SYMBOL, FIRST_BID, proofDeadline, proof);
    }

    function test_StartAuctionRevertsWhenSymbolDiffersFromProof() public {
        bytes memory proof = sign(proofSignerKey, NAME, SYMBOL, FIRST_BID, proofDeadline);
        vm.prank(alice);
        vm.expectRevert(Proofs.InvalidProof.selector);
        launchpad.startAuction(NAME, "fake", FIRST_BID, proofDeadline, proof);
    }

    function test_StartAuctionRevertsWhenBidDiffersFromProof() public {
        bytes memory proof = sign(proofSignerKey, NAME, SYMBOL, FIRST_BID, proofDeadline);
        vm.prank(alice);
        vm.expectRevert(Proofs.InvalidProof.selector);
        launchpad.startAuction(NAME, SYMBOL, FIRST_BID - 1, proofDeadline, proof);
    }

    function test_StartAuctionRevertsWhenProofDeadlineDiffersFromProof() public {
        bytes memory proof = sign(proofSignerKey, NAME, SYMBOL, FIRST_BID, proofDeadline);
        vm.prank(alice);
        vm.expectRevert(Proofs.InvalidProof.selector);
        launchpad.startAuction(NAME, SYMBOL, FIRST_BID, proofDeadline + 1, proof);
    }

    function test_StartAuctionSucceedsAtProofDeadline() public {
        vm.warp(proofDeadline);

        startAuction(FIRST_BID);

        (,, address highestBidder,,) = launchpad.auctions(auctionId);
        assertEq(highestBidder, alice);
    }

    function test_StartAuctionRevertsWhenProofExpired() public {
        bytes memory proof = sign(proofSignerKey, NAME, SYMBOL, FIRST_BID, proofDeadline);
        vm.warp(proofDeadline + 1);

        vm.prank(alice);
        vm.expectRevert(Proofs.ProofExpired.selector);
        launchpad.startAuction(NAME, SYMBOL, FIRST_BID, proofDeadline, proof);
    }

    function test_StartAuctionRevertsWhenHandleAlreadyAuctioned() public {
        startAuction(FIRST_BID);

        bytes memory proof = sign(proofSignerKey, NAME, SYMBOL, FIRST_BID, proofDeadline);
        vm.prank(bob);
        vm.expectRevert(Auction.AuctionAlreadyExists.selector);
        launchpad.startAuction(NAME, SYMBOL, FIRST_BID, proofDeadline, proof);
    }

    function test_BidRecordsNewBidAndRefundsPreviousBidder() public {
        startAuction(100e6);

        vm.prank(bob);
        launchpad.bid(auctionId, 110e6);

        (,, address highestBidder, uint256 highestBid,) = launchpad.auctions(auctionId);
        assertEq(highestBidder, bob);
        assertEq(highestBid, 110e6);
        assertEq(usd.balanceOf(alice), INITIAL_BALANCE);
        assertEq(usd.balanceOf(bob), INITIAL_BALANCE - 110e6);
        assertEq(usd.balanceOf(address(launchpad)), 110e6);
    }

    function test_BidRevertsWhenIncrementBelowTenPercent() public {
        startAuction(100e6);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Auction.BidTooLow.selector, 110e6));
        launchpad.bid(auctionId, 110e6 - 1);
    }

    function test_BidRevertsWhenAuctionDoesNotExist() public {
        vm.prank(bob);
        vm.expectRevert(Auction.AuctionNotActive.selector);
        launchpad.bid(auctionId, 100e6);
    }

    function test_BidRevertsWhenAuctionEnded() public {
        startAuction(100e6);
        skip(24 hours);

        vm.prank(bob);
        vm.expectRevert(Auction.AuctionNotActive.selector);
        launchpad.bid(auctionId, 200e6);
    }

    function test_BidInLastFiveMinutesExtendsAuction() public {
        startAuction(100e6);
        (,,,, uint256 endTime) = launchpad.auctions(auctionId);
        skip(24 hours - 1 minutes);

        vm.prank(bob);
        launchpad.bid(auctionId, 200e6);

        (,,,, uint256 extendedEndTime) = launchpad.auctions(auctionId);
        assertEq(extendedEndTime, endTime + 5 minutes);
    }

    function test_BidBeforeLastFiveMinutesKeepsEndTime() public {
        startAuction(100e6);
        (,,,, uint256 endTime) = launchpad.auctions(auctionId);
        skip(1 hours);

        vm.prank(bob);
        launchpad.bid(auctionId, 200e6);

        (,,,, uint256 sameEndTime) = launchpad.auctions(auctionId);
        assertEq(sameEndTime, endTime);
    }

    function test_DefaultAuctionSettings() public view {
        assertEq(launchpad.auctionDuration(), 24 hours);
        assertEq(launchpad.auctionExtension(), 5 minutes);
        assertEq(launchpad.auctionMinBidIncrementBps(), 1000);
    }

    function test_SetAuctionSettingsRevertsWhenCallerIsNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        launchpad.setAuctionSettings(1 hours, 1 minutes, 500);
    }

    function test_UpdatedDurationAppliesToNewAuction() public {
        launchpad.setAuctionSettings(1 hours, 5 minutes, 1000);

        startAuction(100e6);

        (,,,, uint256 endTime) = launchpad.auctions(auctionId);
        assertEq(endTime, block.timestamp + 1 hours);
    }

    function test_UpdatedIncrementAppliesToNextBid() public {
        startAuction(100e6);
        launchpad.setAuctionSettings(24 hours, 5 minutes, 5000);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Auction.BidTooLow.selector, 150e6));
        launchpad.bid(auctionId, 149e6);

        vm.prank(bob);
        launchpad.bid(auctionId, 150e6);
    }

    function test_UpdatedExtensionAppliesToNextBid() public {
        startAuction(100e6);
        (,,,, uint256 endTime) = launchpad.auctions(auctionId);
        launchpad.setAuctionSettings(24 hours, 1 hours, 1000);
        skip(24 hours - 30 minutes);

        vm.prank(bob);
        launchpad.bid(auctionId, 200e6);

        (,,,, uint256 extendedEndTime) = launchpad.auctions(auctionId);
        assertEq(extendedEndTime, endTime + 1 hours);
    }

    function test_SetProofSignerRevertsWhenCallerIsNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        launchpad.setProofSigner(alice);
    }

    function test_NewProofSignerReplacesPreviousOne() public {
        (address newProofSigner, uint256 newProofSignerKey) = makeAddrAndKey("newProofSigner");
        launchpad.setProofSigner(newProofSigner);
        assertEq(launchpad.proofSigner(), newProofSigner);

        bytes memory staleProof = sign(proofSignerKey, NAME, SYMBOL, FIRST_BID, proofDeadline);
        vm.prank(alice);
        vm.expectRevert(Proofs.InvalidProof.selector);
        launchpad.startAuction(NAME, SYMBOL, FIRST_BID, proofDeadline, staleProof);

        bytes memory proof = sign(newProofSignerKey, NAME, SYMBOL, FIRST_BID, proofDeadline);
        vm.prank(alice);
        launchpad.startAuction(NAME, SYMBOL, FIRST_BID, proofDeadline, proof);
    }
}
