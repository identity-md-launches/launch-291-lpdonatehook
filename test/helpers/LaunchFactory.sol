// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RBTE} from "../../src/RBTE.sol";
import {LPDonateHook} from "../../src/LPDonateHook.sol";
import {LaunchParameters as P} from "./LaunchParameters.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/// @dev A local factory model: CREATE token, CREATE2 hook, initialize, unlock and seed using only RBTE.
/// No privileged runtime substitutions or preminted ETH reserves are used.
contract LaunchFactory is IUnlockCallback {
    IPoolManager public immutable manager;
    RBTE public token;
    LPDonateHook public hook;
    PoolKey public key;
    uint128 public seededLiquidity;
    uint256 public mintedToFactory;
    BalanceDelta public seedDelta;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function launch(bytes32 salt) external {
        require(address(token) == address(0), "already launched");
        token = new RBTE();
        mintedToFactory = token.balanceOf(address(this));
        hook = new LPDonateHook{salt: salt}(manager);
        key = PoolKey(
            Currency.wrap(address(0)), Currency.wrap(address(token)), P.FEE, P.TICK_SPACING, IHooks(hook)
        );
        manager.initialize(key, P.SQRT_PRICE_X96);
        seededLiquidity = uint128(
            FullMath.mulDiv(
                P.SEED_AMOUNT,
                1 << 96,
                TickMath.getSqrtPriceAtTick(P.TICK_UPPER) - TickMath.getSqrtPriceAtTick(P.TICK_LOWER)
            )
        );
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        (BalanceDelta delta,) = manager.modifyLiquidity(
            key, ModifyLiquidityParams(P.TICK_LOWER, P.TICK_UPPER, int256(uint256(seededLiquidity)), 0), ""
        );
        require(delta.amount0() == 0 && delta.amount1() < 0, "seed must be token only");
        seedDelta = delta;
        manager.sync(key.currency1);
        require(token.transfer(address(manager), uint256(-int256(delta.amount1()))));
        manager.settle();
        return "";
    }
}
