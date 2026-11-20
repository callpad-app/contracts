// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {stdError} from "forge-std/StdError.sol";
import {Auction, Launchpad} from "../src/Launchpad.sol";
import {Proofs} from "../src/Proofs.sol";
import {LaunchFixture} from "./LaunchFixture.sol";

contract LaunchpadTest is LaunchFixture {
    address internal poster = makeAddr("poster");

    function test_OpeningBidMayExceedProvenMinimum() public {
        bytes memory proof = _startAuctionProof("Other", "other");
        bytes32 salt = _validSalt(keccak256("other"));

        bytes32 handleId = launchpad.startAuction("Other", "other", salt, BID, 2 * BID, block.timestamp, proof);

        (Auction memory auction,,,,,) = launchpad.handles(handleId);
        assertEq(auction.highestBid, 2 * BID);
    }

    function test_RevertWhen_OpeningBidIsBelowProvenMinimum() public {
        bytes memory proof = _startAuctionProof("Other", "other");
        bytes32 salt = _validSalt(keccak256("other"));

        vm.expectRevert(abi.encodeWithSelector(Launchpad.BidTooLow.selector, BID));
        launchpad.startAuction("Other", "other", salt, BID, BID - 1, block.timestamp, proof);
    }

    function test_ClaimAirdropPaysTheProvenAmount() public {
        uint256 airdropTokens = _airdropTokens();

        vm.expectEmit();
        emit Launchpad.AirdropClaimed(HANDLE_ID, poster, 100e18);
        uint256 tokens = _claimAirdrop(HANDLE_ID, poster, 100e18);

        assertEq(tokens, 100e18);
        assertEq(IERC20(token).balanceOf(poster), 100e18);
        assertEq(launchpad.airdropClaimOf(HANDLE_ID, poster), 100e18);
        assertEq(_airdropTokens(), airdropTokens - 100e18);
    }

    function test_ClaimAirdropPaysOnlyTheIncreaseOfTheProvenAmount() public {
        _claimAirdrop(HANDLE_ID, poster, 100e18);

        uint256 tokens = _claimAirdrop(HANDLE_ID, poster, 250e18);

        assertEq(tokens, 150e18);
        assertEq(IERC20(token).balanceOf(poster), 250e18);
        assertEq(launchpad.airdropClaimOf(HANDLE_ID, poster), 250e18);
    }

    function test_WholeAirdropCanBeClaimedWithoutTouchingPrebuyTokens() public {
        (,,,, uint256 prebuyTokens, uint256 airdropTokens) = launchpad.handles(HANDLE_ID);

        _claimAirdrop(HANDLE_ID, poster, airdropTokens);

        assertEq(_airdropTokens(), 0);
        assertEq(launchpad.claimPrebuy(HANDLE_ID), prebuyTokens);
    }

    function test_RevertWhen_AirdropProofIsUsedTwice() public {
        _claimAirdrop(HANDLE_ID, poster, 100e18);

        vm.expectRevert(Launchpad.NothingToClaim.selector);
        this.claimAirdropAs(HANDLE_ID, poster, 100e18);
    }

    function test_RevertWhen_AirdropProofIsForLessThanAlreadyClaimed() public {
        _claimAirdrop(HANDLE_ID, poster, 100e18);

        vm.expectRevert(Launchpad.NothingToClaim.selector);
        this.claimAirdropAs(HANDLE_ID, poster, 40e18);
    }

    function test_RevertWhen_AirdropProofIsForAnotherAccount() public {
        bytes memory proof = _airdropProof(HANDLE_ID, poster, 100e18);

        vm.expectRevert(Proofs.InvalidProof.selector);
        launchpad.claimAirdrop(HANDLE_ID, 100e18, block.timestamp, proof);
    }

    function test_RevertWhen_AirdropProofIsForAnotherAmount() public {
        bytes memory proof = _airdropProof(HANDLE_ID, poster, 100e18);

        vm.expectRevert(Proofs.InvalidProof.selector);
        vm.prank(poster);
        launchpad.claimAirdrop(HANDLE_ID, 101e18, block.timestamp, proof);
    }

    function test_RevertWhen_AirdropProofHasExpired() public {
        bytes memory proof = _airdropProof(HANDLE_ID, poster, 100e18);
        uint256 proofDeadline = block.timestamp;
        skip(1);

        vm.expectRevert(Proofs.ProofExpired.selector);
        vm.prank(poster);
        launchpad.claimAirdrop(HANDLE_ID, 100e18, proofDeadline, proof);
    }

    function test_RevertWhen_AirdropClaimsExceedTheAirdrop() public {
        uint256 airdropTokens = _airdropTokens();
        _claimAirdrop(HANDLE_ID, poster, airdropTokens);

        vm.expectRevert(stdError.arithmeticError);
        this.claimAirdropAs(HANDLE_ID, makeAddr("other poster"), 1);
    }

    function test_RevertWhen_AirdropIsClaimedBeforeLaunch() public {
        bytes32 handleId = _startAuction("Other", "other");

        vm.expectRevert(stdError.arithmeticError);
        this.claimAirdropAs(handleId, poster, 1);
    }

    function claimAirdropAs(bytes32 handleId, address account, uint256 amount) external {
        _claimAirdrop(handleId, account, amount);
    }

    function _airdropTokens() internal view returns (uint256 airdropTokens) {
        (,,,,, airdropTokens) = launchpad.handles(HANDLE_ID);
    }
}
