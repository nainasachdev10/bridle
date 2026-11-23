// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IMandate, Mandate} from "../../src/interfaces/IMandate.sol";
import {BridleHook} from "../../src/BridleHook.sol";
import {BridleVault} from "../../src/BridleVault.sol";
import {BridleFixture} from "../utils/BridleFixture.sol";

contract AmendmentsTest is BridleFixture {
    PoolId id;
    IERC20 t0;
    IERC20 t1;
    address alice = makeAddr("alice");
    uint256 aliceShares;

    function setUp() public override {
        super.setUp();
        id = key.toId();
        t0 = IERC20(Currency.unwrap(currency0));
        t1 = IERC20(Currency.unwrap(currency1));
        t0.transfer(alice, 1e30);
        t1.transfer(alice, 1e30);
        vm.startPrank(alice);
        t0.approve(address(vault), type(uint256).max);
        t1.approve(address(vault), type(uint256).max);
        (aliceShares,,) = vault.deposit(100e18, 100e18, 0, alice);
        vm.stopPrank();
        bondCurator();
    }

    function _violation(bytes32 term) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IMandate.MandateViolation.selector, term);
    }

    function _propose(Mandate memory m) internal {
        vm.prank(curator);
        vault.proposeAmendment(m);
    }

    /// @dev A stricter minimum width: easy to see enforced after apply.
    function _wider() internal pure returns (Mandate memory m) {
        m = testMandate();
        m.minWidthTicks = 600;
    }

    // ================================================================ propose

    function test_propose_setsPendingAndClock() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit BridleVault.AmendmentProposed(_wider(), uint64(block.timestamp + 10 minutes));
        _propose(_wider());
        assertEq(vault.amendmentApplyAfter(), block.timestamp + 10 minutes);
        (,, uint24 minWidth,,,,,,,,) = vault.pendingMandate();
        assertEq(minWidth, 600);
    }

    function test_propose_revert_notCurator() public {
        vm.prank(alice);
        vm.expectRevert(IMandate.NotCurator.selector);
        vault.proposeAmendment(_wider());
    }

    function test_propose_revert_invalidMandate() public {
        Mandate memory m = testMandate();
        m.maxRanges = 0;
        vm.prank(curator);
        vm.expectRevert(_violation("maxRanges"));
        vault.proposeAmendment(m);
    }

    function test_propose_revert_feeUp() public {
        Mandate memory m = testMandate();
        m.perfFeeBps += 1;
        vm.prank(curator);
        vm.expectRevert(_violation("perfFeeBps"));
        vault.proposeAmendment(m);
    }

    function test_propose_feeDown_ok() public {
        Mandate memory m = testMandate();
        m.perfFeeBps = 500;
        _propose(m);
    }

    /// @dev A losing curator must not be able to move the breach line away from themselves.
    function test_propose_revert_drawdownLooser() public {
        Mandate memory m = testMandate();
        m.maxDrawdownBps += 1;
        vm.prank(curator);
        vm.expectRevert(_violation("maxDrawdownBps"));
        vault.proposeAmendment(m);
    }

    function test_propose_revert_epochLengthChange() public {
        Mandate memory m = testMandate();
        m.epochLength += 1;
        vm.prank(curator);
        vm.expectRevert(_violation("epochLength"));
        vault.proposeAmendment(m);
    }

    function test_propose_revert_shorterDelay() public {
        Mandate memory m = testMandate();
        m.amendmentDelay -= 1;
        vm.prank(curator);
        vm.expectRevert(_violation("amendmentDelay"));
        vault.proposeAmendment(m);
    }

    /// @dev A longer delay in the proposal doesn't shorten anything now: the CURRENT delay applies.
    function test_propose_usesCurrentDelay() public {
        Mandate memory m = testMandate();
        m.amendmentDelay = 1 hours;
        _propose(m);
        assertEq(vault.amendmentApplyAfter(), block.timestamp + 10 minutes);
    }

    function test_propose_replacingRestartsTheClock() public {
        _propose(_wider());
        vm.warp(block.timestamp + 9 minutes);
        _propose(_wider());
        assertEq(vault.amendmentApplyAfter(), block.timestamp + 10 minutes);
    }

    // ================================================================ apply

    function test_apply_revert_beforeDelay() public {
        _propose(_wider());
        vm.warp(block.timestamp + 10 minutes - 1);
        vm.expectRevert(BridleVault.NoAmendmentReady.selector);
        vault.applyAmendment();
    }

    function test_apply_revert_nothingProposed() public {
        vm.expectRevert(BridleVault.NoAmendmentReady.selector);
        vault.applyAmendment();
    }

    function test_apply_atDelay_newTermsEnforced() public {
        queue(oneRange(-120, 120)); // width 240 is fine under the current terms
        _propose(_wider());
        vm.warp(block.timestamp + 10 minutes);
        oracle.set(1e8);
        vault.applyAmendment(); // permissionless

        assertEq(hook.mandateOf(id).minWidthTicks, 600);
        assertEq(vault.amendmentApplyAfter(), 0);
        vm.expectRevert(_violation("minWidthTicks"));
        this.queueExternal(-120, 120);
        queue(oneRange(-600, 600)); // width 1200 passes
    }

    function queueExternal(int24 lo, int24 hi) external {
        queue(oneRange(lo, hi));
    }

    /// @dev The point of the delay: anyone who disagrees leaves in kind before the terms change.
    function test_exitDuringWindow() public {
        _propose(_wider());
        vm.warp(block.timestamp + 5 minutes);
        vm.prank(alice);
        vault.withdraw(aliceShares, 0, 0, alice);
        assertEq(vault.balanceOf(alice), 0);
    }

    // ================================================================ safe mode

    function _idleSafeMode() internal {
        vm.warp(block.timestamp + 14 * 5 minutes); // no rebalance, no intent: liveness
        oracle.set(1e8);
        vault.closeEpoch();
        assertTrue(hook.safeMode(id));
    }

    function test_safeMode_blocksPropose() public {
        _idleSafeMode();
        vm.prank(curator);
        vm.expectRevert(BridleVault.SafeModeOn.selector);
        vault.proposeAmendment(_wider());
    }

    function test_safeMode_blocksApply() public {
        _propose(_wider());
        _idleSafeMode();
        vm.expectRevert(BridleVault.SafeModeOn.selector);
        vault.applyAmendment();
    }

    function test_setMandate_revert_notVault() public {
        vm.expectRevert(BridleHook.NotVault.selector);
        hook.setMandate(id, _wider());
    }

    // ================================================================ capacity

    /// @dev Its own vault with a small cap: 150 shares base, at most 3x.
    function _cappedVault() internal returns (BridleVault v) {
        PoolKey memory k = PoolKey(currency0, currency1, 500, 10, IHooks(address(hook)));
        v = new BridleVault(hook, k, feedConfig(), curator, testMandate(), MIN_BOND, 150e18, 3, "cap", "CAP");
        manager.initialize(k, SQRT_PRICE_1_1);
        vm.startPrank(alice);
        t0.approve(address(v), type(uint256).max);
        t1.approve(address(v), type(uint256).max);
        v.deposit(100e18, 100e18, 0, alice);
        vm.stopPrank();
    }

    function _goodEpoch(BridleVault v) internal {
        vm.warp(block.timestamp + 5 minutes);
        oracle.set(1e8);
        assertGe(v.closeEpoch().ratio, 1e18); // all idle: exactly holding, counts as good
    }

    function test_capacity_revert_aboveBaseCap() public {
        BridleVault v = _cappedVault();
        assertEq(v.capacity(), 150e18);
        vm.prank(alice);
        vm.expectRevert(IMandate.CapacityExceeded.selector);
        v.deposit(60e18, 60e18, 0, alice); // 160 > 150
        vm.prank(alice);
        v.deposit(50e18, 50e18, 0, alice); // exactly 150
    }

    function test_capacity_growsWithGoodEpochs_upToCeiling() public {
        BridleVault v = _cappedVault();
        _goodEpoch(v);
        assertEq(v.capacity(), 300e18);
        vm.prank(alice);
        v.deposit(150e18, 150e18, 0, alice); // 250 <= 300

        for (uint256 i; i < 5; ++i) {
            _goodEpoch(v);
        }
        assertEq(v.goodEpochs(), 6);
        assertEq(v.capacity(), 450e18, "ceiling: 3x");
    }

    function test_capacity_badEpochDoesNotCount() public {
        queue(oneRange(-600, 600));
        hook.executeQueued(id);
        vm.warp(block.timestamp + 5 minutes);
        oracle.set(1.05e8); // impermanent loss: ratio < 1
        assertLt(vault.closeEpoch().ratio, 1e18);
        assertEq(vault.goodEpochs(), 0);
    }

    function test_constructor_revert_zeroCapacity() public {
        PoolKey memory k = PoolKey(currency0, currency1, 500, 10, IHooks(address(hook)));
        vm.expectRevert(BridleVault.BadCapacity.selector);
        new BridleVault(hook, k, feedConfig(), curator, testMandate(), MIN_BOND, 0, 3, "x", "x");
        vm.expectRevert(BridleVault.BadCapacity.selector);
        new BridleVault(hook, k, feedConfig(), curator, testMandate(), MIN_BOND, 1e18, 0, "x", "x");
    }
}
