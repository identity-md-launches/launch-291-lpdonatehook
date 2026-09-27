// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DifferentialHookBase} from "./helpers/DifferentialHookBase.sol";
import {
    IPoolManager,
    PoolKey,
    BalanceDelta,
    SwapParams,
    StateLibrary,
    TickMath,
    PoolSwapTest
} from "./helpers/HookTestBase.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";

contract DonationAccountingTest is DifferentialHookBase {
    using StateLibrary for IPoolManager;

    function test_allModesAtRoundingThresholds() public {
        uint256 snapshot = vm.snapshotState();
        for (uint256 mode; mode < 4; ++mode) {
            bool buy = mode < 2;
            bool exactInput = mode % 2 == 0;
            uint256 thresholds;
            for (uint256 size = 197; size <= 204; ++size) {
                assertTrue(vm.revertToState(snapshot));
                Observation memory o = _checkedSwap(_params(buy, exactInput, size, buy ? -600 : int24(600)));
                int256 leg = o.donateETH ? int256(o.raw.amount0()) : int256(o.raw.amount1());
                uint256 magnitude = uint256(leg < 0 ? -leg : leg);
                if (magnitude >= 199 && magnitude <= 201) thresholds |= 1 << (magnitude - 199);
                assertEq(o.donation, magnitude < 200 ? 0 : 1);
            }
            assertEq(thresholds, 7, "exercise unspecified amounts 199, 200 and 201 in every mode");
            assertTrue(vm.revertToState(snapshot));
            Observation memory dust = _checkedSwap(_params(buy, exactInput, 1, buy ? -600 : int24(600)));
            assertEq(dust.donation, 0);
        }
    }

    function test_crossingRangeDonatesOnlyToPostSwapLPsAllModes() public {
        _bothLiquidity(-60, 60, int256(uint256(LIQUIDITY)), bytes32("departing"));
        uint256 snapshot = vm.snapshotState();
        for (uint256 mode; mode < 4; ++mode) {
            assertTrue(vm.revertToState(snapshot));
            bool buy = mode < 2;
            assertEq(manager.getLiquidity(key.toId()), 2 * LIQUIDITY);
            Observation memory o =
                _checkedSwap(_params(buy, mode % 2 == 0, 1000 ether, buy ? -120 : int24(120)));
            assertEq(o.liquidity, LIQUIDITY);
            assertGt(o.donation, 0);
            _checkCollectedFees(-60, 60, bytes32("departing"), o.donateETH, 0);
            // All of this swap's donation accrues to the surviving position, even though
            // the departed position earned ordinary trading fees earlier in the swap.
            _checkCollectedFees(-600, 600, 0, o.donateETH, o.donation);
            _assertAccounting();
        }
    }

    function _checkCollectedFees(int24 lower, int24 upper, bytes32 salt, bool donateETH, uint256 donation)
        internal
    {
        BalanceDelta fees = _liquidity(key, lower, upper, 0, salt);
        BalanceDelta baseline = _liquidity(referenceKey, lower, upper, 0, salt);
        int256 extra0 = int256(fees.amount0()) - int256(baseline.amount0());
        int256 extra1 = int256(fees.amount1()) - int256(baseline.amount1());
        // Global growth and position collection each floor. Combined ordinary fee growth
        // can change the final rounding by one unit relative to the reference pool.
        assertEq(donateETH ? extra1 : extra0, 0, "no donation in the other currency");
        assertApproxEqAbs(donateETH ? extra0 : extra1, int256(donation), donation == 0 ? 0 : 1);
    }

    function test_exitAndReenterLiquidityPreservesLifetimeTotalsAllModes() public {
        uint256 snapshot = vm.snapshotState();
        for (uint256 mode; mode < 4; ++mode) {
            assertTrue(vm.revertToState(snapshot));
            bool buy = mode < 2;
            bool exactInput = mode % 2 == 0;
            _checkedSwap(_params(buy, exactInput, 1 ether, buy ? -600 : int24(600)));
            uint256 donatedBefore = expected0 + expected1;
            assertGt(donatedBefore, 0);
            Observation memory exhausted =
                _checkedSwap(_params(buy, exactInput, 1000 ether, buy ? -660 : int24(660)));
            assertEq(exhausted.liquidity, 0);
            assertTrue(exhausted.raw.amount0() != 0 && exhausted.raw.amount1() != 0);
            assertEq(exhausted.donation, 0);
            assertEq(expected0 + expected1, donatedBefore);
            Observation memory recovered = _checkedSwap(_params(!buy, exactInput, 1000 ether, 0));
            assertEq(recovered.liquidity, LIQUIDITY);
            assertGt(recovered.donation, 0);
        }
    }

    function test_tokenSettlementFailureRollsBackFeesAndCanRetry() public {
        for (uint256 mode; mode < 2; ++mode) {
            _checkedSwap(_params(true, true, 1 ether, -600));
            SwapParams memory params = _params(false, mode == 0, 1 ether, 600);
            assertTrue(token.approve(address(router), 0));
            bytes32 beforeState = _stateDigest();
            vm.expectPartialRevert(IERC20Errors.ERC20InsufficientAllowance.selector);
            _execute(key, params);
            assertEq(
                _stateDigest(),
                beforeState,
                "settlement failure must revert donation, growth, price and balances"
            );
            _assertAccounting();
            assertTrue(token.approve(address(router), type(uint256).max));
            assertGt(_checkedSwap(params).donation, 0);
        }
    }

    function test_traderCanTakeAndBurnClaimsWhileHookKeepsNoneAllModes() public {
        assertTrue(manager.setOperator(address(router), true));
        uint256 snapshot = vm.snapshotState();
        for (uint256 mode; mode < 4; ++mode) {
            assertTrue(vm.revertToState(snapshot));
            bool buy = mode < 2;
            Observation memory first = _checkedSwap(
                _params(buy, mode % 2 == 0, 1 ether, buy ? -600 : int24(600)),
                PoolSwapTest.TestSettings(true, false)
            );
            uint256 outputId = buy ? key.currency1.toId() : key.currency0.toId();
            uint256 claims = manager.balanceOf(address(this), outputId);
            assertEq(claims, uint256(int256(buy ? first.actual.amount1() : first.actual.amount0())));
            assertGt(claims, 0);
            // Pay for the reverse trade entirely by burning the trader's output claims.
            _checkedSwap(
                _params(!buy, true, claims / 2, buy ? int24(600) : int24(-600)),
                PoolSwapTest.TestSettings(true, true)
            );
            assertEq(manager.balanceOf(address(this), outputId), claims - claims / 2);
            _assertEmptyHook(key);
        }
    }

    function test_zeroAmountAndWrongPriceLimitLeaveAccountingUnchanged() public {
        _checkedSwap(_params(true, true, 1 ether, -600));
        bytes32 beforeState = _stateDigest();
        (uint160 price,,,) = manager.getSlot0(key.toId());
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        _execute(key, SwapParams(true, 0, TickMath.MIN_SQRT_PRICE + 1));
        assertEq(_stateDigest(), beforeState);
        for (uint256 mode; mode < 4; ++mode) {
            vm.expectRevert(abi.encodeWithSelector(Pool.PriceLimitAlreadyExceeded.selector, price, price));
            _execute(key, SwapParams(mode < 2, mode % 2 == 0 ? -int256(1 ether) : int256(1 ether), price));
            assertEq(_stateDigest(), beforeState);
        }
        _assertAccounting();
    }

    function testFuzz_priceLimitedTradesAcrossRanges(uint96 size, bool buy, bool exactInput, uint16 tickSeed)
        public
    {
        _bothLiquidity(-60, 60, int256(uint256(LIQUIDITY)), bytes32("narrow"));
        int24 distance = int24(int256(bound(uint256(tickSeed), 1, 720)));
        _checkedSwap(
            _params(buy, exactInput, bound(uint256(size), 1, 1000 ether), buy ? -distance : distance)
        );
    }

    function _params(bool buy, bool exactInput, uint256 size, int24 limit)
        internal
        pure
        returns (SwapParams memory)
    {
        return SwapParams(buy, exactInput ? -int256(size) : int256(size), TickMath.getSqrtPriceAtTick(limit));
    }

    function _stateDigest() internal view returns (bytes32) {
        (uint160 price, int24 tick,,) = manager.getSlot0(key.toId());
        (uint256 g0, uint256 g1) = manager.getFeeGrowthGlobals(key.toId());
        return keccak256(
            abi.encode(
                price,
                tick,
                g0,
                g1,
                manager.getLiquidity(key.toId()),
                hook.totalDonated(key.toId(), key.currency0),
                hook.totalDonated(key.toId(), key.currency1),
                address(this).balance,
                address(manager).balance,
                token.balanceOf(address(this)),
                token.balanceOf(address(manager))
            )
        );
    }
}
