// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    HookTestBase,
    Vm,
    LPDonateHook,
    IPoolManager,
    IHooks,
    PoolKey,
    PoolId,
    Currency,
    BalanceDelta,
    toBalanceDelta,
    SwapParams,
    ModifyLiquidityParams,
    StateLibrary,
    TickMath
} from "./helpers/HookTestBase.sol";
import {HookMiner} from "./helpers/HookMiner.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

contract LPDonateHookTest is HookTestBase {
    using StateLibrary for IPoolManager;

    function test_exactPermissionsAndImmutableManager() public view {
        Hooks.Permissions memory expected;
        expected.afterSwap = true;
        expected.afterSwapReturnDelta = true;
        assertEq(abi.encode(hook.getHookPermissions()), abi.encode(expected));
        assertEq(uint160(address(hook)) & 0x3fff, 0x44);
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.DONATION_BPS(), 50);
        assertEq(hook.BPS_DENOMINATOR(), 10000);
    }

    function test_constructorRejectsMissingPermissionBit() public {
        _invalidAddress(0x40);
    }

    function test_constructorRejectsExtraPermissionBit() public {
        _invalidAddress(0x2044);
    }

    function _invalidAddress(uint160 flags) internal {
        (bytes32 salt, address predicted) = HookMiner.find(address(this), manager, flags);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new LPDonateHook{salt: salt}(manager);
    }

    function test_everyCallbackRejectsNonManager() public {
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(-60, 60, 1 ether, 0);
        SwapParams memory swap = SwapParams(true, -1 ether, Q96 / 2);
        bytes[10] memory calls = [
            abi.encodeCall(IHooks.beforeInitialize, (address(this), key, Q96)),
            abi.encodeCall(IHooks.afterInitialize, (address(this), key, Q96, 0)),
            abi.encodeCall(IHooks.beforeAddLiquidity, (address(this), key, lp, "")),
            abi.encodeCall(
                IHooks.afterAddLiquidity,
                (address(this), key, lp, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "")
            ),
            abi.encodeCall(IHooks.beforeRemoveLiquidity, (address(this), key, lp, "")),
            abi.encodeCall(
                IHooks.afterRemoveLiquidity,
                (address(this), key, lp, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "")
            ),
            abi.encodeCall(IHooks.beforeSwap, (address(this), key, swap, "")),
            abi.encodeCall(
                IHooks.afterSwap, (address(this), key, swap, toBalanceDelta(-1 ether, 1 ether), "")
            ),
            abi.encodeCall(IHooks.beforeDonate, (address(this), key, 1, 1, "")),
            abi.encodeCall(IHooks.afterDonate, (address(this), key, 1, 1, ""))
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory reason) = address(hook).call(calls[i]);
            assertFalse(ok);
            assertEq(reason, abi.encodeWithSelector(LPDonateHook.OnlyPoolManager.selector));
        }
        _assertEmptyHook(key);
    }

    function test_exactInBuyDonatesToken() public {
        _checkSwap(true, -1 ether, false);
    }

    function test_exactInSellDonatesETH() public {
        _checkSwap(false, -1 ether, true);
    }

    function test_exactOutBuyDonatesETH() public {
        _checkSwap(true, 1 ether, true);
    }

    function test_exactOutSellDonatesToken() public {
        _checkSwap(false, 1 ether, false);
    }

    function test_roundingImmediatelyBelowAndAtOneUnitDonation() public {
        // At price 1 with 3000 ppm LP fees, these tiny exact-out swaps need 199 and 200 input units.
        _checkSwap(true, 197, true);
        assertEq(hook.totalDonated(key.toId(), key.currency0), 0);
        _newKey(3001);
        _checkSwap(true, 198, true);
        assertEq(hook.totalDonated(key.toId(), key.currency0), 1);
    }

    function test_priceLimitedPartialFillsChargeActualUnspecifiedLeg() public {
        for (uint24 i; i < 4; ++i) {
            if (i > 0) _newKey(3000 + i);
            PoolKey memory referenceKey = key;
            referenceKey.hooks = IHooks(address(0));
            manager.initialize(referenceKey, Q96);
            _liquidity(referenceKey, -600, 600, int256(uint256(LIQUIDITY)), 0);
            bool buy = i < 2;
            bool exactInput = i % 2 == 0;
            SwapParams memory params = SwapParams(
                buy,
                exactInput ? -int256(1000 ether) : int256(1000 ether),
                TickMath.getSqrtPriceAtTick(buy ? int24(-60) : int24(60))
            );
            BalanceDelta actual = _limitedSwap(key, params);
            BalanceDelta raw = _limitedSwap(referenceKey, params);
            bool donateETH = exactInput ? !buy : buy;
            int256 leg = donateETH ? int256(raw.amount0()) : int256(raw.amount1());
            uint256 fee = uint256(leg < 0 ? -leg : leg) / 200;
            assertEq(int256(actual.amount0()), int256(raw.amount0()) - (donateETH ? int256(fee) : int256(0)));
            assertEq(int256(actual.amount1()), int256(raw.amount1()) - (donateETH ? int256(0) : int256(fee)));
            assertLt(uint256(raw.amount0() < 0 ? -int256(raw.amount0()) : int256(raw.amount0())), 1000 ether);
            assertEq(hook.totalDonated(key.toId(), donateETH ? key.currency0 : key.currency1), fee);
            assertEq(manager.getLiquidity(key.toId()), LIQUIDITY);
            _assertGrowth(referenceKey, donateETH, fee);
            _assertEmptyHook(key);
        }
    }

    function _limitedSwap(PoolKey memory pool, SwapParams memory params) internal returns (BalanceDelta) {
        return router.swap{value: params.zeroForOne ? 1000 ether : 0}(
            pool, params, PoolSwapTest.TestSettings(false, false), ""
        );
    }

    function test_failedRouterPaymentRollsBackDonationAndPrice() public {
        (uint160 beforePrice,,,) = manager.getSlot0(key.toId());
        vm.expectRevert();
        router.swap(key, SwapParams(true, -1 ether, Q96 / 2), PoolSwapTest.TestSettings(false, false), "");
        (uint160 afterPrice,,,) = manager.getSlot0(key.toId());
        assertEq(beforePrice, afterPrice);
        assertEq(hook.totalDonated(key.toId(), key.currency0), 0);
        assertEq(hook.totalDonated(key.toId(), key.currency1), 0);
        _assertEmptyHook(key);
    }

    function test_arbitraryHookDataAndSenderDoNotChangeDonation() public {
        uint256 snapshot = vm.snapshotState();
        BalanceDelta emptyData = _swap(key, true, -1 ether);
        uint256 expected = hook.totalDonated(key.toId(), key.currency1);
        assertTrue(vm.revertToState(snapshot));
        PoolSwapTest otherRouter = new PoolSwapTest(manager);
        BalanceDelta arbitraryData = otherRouter.swap{value: 1 ether}(
            key,
            SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            hex"badbadba"
        );
        assertEq(BalanceDelta.unwrap(emptyData), BalanceDelta.unwrap(arbitraryData));
        assertEq(hook.totalDonated(key.toId(), key.currency1), expected);
        _assertEmptyHook(key);
    }

    function test_runtimeContainsNoEscapeHatchesAndFitsEIP170() public view {
        _scan(address(hook).code);
        _scan(address(token).code);
    }

    function _scan(bytes memory code) internal pure {
        assertGt(code.length, 0);
        assertLe(code.length, 24576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xff && op != 0xf4 && op != 0xf2, "escape hatch opcode");
        }
    }

    function testFuzz_allModes(uint96 size, bool buy, bool exactInput) public {
        int256 amount = int256(bound(uint256(size), 1, 20 ether));
        // On a buy the input is ETH; on a sell the output is ETH.
        bool donateETH = exactInput ? !buy : buy;
        _checkSwap(buy, exactInput ? -amount : amount, donateETH);
    }

    function test_dustAllFourModes() public {
        // Separate fee tiers make each comparison start at an identical fresh price.
        _checkSwap(true, -100, false);
        _newKey(500);
        _checkSwap(false, -100, true);
        _newKey(1000);
        _checkSwap(true, 100, true);
        _newKey(10000);
        _checkSwap(false, 100, false);
    }

    function _newKey(uint24 fee) internal {
        key.fee = fee;
        manager.initialize(key, Q96);
        _liquidity(key, -600, 600, int256(uint256(LIQUIDITY)), 0);
    }

    function _checkSwap(bool buy, int256 amount, bool donateETH) internal {
        PoolKey memory referenceKey = key;
        referenceKey.hooks = IHooks(address(0));
        manager.initialize(referenceKey, Q96);
        _liquidity(referenceKey, -600, 600, int256(uint256(LIQUIDITY)), 0);

        vm.recordLogs();
        BalanceDelta actual = _swap(key, buy, amount);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        BalanceDelta raw = _rawDelta(logs, key.toId());
        BalanceDelta referenceDelta = _swap(referenceKey, buy, amount);
        assertEq(BalanceDelta.unwrap(raw), BalanceDelta.unwrap(referenceDelta), "core execution changed");
        int256 leg = donateETH ? int256(raw.amount0()) : int256(raw.amount1());
        uint256 fee = uint256(leg < 0 ? -leg : leg) / 200;
        assertEq(int256(actual.amount0()), int256(raw.amount0()) - (donateETH ? int256(fee) : int256(0)));
        assertEq(int256(actual.amount1()), int256(raw.amount1()) - (donateETH ? int256(0) : int256(fee)));
        Currency currency = donateETH ? key.currency0 : key.currency1;
        assertEq(hook.totalDonated(key.toId(), currency), fee);
        assertEq(hook.totalDonated(key.toId(), donateETH ? key.currency1 : key.currency0), 0);
        assertEq(_donationEvents(logs, key.toId(), currency, fee), fee == 0 ? 0 : 1);
        _assertGrowth(referenceKey, donateETH, fee);
        _assertEmptyHook(key);
    }

    function _assertGrowth(PoolKey memory referenceKey, bool donateETH, uint256 fee) internal view {
        (uint256 g0, uint256 g1) = manager.getFeeGrowthGlobals(key.toId());
        (uint256 r0, uint256 r1) = manager.getFeeGrowthGlobals(referenceKey.toId());
        uint256 growth = fee * (1 << 128) / LIQUIDITY;
        assertEq(g0 - r0, donateETH ? growth : 0, "donation must accrue to LPs in currency0");
        assertEq(g1 - r1, donateETH ? 0 : growth, "donation must accrue to LPs in currency1");
    }

    function testFuzz_swapEndingWithZeroLiquiditySkipsDonation(bool buy, bool exactInput) public {
        vm.recordLogs();
        // Beyond the entire funded range, this is partially filled and finishes with no active LP.
        BalanceDelta actual = _swap(key, buy, exactInput ? -int256(1000 ether) : int256(1000 ether));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(manager.getLiquidity(key.toId()), 0);
        assertEq(BalanceDelta.unwrap(actual), BalanceDelta.unwrap(_rawDelta(logs, key.toId())));
        assertTrue(actual.amount0() != 0 && actual.amount1() != 0);
        assertEq(hook.totalDonated(key.toId(), key.currency0), 0);
        assertEq(hook.totalDonated(key.toId(), key.currency1), 0);
        assertEq(_donationEvents(logs, key.toId(), key.currency0, 0), 0);
        _assertEmptyHook(key);
    }

    function test_entirelyEmptyPoolSwapDoesNotCharge() public {
        key.fee = 500;
        manager.initialize(key, Q96);
        BalanceDelta delta = _swap(key, true, -1 ether);
        assertEq(BalanceDelta.unwrap(delta), 0);
        assertEq(hook.totalDonated(key.toId(), key.currency1), 0);
        _assertEmptyHook(key);
    }

    function test_nonETHPoolHasNoDonationOrOtherEffect() public {
        MockERC20 other = new MockERC20("Other", "OTHER", 1_000_000 ether);
        other.approve(address(router), type(uint256).max);
        other.approve(address(liquidityRouter), type(uint256).max);
        (address a, address b) = address(token) < address(other)
            ? (address(token), address(other))
            : (address(other), address(token));
        key = PoolKey(Currency.wrap(a), Currency.wrap(b), 3000, 60, IHooks(hook));
        manager.initialize(key, Q96);
        _liquidity(key, -600, 600, int256(uint256(LIQUIDITY)), 0);
        for (uint256 i; i < 4; ++i) {
            vm.recordLogs();
            BalanceDelta actual = _swap(key, i < 2, i % 2 == 0 ? -int256(1 ether) : int256(1 ether));
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertEq(BalanceDelta.unwrap(actual), BalanceDelta.unwrap(_rawDelta(logs, key.toId())));
            assertEq(_donationEvents(logs, key.toId(), key.currency0, 0), 0);
            _assertEmptyHook(key);
        }
        assertEq(hook.totalDonated(key.toId(), key.currency0), 0);
        assertEq(hook.totalDonated(key.toId(), key.currency1), 0);
    }

    function test_lifetimeTotalsAreSeparatedByPoolId() public {
        _swap(key, true, -1 ether);
        _swap(key, false, -1 ether);
        PoolId first = key.toId();
        uint256 a = hook.totalDonated(first, key.currency0);
        uint256 b = hook.totalDonated(first, key.currency1);
        assertGt(a, 0);
        assertGt(b, 0);
        _newKey(500);
        _swap(key, true, -2 ether);
        assertEq(hook.totalDonated(first, key.currency0), a);
        assertEq(hook.totalDonated(first, key.currency1), b);
        assertEq(hook.totalDonated(key.toId(), key.currency0), 0);
        assertGt(hook.totalDonated(key.toId(), key.currency1), b);
        _assertEmptyHook(key);
    }

    function test_sameBlockJITLiquiditySharesDonationAndOutOfRangeDoesNot() public {
        uint256 initialBlock = block.number;
        _liquidity(key, -60, 60, int256(uint256(LIQUIDITY)), bytes32("jit"));
        _liquidity(key, 600, 660, int256(uint256(LIQUIDITY)), bytes32("outside"));
        _swap(key, true, -1 ether);
        uint256 donation = hook.totalDonated(key.toId(), key.currency1);
        BalanceDelta jitFees = _liquidity(key, -60, 60, 0, bytes32("jit"));
        BalanceDelta outsideFees = _liquidity(key, 600, 660, 0, bytes32("outside"));
        assertGt(jitFees.amount1(), 0);
        assertApproxEqAbs(uint256(uint128(jitFees.amount1())), donation / 2, 1);
        assertEq(BalanceDelta.unwrap(outsideFees), 0);
        assertEq(block.number, initialBlock);
        _assertEmptyHook(key);
    }

    function test_exactOutSignedDeltaBoundaryWaivesDonation() public {
        // Synthetic boundary input isolates a representational limit unreachable with RBTE's supply.
        SwapParams memory params = SwapParams(true, 1, Q96 / 2);
        vm.prank(address(manager));
        (bytes4 selector, int128 fee) =
            hook.afterSwap(address(router), key, params, toBalanceDelta(type(int128).min, 1), "");
        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(fee, 0);
        assertEq(hook.totalDonated(key.toId(), key.currency0), 0);
        _assertEmptyHook(key);
    }
}
