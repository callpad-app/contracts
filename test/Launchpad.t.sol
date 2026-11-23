// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {stdError} from "forge-std/StdError.sol";
import {ILaunchpad} from "../src/interfaces/ILaunchpad.sol";
import {Proofs} from "../src/Proofs.sol";
import {LaunchFixture} from "./LaunchFixture.sol";

contract LaunchpadTest is LaunchFixture {
    using StateLibrary for IPoolManager;

    bytes32 internal constant USER_ID = keccak256("user");

    address internal poster = makeAddr("poster");
    address internal otherWallet = makeAddr("other wallet");
    address internal blogger = makeAddr("blogger");

    function test_OpeningBidMayExceedProvenMinimum() public {
        bytes memory proof = _startAuctionProof("Other", "other");
        bytes32 salt = _validSalt(keccak256("other"));

        bytes32 handleId = launchpad.startAuction("Other", "other", salt, BID, 2 * BID, block.timestamp, proof);

        (ILaunchpad.Auction memory auction,,,,,,) = launchpad.handles(handleId);
        assertEq(auction.highestBid, 2 * BID);
    }

    function test_RevertWhen_OpeningBidIsBelowProvenMinimum() public {
        bytes memory proof = _startAuctionProof("Other", "other");
        bytes32 salt = _validSalt(keccak256("other"));

        vm.expectRevert(abi.encodeWithSelector(ILaunchpad.BidTooLow.selector, BID));
        launchpad.startAuction("Other", "other", salt, BID, BID - 1, block.timestamp, proof);
    }

    function test_SymbolKeepsItsCaseAndHandleIdIgnoresIt() public {
        bytes32 handleId = _startAuction("Parik Patel", "ParikPatelCFA");

        (ILaunchpad.Auction memory auction,,,,,,) = launchpad.handles(handleId);
        assertEq(auction.symbol, "ParikPatelCFA");
        assertEq(handleId, keccak256("parikpatelcfa"));
    }

    function test_RevertWhen_HandleIsAuctionedAgainInAnotherCase() public {
        bytes32 handleId = _startAuction("Parik Patel", "ParikPatelCFA");
        bytes memory proof = _startAuctionProof("Parik Patel", "parikpatelcfa");
        bytes32 salt = _validSalt(handleId);

        vm.expectRevert(ILaunchpad.AuctionAlreadyExists.selector);
        launchpad.startAuction("Parik Patel", "parikpatelcfa", salt, BID, BID, block.timestamp, proof);
    }

    function test_RunningAuctionKeepsItsBidStepAndExtension() public {
        uint256 duration = launchpad.auctionDuration();
        uint256 extension = launchpad.auctionExtension();
        bytes32 handleId = _startAuction("Other", "other");
        launchpad.setAuctionSettings(1 hours, 1 hours, 5000);

        skip(duration - extension);
        launchpad.bid(handleId, BID * 11 / 10);

        (ILaunchpad.Auction memory auction,,,,,,) = launchpad.handles(handleId);
        assertEq(auction.endTime, block.timestamp + 2 * extension);
    }

    function test_RunningAuctionKeepsItsAirdropAndStartPrice() public {
        uint256 airdropBps = launchpad.airdropBps();
        int24 startTick = launchpad.startTick();
        bytes32 handleId = _startAuction("Other", "other");
        launchpad.setLaunchSettings(2 * airdropBps, startTick + launchpad.TICK_SPACING());

        skip(launchpad.auctionDuration());
        uint256 airdropTokens = launchpad.TOKEN_SUPPLY() * airdropBps / 10_000;
        vm.expectEmit(true, false, true, true);
        emit ILaunchpad.Launched(handleId, address(0), address(this), "Other", "other", airdropTokens, startTick);
        _trade(launchpad.launch(handleId));

        (,,,,, uint256 keptTokens,) = launchpad.handles(handleId);
        assertEq(keptTokens, airdropTokens);
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(startTick));
    }

    function test_OwnLaunchOverAnAuctionKeepsItsStartPrice() public {
        int24 startTick = launchpad.startTick();
        _startAuction("Own", "own");
        launchpad.setLaunchSettings(launchpad.airdropBps(), startTick + launchpad.TICK_SPACING());

        _trade(_launchOwn(blogger));

        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(startTick));
    }

    function test_SettingsApplyToAuctionsStartedAfterTheChange() public {
        int24 startTick = launchpad.startTick() + launchpad.TICK_SPACING();
        launchpad.setAuctionSettings(1 hours, 10 minutes, 5000);
        launchpad.setLaunchSettings(500, startTick);

        bytes32 handleId = _startAuction("Other", "other");

        (ILaunchpad.Auction memory auction,,,,,,) = launchpad.handles(handleId);
        assertEq(auction.endTime, block.timestamp + 1 hours);
        assertEq(auction.extension, 10 minutes);
        assertEq(auction.minBidIncrementBps, 5000);
        assertEq(auction.airdropBps, 500);
        assertEq(auction.startTick, startTick);
    }

    function test_AnyoneConfirmsTheCallWithAProof() public {
        bytes memory proof = _callProof(HANDLE_ID);

        vm.expectEmit();
        emit ILaunchpad.CallConfirmed(HANDLE_ID);
        vm.prank(poster);
        launchpad.confirmCall(HANDLE_ID, block.timestamp, proof);

        (,,,,,, uint256 calledAt) = launchpad.handles(HANDLE_ID);
        assertEq(calledAt, block.timestamp);
    }

    function test_RevertWhen_CallIsConfirmedTwice() public {
        _confirmCall(HANDLE_ID);
        bytes memory proof = _callProof(HANDLE_ID);

        vm.expectRevert(ILaunchpad.AlreadyCalled.selector);
        launchpad.confirmCall(HANDLE_ID, block.timestamp, proof);
    }

    function test_RevertWhen_CallIsConfirmedForOwnLaunch() public {
        _launchOwn(blogger);
        bytes memory proof = _callProof(OWN_HANDLE_ID);

        (,,,,,, uint256 calledAt) = launchpad.handles(OWN_HANDLE_ID);
        assertEq(calledAt, block.timestamp);
        vm.expectRevert(ILaunchpad.AlreadyCalled.selector);
        launchpad.confirmCall(OWN_HANDLE_ID, block.timestamp, proof);
    }

    function test_RevertWhen_CallIsConfirmedBeforeLaunch() public {
        bytes32 handleId = _startAuction("Other", "other");
        bytes memory proof = _callProof(handleId);

        vm.expectRevert(ILaunchpad.NotLaunched.selector);
        launchpad.confirmCall(handleId, block.timestamp, proof);
    }

    function test_RevertWhen_CallProofIsForAnotherHandle() public {
        bytes memory proof = _callProof(OWN_HANDLE_ID);

        vm.expectRevert(Proofs.InvalidProof.selector);
        launchpad.confirmCall(HANDLE_ID, block.timestamp, proof);
    }

    function test_RevertWhen_CallProofHasExpired() public {
        bytes memory proof = _callProof(HANDLE_ID);
        uint256 proofDeadline = block.timestamp;
        skip(1);

        vm.expectRevert(Proofs.ProofExpired.selector);
        launchpad.confirmCall(HANDLE_ID, proofDeadline, proof);
    }

    function test_OwnLaunchKeepsNoAirdrop() public {
        address ownToken = _launchOwn(blogger);

        (,,,,, uint256 airdropTokens,) = launchpad.handles(OWN_HANDLE_ID);
        assertEq(airdropTokens, 0);
        assertApproxEqAbs(IERC20(ownToken).balanceOf(address(manager)), launchpad.TOKEN_SUPPLY(), 1e18);
    }

    function test_AirdropUnlocksEvenlyAfterTheCall() public {
        _confirmCall(HANDLE_ID);

        skip(1 days);
        assertEq(_claimAirdrop(HANDLE_ID, USER_ID, poster, 700e18), 100e18);

        skip(2 days);
        assertEq(_claimAirdrop(HANDLE_ID, USER_ID, poster, 700e18), 200e18);

        skip(30 days);
        assertEq(_claimAirdrop(HANDLE_ID, USER_ID, poster, 700e18), 400e18);
        assertEq(IERC20(token).balanceOf(poster), 700e18);
    }

    function test_UserClaimsToAnyWalletOutOfOneShare() public {
        _confirmCall(HANDLE_ID);

        skip(1 days);
        assertEq(_claimAirdrop(HANDLE_ID, USER_ID, poster, 700e18), 100e18);

        skip(2 days);
        assertEq(_claimAirdrop(HANDLE_ID, USER_ID, otherWallet, 700e18), 200e18);

        assertEq(IERC20(token).balanceOf(poster), 100e18);
        assertEq(IERC20(token).balanceOf(otherWallet), 200e18);
        assertEq(launchpad.airdropClaimOf(HANDLE_ID, USER_ID), 300e18);
    }

    function test_RevertWhen_UserClaimsTheCapAgainFromAnotherWallet() public {
        _unlockAirdrop();
        uint256 cap = launchpad.AIRDROP_CAP();
        _claimAirdrop(HANDLE_ID, USER_ID, poster, cap);

        vm.expectRevert(ILaunchpad.NothingToClaim.selector);
        this.claimAirdropAs(HANDLE_ID, USER_ID, otherWallet, cap);
    }

    function test_RevertWhen_AirdropProofIsForAnotherUser() public {
        bytes memory proof = _airdropProof(HANDLE_ID, USER_ID, poster, 100e18);

        vm.expectRevert(Proofs.InvalidProof.selector);
        vm.prank(poster);
        launchpad.claimAirdrop(HANDLE_ID, keccak256("other user"), 100e18, block.timestamp, proof);
    }

    function test_ClaimAirdropPaysTheProvenAmount() public {
        _unlockAirdrop();
        uint256 airdropTokens = _airdropTokens();

        vm.expectEmit();
        emit ILaunchpad.AirdropClaimed(HANDLE_ID, USER_ID, poster, 100e18);
        uint256 tokens = _claimAirdrop(HANDLE_ID, USER_ID, poster, 100e18);

        assertEq(tokens, 100e18);
        assertEq(IERC20(token).balanceOf(poster), 100e18);
        assertEq(launchpad.airdropClaimOf(HANDLE_ID, USER_ID), 100e18);
        assertEq(_airdropTokens(), airdropTokens - 100e18);
    }

    function test_ClaimAirdropPaysOnlyTheIncreaseOfTheProvenAmount() public {
        _unlockAirdrop();
        _claimAirdrop(HANDLE_ID, USER_ID, poster, 100e18);

        uint256 tokens = _claimAirdrop(HANDLE_ID, USER_ID, poster, 250e18);

        assertEq(tokens, 150e18);
        assertEq(IERC20(token).balanceOf(poster), 250e18);
        assertEq(launchpad.airdropClaimOf(HANDLE_ID, USER_ID), 250e18);
    }

    function test_WholeAirdropCanBeClaimedWithoutTouchingPrebuyTokens() public {
        (,,,, uint256 prebuyTokens,,) = launchpad.handles(HANDLE_ID);
        _unlockAirdrop();

        _claimWholeAirdrop();

        assertEq(_airdropTokens(), 0);
        assertEq(launchpad.claimPrebuy(HANDLE_ID), prebuyTokens);
    }

    function test_RevertWhen_AirdropAmountExceedsTheCap() public {
        _unlockAirdrop();
        uint256 amount = launchpad.AIRDROP_CAP() + 1;

        vm.expectRevert(ILaunchpad.AirdropCapExceeded.selector);
        this.claimAirdropAs(HANDLE_ID, USER_ID, poster, amount);
    }

    function test_RevertWhen_AirdropIsClaimedBeforeTheCall() public {
        vm.expectRevert(ILaunchpad.NotCalled.selector);
        this.claimAirdropAs(HANDLE_ID, USER_ID, poster, 100e18);
    }

    function test_RevertWhen_NothingHasUnlockedYet() public {
        _confirmCall(HANDLE_ID);

        vm.expectRevert(ILaunchpad.NothingToClaim.selector);
        this.claimAirdropAs(HANDLE_ID, USER_ID, poster, 100e18);
    }

    function test_RevertWhen_AirdropProofIsUsedTwice() public {
        _unlockAirdrop();
        _claimAirdrop(HANDLE_ID, USER_ID, poster, 100e18);

        vm.expectRevert(ILaunchpad.NothingToClaim.selector);
        this.claimAirdropAs(HANDLE_ID, USER_ID, poster, 100e18);
    }

    function test_RevertWhen_AirdropProofIsForLessThanAlreadyClaimed() public {
        _unlockAirdrop();
        _claimAirdrop(HANDLE_ID, USER_ID, poster, 100e18);

        vm.expectRevert(ILaunchpad.NothingToClaim.selector);
        this.claimAirdropAs(HANDLE_ID, USER_ID, poster, 40e18);
    }

    function test_RevertWhen_AirdropProofIsForAnotherAccount() public {
        bytes memory proof = _airdropProof(HANDLE_ID, USER_ID, poster, 100e18);

        vm.expectRevert(Proofs.InvalidProof.selector);
        launchpad.claimAirdrop(HANDLE_ID, USER_ID, 100e18, block.timestamp, proof);
    }

    function test_RevertWhen_AirdropProofIsForAnotherAmount() public {
        bytes memory proof = _airdropProof(HANDLE_ID, USER_ID, poster, 100e18);

        vm.expectRevert(Proofs.InvalidProof.selector);
        vm.prank(poster);
        launchpad.claimAirdrop(HANDLE_ID, USER_ID, 101e18, block.timestamp, proof);
    }

    function test_RevertWhen_AirdropProofHasExpired() public {
        bytes memory proof = _airdropProof(HANDLE_ID, USER_ID, poster, 100e18);
        uint256 proofDeadline = block.timestamp;
        skip(1);

        vm.expectRevert(Proofs.ProofExpired.selector);
        vm.prank(poster);
        launchpad.claimAirdrop(HANDLE_ID, USER_ID, 100e18, proofDeadline, proof);
    }

    function test_RevertWhen_AirdropClaimsExceedTheAirdrop() public {
        _unlockAirdrop();
        _claimWholeAirdrop();

        vm.expectRevert(stdError.arithmeticError);
        this.claimAirdropAs(HANDLE_ID, USER_ID, poster, 1);
    }

    function claimAirdropAs(bytes32 handleId, bytes32 userId, address account, uint256 amount) external {
        _claimAirdrop(handleId, userId, account, amount);
    }

    function _unlockAirdrop() internal {
        _confirmCall(HANDLE_ID);
        skip(launchpad.AIRDROP_UNLOCK_PERIOD());
    }

    function _claimWholeAirdrop() internal {
        uint256 cap = launchpad.AIRDROP_CAP();
        for (uint256 i; _airdropTokens() != 0; ++i) {
            _claimAirdrop(HANDLE_ID, bytes32(i), poster, Math.min(cap, _airdropTokens()));
        }
    }

    function _airdropTokens() internal view returns (uint256 airdropTokens) {
        (,,,,, airdropTokens,) = launchpad.handles(HANDLE_ID);
    }
}
