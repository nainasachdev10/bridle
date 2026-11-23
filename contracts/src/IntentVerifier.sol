// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Range, RebalanceIntent, IMandate} from "./interfaces/IMandate.sol";

/// @notice EIP-712 verification of curator rebalance intents.
/// Domain binds chainId and this contract's address (OZ EIP712 rebuilds the separator if chainId changes).
/// Signatures are checked with ECDSA for EOAs and ERC-1271 for contract curators.
abstract contract IntentVerifier is EIP712 {
    bytes32 public constant RANGE_TYPEHASH = keccak256("Range(int24 tickLower,int24 tickUpper,uint16 weightBps)");
    bytes32 public constant INTENT_TYPEHASH = keccak256(
        "RebalanceIntent(bytes32 poolId,address curator,Range[] ranges,uint256 nonce,uint256 deadline)"
        "Range(int24 tickLower,int24 tickUpper,uint16 weightBps)"
    );

    /// @notice Next nonce each curator must sign.
    mapping(address curator => uint256) public nonces;

    constructor() EIP712("Bridle", "1") {}

    function hashIntent(RebalanceIntent memory intent) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    INTENT_TYPEHASH,
                    intent.poolId,
                    intent.curator,
                    _hashRanges(intent.ranges),
                    intent.nonce,
                    intent.deadline
                )
            )
        );
    }

    /// @dev Checks deadline, nonce and signature, then consumes the nonce.
    function _useIntent(RebalanceIntent memory intent, bytes memory signature) internal {
        if (block.timestamp > intent.deadline) revert IMandate.IntentExpired();
        if (intent.nonce != nonces[intent.curator]) revert IMandate.BadNonce();
        if (!SignatureChecker.isValidSignatureNow(intent.curator, hashIntent(intent), signature)) {
            revert IMandate.BadSignature();
        }
        nonces[intent.curator]++;
    }

    /// @dev EIP-712 array encoding: keccak of the concatenated Range struct hashes.
    function _hashRanges(Range[] memory ranges) private pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](ranges.length);
        for (uint256 i; i < ranges.length; ++i) {
            hashes[i] =
                keccak256(abi.encode(RANGE_TYPEHASH, ranges[i].tickLower, ranges[i].tickUpper, ranges[i].weightBps));
        }
        return keccak256(abi.encodePacked(hashes));
    }
}
