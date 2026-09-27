// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    HookTestBase,
    Vm,
    IPoolManager,
    IHooks,
    PoolKey,
    PoolId,
    Currency,
    BalanceDelta,
    SwapParams,
    StateLibrary,
    PoolSwapTest
} from "./HookTestBase.sol";

/// @dev The second pool executes the same trades without a hook. Its returned delta and
/// fee growth are independent oracles, including when a trade crosses initialized ticks.
abstract contract DifferentialHookBase is HookTestBase {
    using StateLibrary for IPoolManager;

    PoolKey internal referenceKey;
    uint256 public expected0;
    uint256 public expected1;
    uint256 public donationGrowth0;
    uint256 public donationGrowth1;

    struct Observation {
        BalanceDelta raw;
        BalanceDelta actual;
        uint256 donation;
        bool donateETH;
        uint128 liquidity;
    }

    function setUp() public virtual override {
        super.setUp();
        referenceKey = key;
        referenceKey.hooks = IHooks(address(0));
        manager.initialize(referenceKey, Q96);
        _liquidity(referenceKey, -600, 600, int256(uint256(LIQUIDITY)), 0);
    }

    function _checkedSwap(SwapParams memory params) internal returns (Observation memory o) {
        return _checkedSwap(params, PoolSwapTest.TestSettings(false, false));
    }

    function _checkedSwap(SwapParams memory params, PoolSwapTest.TestSettings memory settings)
        internal
        returns (Observation memory o)
    {
        uint256 ethBefore = _traderAssets(true);
        uint256 tokenBefore = _traderAssets(false);
        vm.recordLogs();
        o.actual = router.swap{value: params.zeroForOne && !settings.settleUsingBurn ? 1000 ether : 0}(
            key, params, settings, ""
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(int256(_traderAssets(true)) - int256(ethBefore), int256(o.actual.amount0()));
        assertEq(int256(_traderAssets(false)) - int256(tokenBefore), int256(o.actual.amount1()));

        o.raw = _execute(referenceKey, params);
        assertEq(BalanceDelta.unwrap(_rawDelta(logs, key.toId())), BalanceDelta.unwrap(o.raw));
        // Explicit mode table: exact-input sells and exact-output buys donate ETH.
        o.donateETH = params.amountSpecified < 0 ? !params.zeroForOne : params.zeroForOne;
        int256 unspecified = o.donateETH ? int256(o.raw.amount0()) : int256(o.raw.amount1());
        o.liquidity = manager.getLiquidity(referenceKey.toId());
        o.donation = o.liquidity == 0 ? 0 : uint256(unspecified < 0 ? -unspecified : unspecified) / 200;
        assertEq(
            int256(o.actual.amount0()),
            int256(o.raw.amount0()) - (o.donateETH ? int256(o.donation) : int256(0))
        );
        assertEq(
            int256(o.actual.amount1()),
            int256(o.raw.amount1()) - (o.donateETH ? int256(0) : int256(o.donation))
        );

        uint256 growth = o.liquidity == 0 ? 0 : o.donation * (1 << 128) / o.liquidity;
        if (o.donateETH) {
            expected0 += o.donation;
            donationGrowth0 += growth;
        } else {
            expected1 += o.donation;
            donationGrowth1 += growth;
        }
        assertEq(
            _donationEvents(logs, key.toId(), o.donateETH ? key.currency0 : key.currency1, o.donation),
            o.donation == 0 ? 0 : 1
        );
        _assertCoreDonation(logs, o);
        _assertAccounting();
    }

    function _traderAssets(bool eth) internal view returns (uint256) {
        Currency currency = eth ? key.currency0 : key.currency1;
        return currency.balanceOf(address(this)) + manager.balanceOf(address(this), currency.toId());
    }

    function _execute(PoolKey memory pool, SwapParams memory params) internal returns (BalanceDelta) {
        return router.swap{value: params.zeroForOne ? 1000 ether : 0}(
            pool, params, PoolSwapTest.TestSettings(false, false), ""
        );
    }

    function _bothLiquidity(int24 lower, int24 upper, int256 amount, bytes32 salt) internal {
        _liquidity(key, lower, upper, amount, salt);
        _liquidity(referenceKey, lower, upper, amount, salt);
        _assertAccounting();
    }

    function _assertCoreDonation(Vm.Log[] memory logs, Observation memory o) internal view {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter != address(manager)
                    || logs[i].topics[0] != keccak256("Donate(bytes32,address,uint256,uint256)")
            ) continue;
            ++count;
            assertEq(logs[i].topics[1], PoolId.unwrap(key.toId()));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(address(hook)))));
            (uint256 amount0, uint256 amount1) = abi.decode(logs[i].data, (uint256, uint256));
            assertEq(amount0, o.donateETH ? o.donation : 0);
            assertEq(amount1, o.donateETH ? 0 : o.donation);
        }
        assertEq(count, o.donation == 0 ? 0 : 1, "exactly one core donation per nonzero hook fee");
    }

    function _assertAccounting() internal view {
        assertEq(hook.totalDonated(key.toId(), key.currency0), expected0);
        assertEq(hook.totalDonated(key.toId(), key.currency1), expected1);
        (uint256 g0, uint256 g1) = manager.getFeeGrowthGlobals(key.toId());
        (uint256 r0, uint256 r1) = manager.getFeeGrowthGlobals(referenceKey.toId());
        assertEq(g0 - r0, donationGrowth0, "ETH donation growth");
        assertEq(g1 - r1, donationGrowth1, "RBTE donation growth");
        (uint160 price, int24 tick,,) = manager.getSlot0(key.toId());
        (uint160 referencePrice, int24 referenceTick,,) = manager.getSlot0(referenceKey.toId());
        assertEq(price, referencePrice);
        assertEq(tick, referenceTick);
        assertEq(manager.getLiquidity(key.toId()), manager.getLiquidity(referenceKey.toId()));
        _assertEmptyHook(key);
    }
}
