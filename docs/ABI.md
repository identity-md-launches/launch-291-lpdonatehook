# ABI integration

The JSON arrays at `docs/abi/RBTE.json` and `docs/abi/LPDonateHook.json` are compiler-exported ABIs from the pinned Solidity 0.8.26 build. ABI user-defined types are encoded as their underlying types: `PoolId` is `bytes32`, `Currency` is `address`, and `BalanceDelta` is a packed `int256`.

## RBTE

Constructor: `constructor()`, not payable. Standard ERC-20 functions: `name`, `symbol`, `decimals`, `totalSupply`, `balanceOf`, `allowance`, `approve`, `transfer`, and `transferFrom`. Standard `Transfer` and `Approval` events and OpenZeppelin ERC-6093 errors are included. There is no mint, owner, admin, burn, initialization, or upgrade entry point.

## LPDonateHook

Constructor: `constructor(address manager)`, not payable. The address must be the launch network's PoolManager. The creation address must carry exactly the declared permission bits or `Hooks.HookAddressNotValid` reverts.

| Function | Meaning |
| --- | --- |
| `poolManager() -> address` | Immutable authorized v4 manager |
| `DONATION_BPS() -> uint256` | Constant 50 |
| `BPS_DENOMINATOR() -> uint256` | Constant 10000 |
| `getHookPermissions() -> tuple` | Standard 14 v4 bool fields; only afterSwap and afterSwapReturnDelta are true |
| `totalDonated(bytes32 poolId, address currency) -> uint256` | Lifetime successfully donated base units; zero for unseen pools/currencies |

Use the exact v4 pool key to calculate `poolId = keccak256(abi.encode(currency0, currency1, fee, tickSpacing, hook))`. Each field is ABI-encoded to 32 bytes, including signed `int24` tick spacing. ETH is address zero; the token currency is the RBTE deployment address. Both launch currencies have 18 decimals; the hook itself works in base units and never assumes another token's decimals.

```solidity
event Donated(bytes32 indexed poolId, address indexed currency, uint256 amount);
```

The log emitter is the deployed hook. Topic 0 is `keccak256("Donated(bytes32,address,uint256)")`; topic 1 is PoolId, topic 2 is the currency padded to 32 bytes. The data contains a single uint256 amount. Exactly one event is emitted for a positive donation. Skipped and dust donations emit none. Unrelated direct `PoolManager.donate` calls do not increment these totals. An indexer should handle reorgs and deduplicate by transaction hash plus log index. For a 24-hour chart, select logs by their block timestamps, not by a fixed number of blocks.

`afterSwap(address sender, PoolKey key, SwapParams params, int256 delta, bytes hookData)` returns `(bytes4 selector, int128 unspecifiedDelta)`. `delta` packs signed amount0 in its upper 128 bits and signed amount1 in its lower 128 bits. `SwapParams.amountSpecified < 0` means exact input; positive means exact output. The returned selector is `IHooks.afterSwap.selector`. A positive return charges the unspecified leg. This entry point is exclusively for the manager, not a frontend transaction target.

Every `IHooks` callback is present in the ABI and requires the manager. Disabled callbacks revert `CallbackNotEnabled`; unauthorized calls revert `OnlyPoolManager`. Neither direct ETH payments nor unknown selectors are accepted. There is no receive function, payable method, beneficiary registry, withdrawal, or administrative API.

The later frontend should read the pool's price and current in-range liquidity through the verified Sepolia StateView, and use the approved deployed router for swaps. `totalDonated` is a lifetime counter, not an APY or an account balance. Donations per unit of current in-range liquidity are only an **estimate** of recent yield and do not describe a specific position's historical earnings.
