// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Hook} from "../src/Hook.sol";
import {Launchpad} from "../src/Launchpad.sol";
import {Proofs} from "../src/Proofs.sol";
import {LaunchFixture} from "./LaunchFixture.sol";

contract HookFeesTest is LaunchFixture {
    address internal blogger = makeAddr("blogger");

    function test_BidAndPrebuyFeeAreSplit() public view {
        (address creator, address account) = hook.recipients(token);

        assertEq(creator, address(this));
        assertEq(account, address(0));
        assertEq(hook.treasuryFees(), 3e6 + 3e6);
        assertEq(hook.fees(address(this)), 3.5e6);
        assertEq(hook.escrowedFees(token), 7e6 + 3.5e6);
        assertEq(usd.balanceOf(address(launchpad)), 0);
    }

    function test_SwapFeeIsCreditedInFull() public {
        (,, uint256 fee) = _swap(true, -33_333_333);

        assertEq(hook.treasuryFees() + hook.fees(address(this)) + hook.escrowedFees(token), BID + PREBUY_FEE + fee);
        assertEq(_usdFees(), BID + PREBUY_FEE + fee);
    }

    function test_CreatorAndTreasuryTakeOwnShares() public {
        assertEq(_take(address(this)), 3.5e6);
        assertEq(_take(treasury), 3e6 + 3e6);
        assertEq(hook.escrowedFees(token), 7e6 + 3.5e6);
        assertEq(_usdFees(), 7e6 + 3.5e6);
    }

    function test_RevertWhen_NothingToTake() public {
        hook.takeFees();

        vm.expectRevert(Hook.NothingToTake.selector);
        hook.takeFees();

        vm.prank(blogger);
        vm.expectRevert(Hook.NothingToTake.selector);
        hook.takeFees();
    }

    function test_AccountGetsEscrowedShareOnceSetAndDirectShareAfter() public {
        _swap(true, -100e6);

        _setAccount(HANDLE_ID, blogger);

        assertEq(hook.escrowedFees(token), 0);
        assertEq(hook.fees(blogger), 7e6 + 3.5e6 + 0.35e6);

        _swap(true, -100e6);

        assertEq(hook.escrowedFees(token), 0);
        assertEq(_take(blogger), 7e6 + 3.5e6 + 0.35e6 + 0.35e6);
    }

    function test_OwnLaunchGivesCreatorAndAccountSharesToOwner() public {
        _trade(_launchOwn(blogger));
        _swap(true, -100e6);

        assertEq(hook.escrowedFees(token), 0);
        assertEq(_take(blogger), 0.7e6);
    }

    function test_OwnLaunchRefundsBidInsteadOfSplittingIt() public {
        _startAuction("Own", "own");
        uint256 treasuryFeesBefore = hook.treasuryFees();
        uint256 balanceBefore = usd.balanceOf(address(this));

        _trade(_launchOwn(blogger));

        assertEq(usd.balanceOf(address(this)), balanceBefore + BID);
        assertEq(hook.treasuryFees(), treasuryFeesBefore);
        assertEq(hook.fees(blogger), 0);
        assertEq(hook.escrowedFees(token), 0);
        assertEq(usd.balanceOf(address(launchpad)), 0);
    }

    function test_TreasuryTakesFeesOfAllTokensAtOnce() public {
        _trade(_launchOwn(blogger));
        _swap(true, -100e6);

        assertEq(_take(treasury), 3e6 + 3e6 + 0.3e6);
    }

    function test_RevertWhen_AccountProofIsForAnotherAddress() public {
        bytes memory proof = _accountProof(HANDLE_ID, blogger);

        vm.expectRevert(Proofs.InvalidProof.selector);
        launchpad.setAccount(HANDLE_ID, block.timestamp, proof);
    }

    function test_RevertWhen_AccountProofIsExpired() public {
        bytes memory proof = _accountProof(HANDLE_ID, blogger);
        uint256 proofDeadline = block.timestamp;
        skip(1);

        vm.prank(blogger);
        vm.expectRevert(Proofs.ProofExpired.selector);
        launchpad.setAccount(HANDLE_ID, proofDeadline, proof);
    }

    function test_RevertWhen_AccountSetBeforeLaunch() public {
        bytes memory proof = _accountProof(OWN_HANDLE_ID, blogger);

        vm.prank(blogger);
        vm.expectRevert(Launchpad.NotLaunched.selector);
        launchpad.setAccount(OWN_HANDLE_ID, block.timestamp, proof);
    }

    function test_RevertWhen_AccountAlreadySet() public {
        _setAccount(HANDLE_ID, blogger);
        bytes memory proof = _accountProof(HANDLE_ID, address(this));

        vm.expectRevert(Hook.AccountAlreadySet.selector);
        launchpad.setAccount(HANDLE_ID, block.timestamp, proof);
    }

    function test_RevertWhen_AccountSetForOwnLaunch() public {
        _launchOwn(blogger);
        bytes memory proof = _accountProof(OWN_HANDLE_ID, address(this));

        vm.expectRevert(Hook.AccountAlreadySet.selector);
        launchpad.setAccount(OWN_HANDLE_ID, block.timestamp, proof);
    }

    function _take(address recipient) internal returns (uint256 received) {
        uint256 balanceBefore = usd.balanceOf(recipient);
        vm.prank(recipient);
        uint256 taken = hook.takeFees();
        received = usd.balanceOf(recipient) - balanceBefore;
        assertEq(taken, received);
    }
}
