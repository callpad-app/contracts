// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Auction, Launchpad} from "../src/Launchpad.sol";
import {LaunchFixture} from "./LaunchFixture.sol";

contract LaunchpadTest is LaunchFixture {
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
}
