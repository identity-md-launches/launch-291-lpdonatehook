// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {RBTE} from "../../src/RBTE.sol";
import {LPDonateHook} from "../../src/LPDonateHook.sol";
import {HookMiner} from "./HookMiner.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

abstract contract HookTestBase is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    IPoolManager internal manager;
    RBTE internal token;
    LPDonateHook internal hook;
    PoolSwapTest internal router;
    PoolModifyLiquidityTest internal liquidityRouter;
    PoolKey internal key;
    uint160 internal constant Q96 = 1 << 96;
    uint128 internal constant LIQUIDITY = 10_000 ether;
    bytes32 internal constant SWAP_EVENT =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 internal constant DONATED_EVENT = keccak256("Donated(bytes32,address,uint256)");

    receive() external payable {}

    function setUp() public virtual {
        vm.deal(address(this), 1_000_000 ether);
        manager = IPoolManager(address(new PoolManager(address(this))));
        token = new RBTE();
        (bytes32 salt, address predicted) = HookMiner.find(address(this), manager, 0x44);
        hook = new LPDonateHook{salt: salt}(manager);
        assertEq(address(hook), predicted);
        router = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        token.approve(address(router), type(uint256).max);
        token.approve(address(liquidityRouter), type(uint256).max);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(hook));
        manager.initialize(key, Q96);
        _liquidity(key, -600, 600, int256(uint256(LIQUIDITY)), 0);
    }

    function _liquidity(PoolKey memory pool, int24 lower, int24 upper, int256 amount, bytes32 salt)
        internal
        returns (BalanceDelta)
    {
        return liquidityRouter.modifyLiquidity{value: 1000 ether}(
            pool, ModifyLiquidityParams(lower, upper, amount, salt), ""
        );
    }

    function _swap(PoolKey memory pool, bool zeroForOne, int256 amount) internal returns (BalanceDelta) {
        return router.swap{value: zeroForOne && pool.currency0.isAddressZero() ? 1000 ether : 0}(
            pool,
            SwapParams(
                zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function _rawDelta(Vm.Log[] memory logs, PoolId poolId) internal view returns (BalanceDelta) {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_EVENT
                    && logs[i].topics[1] == PoolId.unwrap(poolId)
            ) {
                (int128 a, int128 b,,,,) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return toBalanceDelta(a, b);
            }
        }
        revert("missing core swap event");
    }

    function _donationEvents(Vm.Log[] memory logs, PoolId id, Currency currency, uint256 amount)
        internal
        view
        returns (uint256 count)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == DONATED_EVENT) {
                ++count;
                assertEq(logs[i].topics[1], PoolId.unwrap(id));
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(Currency.unwrap(currency)))));
                assertEq(abi.decode(logs[i].data, (uint256)), amount);
            }
        }
    }

    function _assertEmptyHook(PoolKey memory pool) internal view {
        assertEq(address(hook).balance, 0, "hook ETH");
        assertEq(pool.currency0.balanceOf(address(hook)), 0, "hook currency0");
        assertEq(pool.currency1.balanceOf(address(hook)), 0, "hook currency1");
        assertEq(manager.balanceOf(address(hook), pool.currency0.toId()), 0, "hook claims0");
        assertEq(manager.balanceOf(address(hook), pool.currency1.toId()), 0, "hook claims1");
        assertEq(manager.currencyDelta(address(hook), pool.currency0), 0, "hook delta0");
        assertEq(manager.currencyDelta(address(hook), pool.currency1), 0, "hook delta1");
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
    }
}
