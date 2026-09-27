// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @notice Donates 0.5% of the unspecified swap leg to post-swap, in-range liquidity.
/// @dev Uses only flash accounting: donate's debit cancels the returned positive hook delta.
/// No assets or ERC-6909 claims are taken, minted, transferred or retained by this hook.
contract LPDonateHook is IHooks {
    using StateLibrary for IPoolManager;

    error OnlyPoolManager();
    error CallbackNotEnabled();

    IPoolManager public immutable poolManager;
    uint256 public constant DONATION_BPS = 50;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Lifetime donations in raw currency units, isolated by the complete pool key.
    mapping(PoolId poolId => mapping(Currency currency => uint256 amount)) public totalDonated;

    event Donated(PoolId indexed poolId, Currency indexed currency, uint256 amount);

    constructor(IPoolManager manager) {
        poolManager = manager;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory permissions) {
        permissions.afterSwap = true;
        permissions.afterSwapReturnDelta = true;
    }

    /// @dev `sender` is a router, and hookData is unauthenticated. Neither affects donations.
    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        if (!key.currency0.isAddressZero()) return (IHooks.afterSwap.selector, 0);

        // Exact-in: output. Exact-out: input. This is the same mapping used by v4 Hooks.afterSwap.
        bool unspecifiedIs0 = (params.amountSpecified < 0) != params.zeroForOne;
        int256 unspecified = unspecifiedIs0 ? int256(delta.amount0()) : int256(delta.amount1());
        // Widen before negating, including for int128.min.
        uint256 magnitude = uint256(unspecified < 0 ? -unspecified : unspecified);
        uint256 amount = magnitude * DONATION_BPS / BPS_DENOMINATOR;
        if (amount == 0) return (IHooks.afterSwap.selector, 0);

        // Preserve swap liveness even at v4's signed-delta boundary. Returning this fee would
        // otherwise make Hooks.afterSwap's subtraction overflow for an enormous exact-out input.
        if (unspecified - int256(amount) < type(int128).min) return (IHooks.afterSwap.selector, 0);

        PoolId poolId = key.toId();
        if (poolManager.getLiquidity(poolId) == 0) return (IHooks.afterSwap.selector, 0);

        // donate records -amount against this hook; afterSwap's return records +amount.
        // No take/sync/settle or claims are needed, including on the first buy with zero ETH reserves.
        poolManager.donate(key, unspecifiedIs0 ? amount : 0, unspecifiedIs0 ? 0 : amount, "");

        Currency currency = unspecifiedIs0 ? key.currency0 : key.currency1;
        totalDonated[poolId][currency] += amount;
        emit Donated(poolId, currency, amount);

        // amount <= 2**127 / 200, so the conversion cannot truncate or change sign.
        return (IHooks.afterSwap.selector, int128(int256(amount)));
    }

    // Disabled callbacks still enforce the manager boundary. Their address bits are all unset,
    // so the manager never invokes them during initialization, liquidity changes or donation.
    function beforeInitialize(address, PoolKey calldata, uint160)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert CallbackNotEnabled();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert CallbackNotEnabled();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert CallbackNotEnabled();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        revert CallbackNotEnabled();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert CallbackNotEnabled();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        revert CallbackNotEnabled();
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert CallbackNotEnabled();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert CallbackNotEnabled();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert CallbackNotEnabled();
    }
}
