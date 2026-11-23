// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IMandate, Range, RebalanceIntent} from "../../src/interfaces/IMandate.sol";
import {BridleHook} from "../../src/BridleHook.sol";
import {BridleVault} from "../../src/BridleVault.sol";
import {BridleFixture} from "../utils/BridleFixture.sol";

/// @dev The curator's own posted bond: the vault takes no intents until it covers minBond, and it can only
/// leave after a notice that spans a close.
contract BondTest is BridleFixture {
    PoolId id;
    address alice = makeAddr("alice");

    function setUp() public override {
        super.setUp();
        id = key.toId();
        IERC20 t0 = IERC20(Currency.unwrap(currency0));
        IERC20 t1 = IERC20(Currency.unwrap(currency1));
        t0.transfer(alice, 1e30);
        t1.transfer(alice, 1e30);
        vm.startPrank(alice);
        t0.approve(address(vault), type(uint256).max);
        t1.approve(address(vault), type(uint256).max);
        vault.deposit(100e18, 100e18, 0, alice);
        vm.stopPrank();
    }

    function _signed() internal view returns (RebalanceIntent memory i, bytes memory sig) {
        i = RebalanceIntent({
            poolId: PoolId.unwrap(id),
            curator: curator,
            ranges: oneRange(-600, 600),
            nonce: hook.nonces(curator),
            deadline: block.timestamp + 1 hours
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(curatorPk, hook.hashIntent(i));
        sig = abi.encodePacked(r, s, v);
    }

    function _nextClose() internal {
        vm.warp(block.timestamp + 5 minutes);
        oracle.set(1e8);
        vault.closeEpoch();
    }

    // ================================================================ inactive until bonded

    function test_unbondedVault_takesNoIntents() public {
        assertFalse(vault.isActive());
        (RebalanceIntent memory i, bytes memory sig) = _signed();
        vm.expectRevert(BridleHook.CuratorNotActive.selector);
        hook.queueIntent(i, sig);
    }

    function test_bondedVault_takesIntents() public {
        bondCurator();
        assertTrue(vault.isActive());
        assertEq(vault.postedBond(), MIN_BOND);
        assertEq(vault.balanceOf(address(vault)), MIN_BOND);
        queue(oneRange(-600, 600));
        assertGt(hook.queuedIntent(id).deadline, 0);
    }

    function test_constructor_revert_zeroMinBond() public {
        PoolKey memory other = PoolKey(currency0, currency1, 500, 10, IHooks(address(hook)));
        vm.expectRevert(BridleVault.ZeroMinBond.selector);
        new BridleVault(hook, other, feedConfig(), curator, testMandate(), 0, BASE_CAP, MAX_MULT, "x", "x");
    }

    function test_lockBond_revert_notCurator() public {
        vm.prank(alice);
        vm.expectRevert(IMandate.NotCurator.selector);
        vault.lockBond(1e18);
    }

    function test_lockBond_revert_zero() public {
        vm.prank(curator);
        vm.expectRevert(BridleVault.ZeroShares.selector);
        vault.lockBond(0);
    }

    // ================================================================ unbonding

    function test_unbond_needsACloseInBetween() public {
        bondCurator();
        uint256 free = vault.balanceOf(curator);
        vm.prank(curator);
        vault.requestUnbond(MIN_BOND);
        assertFalse(vault.isActive(), "a pending unbond below minBond deactivates at once");

        vm.prank(curator);
        vm.expectRevert(BridleVault.NoticeNotOver.selector);
        vault.completeUnbond();

        _nextClose(); // the bond was still burnable through this close
        vm.prank(curator);
        vault.completeUnbond();
        assertEq(vault.postedBond(), 0);
        assertEq(vault.balanceOf(curator), free + MIN_BOND);
    }

    function test_unbond_partial_staysActiveAboveMinBond() public {
        bondCurator();
        vm.prank(curator);
        vault.lockBond(0.5e18); // 1.5e18 posted
        vm.prank(curator);
        vault.requestUnbond(0.5e18);
        assertTrue(vault.isActive());
    }

    function test_unbond_revert_moreThanPosted() public {
        bondCurator();
        vm.prank(curator);
        vm.expectRevert(BridleVault.BondTooLarge.selector);
        vault.requestUnbond(MIN_BOND + 1);
    }

    function test_unbond_revert_nothingRequested() public {
        bondCurator();
        vm.prank(curator);
        vm.expectRevert(BridleVault.ZeroShares.selector);
        vault.completeUnbond();
    }

    function test_unbond_revert_notCurator() public {
        bondCurator();
        vm.prank(alice);
        vm.expectRevert(IMandate.NotCurator.selector);
        vault.requestUnbond(1);
    }
}
