// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {Range, RebalanceIntent, IMandate} from "../../src/interfaces/IMandate.sol";
import {IntentVerifier} from "../../src/IntentVerifier.sol";

contract IntentVerifierHarness is IntentVerifier {
    function useIntent(RebalanceIntent memory intent, bytes memory sig) external {
        _useIntent(intent, sig);
    }
}

/// @dev Smart-wallet curator: accepts signatures from its owner key.
contract MockWallet is IERC1271 {
    address public immutable owner;

    constructor(address _owner) {
        owner = _owner;
    }

    function isValidSignature(bytes32 hash, bytes memory sig) external view returns (bytes4) {
        (address rec, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, sig);
        return err == ECDSA.RecoverError.NoError && rec == owner ? IERC1271.isValidSignature.selector : bytes4(0);
    }
}

contract IntentVerifierTest is Test {
    IntentVerifierHarness v;
    uint256 curatorPk = 0xC0FFEE;
    address curator;

    uint256 constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    function setUp() public {
        v = new IntentVerifierHarness();
        curator = vm.addr(curatorPk);
        vm.warp(1_000_000);
    }

    function _intent(address who, uint256 nonce) internal view returns (RebalanceIntent memory i) {
        i.poolId = keccak256("pool");
        i.curator = who;
        i.ranges = new Range[](2);
        i.ranges[0] = Range(-600, 600, 6_000);
        i.ranges[1] = Range(-1200, 1200, 4_000);
        i.nonce = nonce;
        i.deadline = block.timestamp + 1 hours;
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, vv);
    }

    // ---------------------------------------------------------------- encoding

    function test_digest_matchesManualEip712() public view {
        RebalanceIntent memory i = _intent(curator, 0);
        bytes32 rangeTh = keccak256("Range(int24 tickLower,int24 tickUpper,uint16 weightBps)");
        bytes32 rangesHash = keccak256(
            abi.encodePacked(
                keccak256(abi.encode(rangeTh, int24(-600), int24(600), uint16(6_000))),
                keccak256(abi.encode(rangeTh, int24(-1200), int24(1200), uint16(4_000)))
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "RebalanceIntent(bytes32 poolId,address curator,Range[] ranges,uint256 nonce,uint256 deadline)Range(int24 tickLower,int24 tickUpper,uint16 weightBps)"
                ),
                i.poolId,
                i.curator,
                rangesHash,
                i.nonce,
                i.deadline
            )
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Bridle"),
                keccak256("1"),
                block.chainid,
                address(v)
            )
        );
        assertEq(v.hashIntent(i), keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
    }

    // ---------------------------------------------------------------- EOA happy path + nonce

    function test_validSignature_consumesNonce() public {
        RebalanceIntent memory i = _intent(curator, 0);
        v.useIntent(i, _sign(curatorPk, v.hashIntent(i)));
        assertEq(v.nonces(curator), 1);
    }

    function test_revert_replay() public {
        RebalanceIntent memory i = _intent(curator, 0);
        bytes memory sig = _sign(curatorPk, v.hashIntent(i));
        v.useIntent(i, sig);
        vm.expectRevert(IMandate.BadNonce.selector);
        v.useIntent(i, sig);
    }

    function test_revert_futureNonce() public {
        RebalanceIntent memory i = _intent(curator, 1);
        bytes memory sig = _sign(curatorPk, v.hashIntent(i));
        vm.expectRevert(IMandate.BadNonce.selector);
        v.useIntent(i, sig);
    }

    function test_noncesArePerCurator() public {
        uint256 otherPk = 0xBEEF;
        address other = vm.addr(otherPk);
        RebalanceIntent memory a = _intent(curator, 0);
        v.useIntent(a, _sign(curatorPk, v.hashIntent(a)));
        RebalanceIntent memory b = _intent(other, 0);
        v.useIntent(b, _sign(otherPk, v.hashIntent(b)));
        assertEq(v.nonces(curator), 1);
        assertEq(v.nonces(other), 1);
    }

    // ---------------------------------------------------------------- deadline

    function test_deadline_inclusive() public {
        RebalanceIntent memory i = _intent(curator, 0);
        i.deadline = block.timestamp;
        v.useIntent(i, _sign(curatorPk, v.hashIntent(i)));
    }

    function test_revert_expired() public {
        RebalanceIntent memory i = _intent(curator, 0);
        bytes memory sig = _sign(curatorPk, v.hashIntent(i));
        vm.warp(i.deadline + 1);
        vm.expectRevert(IMandate.IntentExpired.selector);
        v.useIntent(i, sig);
    }

    // ---------------------------------------------------------------- domain binding

    function test_revert_otherChainId() public {
        RebalanceIntent memory i = _intent(curator, 0);
        bytes memory sig = _sign(curatorPk, v.hashIntent(i));
        vm.chainId(block.chainid + 1);
        vm.expectRevert(IMandate.BadSignature.selector);
        v.useIntent(i, sig);
    }

    function test_revert_otherVerifyingContract() public {
        IntentVerifierHarness other = new IntentVerifierHarness();
        RebalanceIntent memory i = _intent(curator, 0);
        bytes memory sig = _sign(curatorPk, other.hashIntent(i));
        vm.expectRevert(IMandate.BadSignature.selector);
        v.useIntent(i, sig);
    }

    // ---------------------------------------------------------------- tampering / wrong signer

    function test_revert_wrongSigner() public {
        RebalanceIntent memory i = _intent(curator, 0);
        bytes memory sig = _sign(0xBAD, v.hashIntent(i));
        vm.expectRevert(IMandate.BadSignature.selector);
        v.useIntent(i, sig);
    }

    function test_revert_tamperedWeight() public {
        RebalanceIntent memory i = _intent(curator, 0);
        bytes memory sig = _sign(curatorPk, v.hashIntent(i));
        i.ranges[0].weightBps = 4_000;
        i.ranges[1].weightBps = 6_000;
        vm.expectRevert(IMandate.BadSignature.selector);
        v.useIntent(i, sig);
    }

    function test_revert_reorderedRanges() public {
        RebalanceIntent memory i = _intent(curator, 0);
        bytes memory sig = _sign(curatorPk, v.hashIntent(i));
        (i.ranges[0], i.ranges[1]) = (i.ranges[1], i.ranges[0]);
        vm.expectRevert(IMandate.BadSignature.selector);
        v.useIntent(i, sig);
    }

    function test_revert_tamperedPool() public {
        RebalanceIntent memory i = _intent(curator, 0);
        bytes memory sig = _sign(curatorPk, v.hashIntent(i));
        i.poolId = keccak256("other pool");
        vm.expectRevert(IMandate.BadSignature.selector);
        v.useIntent(i, sig);
    }

    function test_revert_malleableHighS() public {
        RebalanceIntent memory i = _intent(curator, 0);
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(curatorPk, v.hashIntent(i));
        bytes memory flipped = abi.encodePacked(r, bytes32(SECP256K1_N - uint256(s)), vv == 27 ? uint8(28) : uint8(27));
        vm.expectRevert(IMandate.BadSignature.selector);
        v.useIntent(i, flipped);
    }

    function test_revert_garbageSignature() public {
        RebalanceIntent memory i = _intent(curator, 0);
        vm.expectRevert(IMandate.BadSignature.selector);
        v.useIntent(i, hex"1234");
    }

    function test_revert_zeroCurator() public {
        RebalanceIntent memory i = _intent(address(0), 0);
        vm.expectRevert(IMandate.BadSignature.selector);
        v.useIntent(i, new bytes(65));
    }

    // ---------------------------------------------------------------- ERC-1271 contract curator

    function test_erc1271_valid() public {
        MockWallet w = new MockWallet(curator);
        RebalanceIntent memory i = _intent(address(w), 0);
        v.useIntent(i, _sign(curatorPk, v.hashIntent(i)));
        assertEq(v.nonces(address(w)), 1);
    }

    function test_erc1271_revert_walletRejects() public {
        MockWallet w = new MockWallet(curator);
        RebalanceIntent memory i = _intent(address(w), 0);
        bytes memory sig = _sign(0xBAD, v.hashIntent(i));
        vm.expectRevert(IMandate.BadSignature.selector);
        v.useIntent(i, sig);
    }

    function test_erc1271_revert_nonWalletContract() public {
        // a contract without isValidSignature cannot be a curator
        RebalanceIntent memory i = _intent(address(v), 0);
        bytes memory sig = _sign(curatorPk, v.hashIntent(i));
        vm.expectRevert(IMandate.BadSignature.selector);
        v.useIntent(i, sig);
    }
}
