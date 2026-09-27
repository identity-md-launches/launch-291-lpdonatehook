// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {
    HookTestBase,
    Vm,
    LPDonateHook,
    IPoolManager,
    PoolKey,
    BalanceDelta,
    SwapParams,
    StateLibrary,
    TickMath,
    PoolSwapTest
} from "./helpers/HookTestBase.sol";

contract SwapHandler is Test {
    using StateLibrary for IPoolManager;
    IPoolManager internal manager;
    PoolSwapTest internal router;
    PoolKey internal key;
    uint256 public expected0;
    uint256 public expected1;
    uint256 public swaps;

    constructor(IPoolManager manager_, PoolSwapTest router_, PoolKey memory key_) {
        manager = manager_;
        router = router_;
        key = key_;
    }

    receive() external payable {}

    function swap(uint96 size, bool buy, bool exactInput) external {
        int256 amount = int256(bound(uint256(size), 1, 1 ether));
        vm.recordLogs();
        BalanceDelta actual = router.swap{value: buy ? 2 ether : 0}(
            key,
            SwapParams(
                buy,
                exactInput ? -amount : amount,
                buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool currency0 = exactInput ? !buy : buy;
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(manager)
                    && logs[i].topics[0]
                        == keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)")
            ) {
                (int128 raw0, int128 raw1,,,,) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                int256 raw = currency0 ? int256(raw0) : int256(raw1);
                uint256 fee = manager.getLiquidity(key.toId()) == 0 ? 0 : uint256(raw < 0 ? -raw : raw) / 200;
                if (currency0) expected0 += fee;
                else expected1 += fee;
                assertEq(int256(actual.amount0()), int256(raw0) - (currency0 ? int256(fee) : int256(0)));
                assertEq(int256(actual.amount1()), int256(raw1) - (currency0 ? int256(0) : int256(fee)));
                ++seen;
            }
        }
        assertEq(seen, 1);
        ++swaps;
    }
}

contract HookInvariantTest is HookTestBase {
    SwapHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new SwapHandler(manager, router, key);
        vm.deal(address(handler), 100_000 ether);
        token.transfer(address(handler), 1_000_000 ether);
        vm.prank(address(handler));
        token.approve(address(router), type(uint256).max);
        targetContract(address(handler));
    }

    function invariant_noCustodyOrUnsettledDeltas() public view {
        _assertEmptyHook(key);
    }

    function invariant_totalsEqualIndependentSwapAccounting() public view {
        assertEq(hook.totalDonated(key.toId(), key.currency0), handler.expected0());
        assertEq(hook.totalDonated(key.toId(), key.currency1), handler.expected1());
    }

    function invariant_tokenAndETHConservation() public view {
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(
            token.balanceOf(address(this)) + token.balanceOf(address(manager))
                + token.balanceOf(address(handler)),
            token.totalSupply()
        );
        assertEq(address(this).balance + address(manager).balance + address(handler).balance, 1_100_000 ether);
    }
}
