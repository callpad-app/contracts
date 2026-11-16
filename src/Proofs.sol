// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

library Proofs {
    bytes32 internal constant START_AUCTION_TYPEHASH =
        keccak256("StartAuction(string name,string symbol,uint256 bid,uint256 proofDeadline)");
    bytes32 internal constant LAUNCH_OWN_TYPEHASH =
        keccak256("LaunchOwn(string name,string symbol,address owner,uint256 proofDeadline)");
    bytes32 internal constant SET_ACCOUNT_TYPEHASH =
        keccak256("SetAccount(bytes32 handleId,address account,uint256 proofDeadline)");

    error InvalidProof();
    error ProofExpired();

    function startAuctionHash(string calldata name, string calldata symbol, uint256 bid, uint256 proofDeadline)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(START_AUCTION_TYPEHASH, keccak256(bytes(name)), keccak256(bytes(symbol)), bid, proofDeadline)
        );
    }

    function launchOwnHash(string calldata name, string calldata symbol, address owner, uint256 proofDeadline)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(LAUNCH_OWN_TYPEHASH, keccak256(bytes(name)), keccak256(bytes(symbol)), owner, proofDeadline)
        );
    }

    function setAccountHash(bytes32 handleId, address account, uint256 proofDeadline) internal pure returns (bytes32) {
        return keccak256(abi.encode(SET_ACCOUNT_TYPEHASH, handleId, account, proofDeadline));
    }

    function verify(address signer, bytes32 digest, uint256 proofDeadline, bytes calldata proof) internal view {
        require(block.timestamp <= proofDeadline, ProofExpired());
        require(SignatureChecker.isValidSignatureNowCalldata(signer, digest, proof), InvalidProof());
    }
}
