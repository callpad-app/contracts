// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {stdError} from "forge-std/StdError.sol";
import {Auction, Launchpad} from "../src/Launchpad.sol";
import {Proofs} from "../src/Proofs.sol";
import {LaunchFixture} from "./LaunchFixture.sol";

contract LaunchpadTest is LaunchFixture {
    bytes32 internal constant USER_ID = keccak256("user");

    address internal poster = makeAddr("poster");
    address internal otherWallet = makeAddr("other wallet");
    address internal blogger = makeAddr("blogger");

    function test_OpeningBidMayExceedProvenMinimum() public {
        bytes memory proof = _startAuctionProof("Other", "other");
        bytes32 salt = _validSalt(keccak256("other"));

        bytes32 handleId = launchpad.startAuction("Other", "other", salt, BID, 2 * BID, block.timestamp, proof);

        (Auction memory auction,,,,,,) = launchpad.handles(handleId);
        assertEq(auction.highestBid, 2 * BID);
    }

    function test_RevertWhen_OpeningBidIsBelowProvenMinimum() public {
        bytes memory proof = _startAuctionProof("Other", "other");
        bytes32 salt = _validSalt(keccak256("other"));

        vm.expectRevert(abi.encodeWithSelector(Launchpad.BidTooLow.selector, BID));
        launchpad.startAuction("Other", "other", salt, BID, BID - 1, block.timestamp, proof);
    }

    function test_AnyoneConfirmsTheCallWithAProof() public {
        bytes memory proof = _callProof(HANDLE_ID);

        vm.expectEmit();
        emit Launchpad.CallConfirmed(HANDLE_ID);
        vm.prank(poster);
        launchpad.confirmCall(HANDLE_ID, block.timestamp, proof);

        (,,,,,, uint256 calledAt) = launchpad.handles(HANDLE_ID);
        assertEq(calledAt, block.timestamp);
    }

    function test_RevertWhen_CallIsConfirmedTwice() public {
        _confirmCall(HANDLE_ID);
        bytes memory proof = _callProof(HANDLE_ID);

        vm.expectRevert(Launchpad.AlreadyCalled.selector);
        launchpad.confirmCall(HANDLE_ID, block.timestamp, proof);
    }

    function test_RevertWhen_CallIsConfirmedForOwnLaunch() public {
        _launchOwn(blogger);
        bytes memory proof = _callProof(OWN_HANDLE_ID);

        (,,,,,, uint256 calledAt) = launchpad.handles(OWN_HANDLE_ID);
        assertEq(calledAt, block.timestamp);
        vm.expectRevert(Launchpad.AlreadyCalled.selector);
        launchpad.confirmCall(OWN_HANDLE_ID, block.timestamp, proof);
    }

    function test_RevertWhen_CallIsConfirmedBeforeLaunch() public {
        bytes32 handleId = _startAuction("Other", "other");
        bytes memory proof = _callProof(handleId);

        vm.expectRevert(Launchpad.NotLaunched.selector);
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

        vm.expectRevert(Launchpad.NothingToClaim.selector);
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
        emit Launchpad.AirdropClaimed(HANDLE_ID, USER_ID, poster, 100e18);
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

        vm.expectRevert(Launchpad.AirdropCapExceeded.selector);
        this.claimAirdropAs(HANDLE_ID, USER_ID, poster, amount);
    }

    function test_RevertWhen_AirdropIsClaimedBeforeTheCall() public {
        vm.expectRevert(Launchpad.NotCalled.selector);
        this.claimAirdropAs(HANDLE_ID, USER_ID, poster, 100e18);
    }

    function test_RevertWhen_NothingHasUnlockedYet() public {
        _confirmCall(HANDLE_ID);

        vm.expectRevert(Launchpad.NothingToClaim.selector);
        this.claimAirdropAs(HANDLE_ID, USER_ID, poster, 100e18);
    }

    function test_RevertWhen_AirdropProofIsUsedTwice() public {
        _unlockAirdrop();
        _claimAirdrop(HANDLE_ID, USER_ID, poster, 100e18);

        vm.expectRevert(Launchpad.NothingToClaim.selector);
        this.claimAirdropAs(HANDLE_ID, USER_ID, poster, 100e18);
    }

    function test_RevertWhen_AirdropProofIsForLessThanAlreadyClaimed() public {
        _unlockAirdrop();
        _claimAirdrop(HANDLE_ID, USER_ID, poster, 100e18);

        vm.expectRevert(Launchpad.NothingToClaim.selector);
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
