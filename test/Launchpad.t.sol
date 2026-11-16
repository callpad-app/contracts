// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {MockERC20} from "solady/../test/utils/mocks/MockERC20.sol";
import {Auction} from "../src/Auction.sol";
import {Launchpad} from "../src/Launchpad.sol";
import {Proofs} from "../src/Proofs.sol";
import {Token} from "../src/Token.sol";

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
    address owner = makeAddr("owner");
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

    function signStruct(uint256 key, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Callpad"),
                keccak256("1"),
                block.chainid,
                address(launchpad)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(key, keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash)));
        return abi.encodePacked(r, s, v);
    }

    function sign(uint256 key, string memory name, string memory symbol, uint256 bid, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        return signStruct(
            key,
            keccak256(
                abi.encode(
                    Proofs.START_AUCTION_TYPEHASH, keccak256(bytes(name)), keccak256(bytes(symbol)), bid, deadline
                )
            )
        );
    }

    function signLaunchOwn(uint256 key, string memory name, string memory symbol, address wallet, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        return signStruct(
            key,
            keccak256(
                abi.encode(
                    Proofs.LAUNCH_OWN_TYPEHASH, keccak256(bytes(name)), keccak256(bytes(symbol)), wallet, deadline
                )
            )
        );
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

    function test_LaunchCreatesTokenFromAuctionProfile() public {
        startAuction(FIRST_BID);
        skip(24 hours);

        vm.prank(bob);
        Token token = Token(launchpad.launch(auctionId));

        assertEq(launchpad.tokens(auctionId), address(token));
        assertEq(token.name(), NAME);
        assertEq(token.symbol(), SYMBOL);
        assertEq(token.totalSupply(), launchpad.TOKEN_SUPPLY());
        assertEq(token.balanceOf(address(launchpad)), launchpad.TOKEN_SUPPLY());
    }

    function test_LaunchEmitsWinnerAsLauncher() public {
        startAuction(FIRST_BID);
        vm.prank(bob);
        launchpad.bid(auctionId, 200e6);
        skip(24 hours);

        vm.expectEmit(true, false, true, true);
        emit Launchpad.Launched(auctionId, address(0), bob, NAME, SYMBOL);
        launchpad.launch(auctionId);
    }

    function test_LaunchRevertsWhenAuctionStillActive() public {
        startAuction(FIRST_BID);
        skip(24 hours - 1);

        vm.expectRevert(Launchpad.AuctionNotEnded.selector);
        launchpad.launch(auctionId);
    }

    function test_LaunchRevertsWhenAuctionDoesNotExist() public {
        vm.expectRevert(Launchpad.AuctionNotEnded.selector);
        launchpad.launch(auctionId);
    }

    function test_LaunchRevertsWhenAlreadyLaunched() public {
        startAuction(FIRST_BID);
        skip(24 hours);
        launchpad.launch(auctionId);

        vm.expectRevert(Launchpad.AlreadyLaunched.selector);
        launchpad.launch(auctionId);
    }

    function test_LaunchOwnCreatesTokenWithoutAuction() public {
        bytes memory proof = signLaunchOwn(proofSignerKey, NAME, SYMBOL, alice, proofDeadline);

        vm.expectEmit(true, false, true, true);
        emit Launchpad.Launched(auctionId, address(0), alice, NAME, SYMBOL);
        vm.prank(alice);
        Token token = Token(launchpad.launchOwn(NAME, SYMBOL, proofDeadline, proof));

        assertEq(launchpad.tokens(auctionId), address(token));
        assertEq(token.name(), NAME);
        assertEq(token.symbol(), SYMBOL);
        assertEq(token.balanceOf(address(launchpad)), launchpad.TOKEN_SUPPLY());
    }

    function test_LaunchOwnRevertsWhenCallerIsNotProvenOwner() public {
        bytes memory proof = signLaunchOwn(proofSignerKey, NAME, SYMBOL, alice, proofDeadline);

        vm.prank(bob);
        vm.expectRevert(Proofs.InvalidProof.selector);
        launchpad.launchOwn(NAME, SYMBOL, proofDeadline, proof);
    }

    function test_LaunchOwnRevertsWhenProofSignedByStranger() public {
        (, uint256 strangerKey) = makeAddrAndKey("stranger");
        bytes memory proof = signLaunchOwn(strangerKey, NAME, SYMBOL, alice, proofDeadline);

        vm.prank(alice);
        vm.expectRevert(Proofs.InvalidProof.selector);
        launchpad.launchOwn(NAME, SYMBOL, proofDeadline, proof);
    }

    function test_LaunchOwnRevertsWhenGivenStartAuctionProof() public {
        bytes memory proof = sign(proofSignerKey, NAME, SYMBOL, uint256(uint160(alice)), proofDeadline);

        vm.prank(alice);
        vm.expectRevert(Proofs.InvalidProof.selector);
        launchpad.launchOwn(NAME, SYMBOL, proofDeadline, proof);
    }

    function test_LaunchOwnRevertsWhenProofExpired() public {
        bytes memory proof = signLaunchOwn(proofSignerKey, NAME, SYMBOL, alice, proofDeadline);
        vm.warp(proofDeadline + 1);

        vm.prank(alice);
        vm.expectRevert(Proofs.ProofExpired.selector);
        launchpad.launchOwn(NAME, SYMBOL, proofDeadline, proof);
    }

    function test_LaunchOwnDuringAuctionRefundsHighestBidder() public {
        startAuction(FIRST_BID);
        vm.prank(bob);
        launchpad.bid(auctionId, 200e6);
        bytes memory proof = signLaunchOwn(proofSignerKey, NAME, SYMBOL, owner, proofDeadline);

        vm.expectEmit();
        emit Auction.AuctionCancelled(auctionId, bob, 200e6);
        vm.prank(owner);
        address token = launchpad.launchOwn(NAME, SYMBOL, proofDeadline, proof);

        assertEq(launchpad.tokens(auctionId), token);
        assertEq(usd.balanceOf(alice), INITIAL_BALANCE);
        assertEq(usd.balanceOf(bob), INITIAL_BALANCE);
        assertEq(usd.balanceOf(address(launchpad)), 0);
        (,, address highestBidder, uint256 highestBid, uint256 endTime) = launchpad.auctions(auctionId);
        assertEq(highestBidder, address(0));
        assertEq(highestBid, 0);
        assertEq(endTime, 0);
    }

    function test_LaunchOwnAfterAuctionEndedRefundsWinner() public {
        startAuction(FIRST_BID);
        skip(24 hours);
        bytes memory proof = signLaunchOwn(proofSignerKey, NAME, SYMBOL, owner, block.timestamp);

        vm.prank(owner);
        launchpad.launchOwn(NAME, SYMBOL, block.timestamp, proof);

        assertEq(usd.balanceOf(alice), INITIAL_BALANCE);
        assertEq(usd.balanceOf(address(launchpad)), 0);
    }

    function test_BidRevertsAfterOwnerCancelledAuction() public {
        startAuction(FIRST_BID);
        bytes memory proof = signLaunchOwn(proofSignerKey, NAME, SYMBOL, owner, proofDeadline);
        vm.prank(owner);
        launchpad.launchOwn(NAME, SYMBOL, proofDeadline, proof);

        vm.prank(bob);
        vm.expectRevert(Auction.AuctionNotActive.selector);
        launchpad.bid(auctionId, 200e6);
    }

    function test_LaunchOwnRevertsWhenAuctionWinnerAlreadyLaunched() public {
        startAuction(FIRST_BID);
        skip(24 hours);
        launchpad.launch(auctionId);
        bytes memory proof = signLaunchOwn(proofSignerKey, NAME, SYMBOL, owner, block.timestamp);

        vm.prank(owner);
        vm.expectRevert(Launchpad.AlreadyLaunched.selector);
        launchpad.launchOwn(NAME, SYMBOL, block.timestamp, proof);

        assertEq(usd.balanceOf(address(launchpad)), FIRST_BID);
    }

    function test_LaunchOwnRevertsWhenAlreadyLaunched() public {
        bytes memory proof = signLaunchOwn(proofSignerKey, NAME, SYMBOL, alice, proofDeadline);
        vm.prank(alice);
        launchpad.launchOwn(NAME, SYMBOL, proofDeadline, proof);

        vm.prank(alice);
        vm.expectRevert(Launchpad.AlreadyLaunched.selector);
        launchpad.launchOwn(NAME, SYMBOL, proofDeadline, proof);
    }

    function test_StartAuctionRevertsWhenOwnerAlreadyLaunched() public {
        bytes memory ownProof = signLaunchOwn(proofSignerKey, NAME, SYMBOL, alice, proofDeadline);
        vm.prank(alice);
        launchpad.launchOwn(NAME, SYMBOL, proofDeadline, ownProof);

        bytes memory proof = sign(proofSignerKey, NAME, SYMBOL, FIRST_BID, proofDeadline);
        vm.prank(bob);
        vm.expectRevert(Launchpad.AlreadyLaunched.selector);
        launchpad.startAuction(NAME, SYMBOL, FIRST_BID, proofDeadline, proof);
    }
}
