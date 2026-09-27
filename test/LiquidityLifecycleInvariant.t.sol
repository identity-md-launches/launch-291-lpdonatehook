// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DifferentialHookBase} from "./helpers/DifferentialHookBase.sol";
import {IPoolManager, SwapParams, StateLibrary, TickMath} from "./helpers/HookTestBase.sol";

/// @dev Runs two synchronized real pools while LPs enter, leave, collect and reenter.
/// Assertions in actions are fatal: the repository enables invariant.fail_on_revert.
contract LiquidityLifecycleHandler is DifferentialHookBase {
    using StateLibrary for IPoolManager;

    uint128 public broadLiquidity = LIQUIDITY;
    uint128 public narrowLiquidity;
    uint256 public zeroLiquiditySwaps;
    uint256 public payingSwaps;
    uint256[4] public modeCalls;

    function swap(uint96 sizeSeed, bool buy, bool exactInput) external {
        uint160 lower = TickMath.getSqrtPriceAtTick(-720);
        uint160 upper = TickMath.getSqrtPriceAtTick(720);
        (uint160 price,,,) = manager.getSlot0(key.toId());
        // At a price limit only the opposite direction is admissible. Empty pools can
        // still move to that limit, allowing later LP additions to restore trading.
        if (price <= lower) buy = false;
        if (price >= upper) buy = true;
        uint256 size = bound(uint256(sizeSeed), 1, 1000 ether);
        Observation memory o =
            _checkedSwap(SwapParams(buy, exactInput ? -int256(size) : int256(size), buy ? lower : upper));
        ++modeCalls[(buy ? 0 : 2) + (exactInput ? 0 : 1)];
        if (o.liquidity == 0) ++zeroLiquiditySwaps;
        if (o.donation > 0) ++payingSwaps;
    }

    function changeLiquidity(uint96 seed, bool narrow) external {
        // Whole liquidity units avoid the upstream test router's assertion that every
        // removal pays a positive amount (a one-wei liquidity removal can round to zero).
        uint128 next = seed % 5 == 0 ? 0 : uint128(bound(uint256(seed), 1, 10_000) * 1 ether);
        uint128 previous = narrow ? narrowLiquidity : broadLiquidity;
        int24 lower = narrow ? int24(-60) : int24(-600);
        int24 upper = narrow ? int24(60) : int24(600);
        bytes32 salt = narrow ? bytes32("narrow") : bytes32(0);
        // Collect first so tiny additions cannot be net-positive withdrawals of past fees.
        if (previous > 0) _bothLiquidity(lower, upper, 0, salt);
        if (next != previous) {
            _bothLiquidity(lower, upper, int256(uint256(next)) - int256(uint256(previous)), salt);
        }
        if (narrow) narrowLiquidity = next;
        else broadLiquidity = next;
    }

    function collect(bool narrow) external {
        if (narrow && narrowLiquidity > 0) _bothLiquidity(-60, 60, 0, bytes32("narrow"));
        if (!narrow && broadLiquidity > 0) _bothLiquidity(-600, 600, 0, 0);
        _assertAccounting();
    }

    function assertAccounting() external view {
        _assertAccounting();
        assertEq(token.balanceOf(address(this)) + token.balanceOf(address(manager)), token.totalSupply());
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(address(this).balance + address(manager).balance, 1_000_000 ether);
        assertEq(address(router).balance, 0);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(address(liquidityRouter).balance, 0);
        assertEq(token.balanceOf(address(liquidityRouter)), 0);
    }
}

contract LiquidityLifecycleInvariantTest is Test {
    LiquidityLifecycleHandler internal handler;

    function setUp() public {
        handler = new LiquidityLifecycleHandler();
        handler.setUp();
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.swap.selector;
        selectors[1] = handler.changeLiquidity.selector;
        selectors[2] = handler.collect.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_donationsGrowLPFeesWithoutCustodyOrAssetLoss() public view {
        handler.assertAccounting();
    }

    function test_handlerExercisesFourModesEmptyPoolAndRestoration() public {
        for (uint256 mode; mode < 4; ++mode) {
            handler.swap(1 ether, mode < 2, mode % 2 == 0);
        }
        assertEq(handler.payingSwaps(), 4);
        handler.changeLiquidity(0, false);
        handler.changeLiquidity(0, true);
        for (uint256 mode; mode < 4; ++mode) {
            handler.swap(1 ether, mode < 2, mode % 2 == 0);
        }
        assertEq(handler.zeroLiquiditySwaps(), 4);
        assertEq(handler.payingSwaps(), 4);
        handler.changeLiquidity(uint96(10_000 ether - 1), false);
        handler.changeLiquidity(uint96(10_000 ether - 1), true);
        for (uint256 mode; mode < 4; ++mode) {
            handler.swap(1 ether, mode < 2, mode % 2 == 0);
        }
        assertGt(handler.payingSwaps(), 4);
        for (uint256 mode; mode < 4; ++mode) {
            assertGt(handler.modeCalls(mode), 0);
        }
        handler.collect(false);
        handler.collect(true);
        handler.assertAccounting();
    }
}
