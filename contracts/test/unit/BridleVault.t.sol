// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BridleVault} from "../../src/BridleVault.sol";
import {BridleFixture} from "../utils/BridleFixture.sol";

contract BridleVaultTest is BridleFixture {
    IERC20 t0;
    IERC20 t1;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public override {
        super.setUp();
        t0 = IERC20(Currency.unwrap(currency0));
        t1 = IERC20(Currency.unwrap(currency1));
        for (uint256 i; i < 2; ++i) {
            address u = i == 0 ? alice : bob;
            t0.transfer(u, 1e30);
            t1.transfer(u, 1e30);
            vm.startPrank(u);
            t0.approve(address(vault), type(uint256).max);
            t1.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _idle0() internal view returns (uint256 i) {
        (i,,,,,) = hook.poolState(key.toId());
    }

    function _idle1() internal view returns (uint256 i) {
        (, i,,,,) = hook.poolState(key.toId());
    }

    function _deposit(address who, uint256 a0, uint256 a1) internal returns (uint256 shares) {
        vm.prank(who);
        (shares,,) = vault.deposit(a0, a1, 0, who);
    }

    // ---------------------------------------------------------------- first deposit

    function test_firstDeposit_mintsDeadShares() public {
        uint256 shares = _deposit(alice, 4e18, 1e18);
        assertEq(shares, 2e18 - vault.DEAD_SHARES());
        assertEq(vault.balanceOf(0x000000000000000000000000000000000000dEaD), vault.DEAD_SHARES());
        assertEq(vault.totalSupply(), 2e18);
        assertEq(_idle0(), 4e18);
        assertEq(_idle1(), 1e18);
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 4e18); // held as ERC-6909 claims
    }

    function test_firstDeposit_revert_tooSmall() public {
        vm.prank(alice);
        vm.expectRevert(BridleVault.FirstDepositTooSmall.selector);
        vault.deposit(999_999, 1_000_000, 0, alice); // sqrt < 1e6
    }

    function test_firstDeposit_atMinimum() public {
        assertEq(_deposit(alice, 1e6, 1e6), 1e6 - 1_000);
    }

    function test_firstDeposit_revert_oneSided() public {
        vm.prank(alice);
        vm.expectRevert(BridleVault.FirstDepositTooSmall.selector);
        vault.deposit(1e18, 0, 0, alice);
    }

    // ---------------------------------------------------------------- later deposits

    function test_deposit_proRata_pullsOnlyNeeded() public {
        _deposit(alice, 4e18, 1e18);
        uint256 bal0Before = t0.balanceOf(bob);
        uint256 bal1Before = t1.balanceOf(bob);

        vm.prank(bob);
        (uint256 shares, uint256 a0, uint256 a1) = vault.deposit(8e18, 100e18, 0, bob); // token0 binds
        assertEq(shares, 4e18);
        assertEq(a0, 8e18);
        assertEq(a1, 2e18);
        assertEq(bal0Before - t0.balanceOf(bob), 8e18);
        assertEq(bal1Before - t1.balanceOf(bob), 2e18);
    }

    function test_deposit_roundsAgainstDepositor() public {
        _deposit(alice, 3e18 + 1, 1e18 + 7);
        uint256 supply = vault.totalSupply();
        vm.prank(bob);
        (uint256 shares, uint256 a0, uint256 a1) = vault.deposit(1e18, 1e18, 0, bob);
        // amounts paid are at least the pro-rata value of the shares received
        assertGe(a0, Math.mulDiv(shares, _idle0() - a0, supply));
        assertGe(a1, Math.mulDiv(shares, _idle1() - a1, supply));
        assertLe(a0, 1e18);
        assertLe(a1, 1e18);
    }

    function test_deposit_revert_zeroShares() public {
        _deposit(alice, 1e18, 1e18);
        vm.prank(bob);
        vm.expectRevert(BridleVault.ZeroShares.selector);
        vault.deposit(0, 1e18, 0, bob);
    }

    function test_deposit_revert_dustRoundsToZero() public {
        _deposit(alice, 1e24, 1e6);
        vm.prank(bob);
        vm.expectRevert(BridleVault.ZeroShares.selector);
        vault.deposit(1e24, 0, 0, bob); // token1 side can't cover even one share
    }

    function test_deposit_revert_minShares() public {
        _deposit(alice, 1e18, 1e18);
        vm.prank(bob);
        vm.expectRevert(BridleVault.Slippage.selector);
        vault.deposit(1e18, 1e18, 1e18 + 1, bob);
    }

    function test_donation_doesNotMoveSharePrice() public {
        _deposit(alice, 1e18, 1e18);
        t0.transfer(address(vault), 1000e18); // attacker donation
        t1.transfer(address(vault), 1000e18);
        vm.prank(bob);
        (uint256 shares,,) = vault.deposit(1e18, 1e18, 0, bob);
        assertEq(shares, 1e18);
    }

    // ---------------------------------------------------------------- withdraw

    function test_withdraw_proRata() public {
        _deposit(alice, 4e18, 1e18);
        uint256 bobShares = _deposit(bob, 2e18, 0.5e18);

        vm.prank(bob);
        (uint256 a0, uint256 a1) = vault.withdraw(bobShares, 0, 0, bob);
        assertEq(a0, 2e18);
        assertEq(a1, 0.5e18);
        assertEq(vault.balanceOf(bob), 0);
    }

    function test_withdraw_allExceptDead() public {
        uint256 shares = _deposit(alice, 1e18, 1e18);
        vm.prank(alice);
        (uint256 a0, uint256 a1) = vault.withdraw(shares, 0, 0, alice);
        // dead shares keep their slice forever; rounding stays in the vault
        assertEq(a0, 1e18 - 1_000);
        assertEq(a1, 1e18 - 1_000);
        assertEq(_idle0(), 1_000);
        assertEq(vault.totalSupply(), 1_000);
    }

    function test_withdraw_toOtherReceiver() public {
        uint256 shares = _deposit(alice, 1e18, 1e18);
        uint256 before = t0.balanceOf(bob);
        vm.prank(alice);
        vault.withdraw(shares / 2, 0, 0, bob);
        assertGt(t0.balanceOf(bob), before);
    }

    function test_withdraw_revert_zeroShares() public {
        _deposit(alice, 1e18, 1e18);
        vm.prank(alice);
        vm.expectRevert(BridleVault.ZeroShares.selector);
        vault.withdraw(0, 0, 0, alice);
    }

    function test_withdraw_revert_slippage() public {
        uint256 shares = _deposit(alice, 1e18, 1e18);
        vm.prank(alice);
        vm.expectRevert(BridleVault.Slippage.selector);
        vault.withdraw(shares, 1e18, 0, alice);
    }

    function test_withdraw_revert_notOwnShares() public {
        uint256 shares = _deposit(alice, 1e18, 1e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, 0, shares));
        vault.withdraw(shares, 0, 0, bob);
    }

    function test_withdraw_roundsInVaultFavour() public {
        _deposit(alice, 3e18 + 1, 1e18 + 7);
        uint256 bobShares = _deposit(bob, 1e18, 1e18);
        uint256 idle0Before = _idle0();
        uint256 supplyBefore = vault.totalSupply();
        vm.prank(bob);
        (uint256 a0,) = vault.withdraw(bobShares, 0, 0, bob);
        assertLe(a0 * supplyBefore, bobShares * idle0Before);
    }

    // ---------------------------------------------------------------- construction

    function test_revert_nativeCurrency() public {
        PoolKey memory k = PoolKey(Currency.wrap(address(0)), currency1, 500, 10, IHooks(address(hook)));
        vm.expectRevert(BridleVault.NativeCurrencyUnsupported.selector);
        new BridleVault(hook, k, feedConfig(), curator, testMandate(), "x", "x");
    }
}
