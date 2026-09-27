// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {LaunchFactory} from "./helpers/LaunchFactory.sol";
import {LaunchParameters as P} from "./helpers/LaunchParameters.sol";
import {HookMiner} from "./helpers/HookMiner.sol";
import {RBTE} from "../src/RBTE.sol";
import {LPDonateHook} from "../src/LPDonateHook.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

contract LaunchRehearsalTest is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    IPoolManager internal manager;
    LaunchFactory internal factory;
    RBTE internal token;
    LPDonateHook internal hook;
    PoolKey internal key;
    PoolSwapTest internal router;

    receive() external payable {}

    function setUp() public {
        vm.deal(address(this), 10 ether);
        manager = IPoolManager(address(new PoolManager(address(this))));
        factory = new LaunchFactory(manager);
        (bytes32 salt, address predicted) = HookMiner.find(address(factory), manager, 0x44);
        factory.launch(salt);
        token = factory.token();
        hook = factory.hook();
        assertEq(address(hook), predicted);
        key = PoolKey(
            Currency.wrap(address(0)), Currency.wrap(address(token)), P.FEE, P.TICK_SPACING, IHooks(hook)
        );
        router = new PoolSwapTest(manager);
        token.approve(address(router), type(uint256).max);
    }

    function test_factoryInitializationAndOneSidedSeed() public view {
        assertEq(factory.mintedToFactory(), 1_000_000_000 ether);
        assertEq(factory.seedDelta().amount0(), 0);
        assertLt(factory.seedDelta().amount1(), 0);
        assertEq(address(manager).balance, 0, "factory seed brought ETH");
        assertEq(address(factory).balance, 0);
        assertGt(token.balanceOf(address(manager)), 999_999_999 ether);
        assertEq(token.balanceOf(address(factory)) + token.balanceOf(address(manager)), token.totalSupply());
        (uint160 price, int24 tick,, uint24 fee) = manager.getSlot0(key.toId());
        assertEq(price, P.SQRT_PRICE_X96);
        assertEq(fee, 3000);
        assertGe(tick, P.TICK_UPPER);
        assertEq(manager.getLiquidity(key.toId()), 0, "initial price is above the RBTE-only range");
        _emptyHook();
    }

    function test_firstExactInputBuyIntoETHLessPool() public {
        _firstBuy(true);
    }

    function test_firstExactOutputBuyDonatesETHBeforeRouterFundsPool() public {
        _firstBuy(false);
    }

    function testFuzz_firstBuyAndImmediateSale(uint96 size, bool exactInput) public {
        uint256 amount =
            exactInput ? bound(uint256(size), 1e8, 1 ether) : bound(uint256(size), 1 ether, 50_000_000 ether);
        _firstBuy(exactInput, amount);
    }

    function test_failedFirstBuyLeavesFactorySeedAndDonationsUntouched() public {
        uint256 tokensBefore = token.balanceOf(address(manager));
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(key.toId());
        // afterSwap runs, but the router cannot pay the native input at settlement.
        vm.expectRevert();
        router.swap(
            key,
            SwapParams(true, int256(1_000_000 ether), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        (uint160 price,,,) = manager.getSlot0(key.toId());
        (uint256 after0, uint256 after1) = manager.getFeeGrowthGlobals(key.toId());
        assertEq(price, P.SQRT_PRICE_X96);
        assertEq(manager.getLiquidity(key.toId()), 0);
        assertEq(after0, growth0);
        assertEq(after1, growth1);
        assertEq(token.balanceOf(address(manager)), tokensBefore);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(address(manager).balance, 0);
        assertEq(hook.totalDonated(key.toId(), key.currency0), 0);
        assertEq(hook.totalDonated(key.toId(), key.currency1), 0);
        _emptyHook();
        _firstBuy(false);
    }

    function _firstBuy(bool exactInput) internal {
        _firstBuy(exactInput, exactInput ? 1 ether : 1_000_000 ether);
    }

    function _firstBuy(bool exactInput, uint256 amount) internal {
        assertEq(address(manager).balance, 0);
        assertEq(address(router).balance, 0);
        assertEq(token.balanceOf(address(this)), 0);
        uint256 tokensBefore = token.balanceOf(address(manager));
        vm.recordLogs();
        BalanceDelta delta = router.swap{value: 2 ether}(
            key,
            SwapParams(true, exactInput ? -int256(amount) : int256(amount), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertGt(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(this)), uint256(uint128(delta.amount1())));
        assertEq(token.balanceOf(address(manager)), tokensBefore - token.balanceOf(address(this)));
        assertEq(address(manager).balance, uint256(-int256(delta.amount0())));
        assertEq(manager.getLiquidity(key.toId()), factory.seededLiquidity());
        Currency donated = exactInput ? key.currency1 : key.currency0;
        uint256 donation = hook.totalDonated(key.toId(), donated);
        assertGt(donation, 0);
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(manager)
                    && logs[i].topics[0]
                        == keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)")
            ) {
                (int128 raw0, int128 raw1,,,,) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                assertEq(donation, (exactInput ? uint256(uint128(raw1)) : uint256(-int256(raw0))) / 200);
                ++seen;
            }
        }
        assertEq(seen, 1);
        _emptyHook();

        // The first buyer can sell immediately. Factory seed and first swap did not trap the pool.
        BalanceDelta sale = router.swap(
            key,
            SwapParams(false, -int256(token.balanceOf(address(this)) / 2), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertGt(sale.amount0(), 0);
        _emptyHook();
    }

    function _emptyHook() internal view {
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(manager.balanceOf(address(hook), key.currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }
}
