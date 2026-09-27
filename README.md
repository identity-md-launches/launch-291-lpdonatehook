# Rebate / LPDonateHook

This is the contract-stage contribution for **lab-lp-donate-hook** on Sepolia (chain ID **11155111**). It delivers the fixed-supply RBTE token, a Uniswap v4 donation hook, offline Foundry tests, and exported ABIs. The separate manifest author owns `launch.json`; services own publication, signed artifact linkage, attestation, admission, deployment, and the later static frontend. This repository does not claim those stages have run.

## Contracts

`src/RBTE.sol` is an OpenZeppelin ERC-20 named **Rebate**, symbol **RBTE**, with **18 decimals**. Its zero-argument constructor mints exactly **1,000,000,000 RBTE** (`1000000000000000000000000000` base units) to `msg.sender`, including when the caller is the launch factory. There is no public mint, burn, owner, admin, transfer tax, pause, upgrade, or configurable behavior. Standard transfers, approvals, finite allowances, and infinite allowances work normally.

`src/LPDonateHook.sol` takes exactly one constructor argument, `IPoolManager manager`. For the approved deployment this is **`0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`**, the Sepolia manager specified by the workflow. There are no owner/token constructor arguments. The immutable manager is injected so local tests can deploy and use a real manager without relocating its runtime code.

The constructor calls `Hooks.validateHookPermissions`. `getHookPermissions()` enables exactly `afterSwap` and `afterSwapReturnDelta`; every other flag is false. The mined address must satisfy:

```text
uint160(hook) & 0x3fff == 0x0044
```

Every callback enforces `msg.sender == poolManager`. Disabled callbacks also reject a manager call with `CallbackNotEnabled`; the real manager does not call these because their permission bits are unset. Consequently factory initialization and one-sided liquidity adds have no hook gate. There is no admin, setter, pause, sweep, upgrade, external oracle, or privileged router. Only the immutable manager is trusted.

## Donation accounting

For native-ETH pools (`currency0 == address(0)`), `afterSwap` calculates `floor(abs(unspecifiedDelta) * 50 / 10_000)` using the **actual core swap delta**, including for partial fills. `50` and `10_000` are source constants. The currency is selected as follows:

| Trade | Specified leg | Donation currency | Effect on trader |
| --- | --- | --- | --- |
| Exact-input buy | ETH input | RBTE output | Receives output minus donation |
| Exact-input sell | RBTE input | ETH output | Receives output minus donation |
| Exact-output buy | RBTE output | ETH input | Pays input plus donation |
| Exact-output sell | ETH output | RBTE input | Pays input plus donation |

The positive returned delta charges the trader. Within that same callback, `PoolManager.donate` records an equal negative delta against the hook, in the same currency:

```text
hook donation debt       -D
hook returned credit     +D
hook net                  0
trader unspecified leg   original - D
LP fee growth            floor(D * 2^128 / postSwapLiquidity)
```

No `take`, token transfer, ETH transfer, `sync`, `settle`, claim mint, or claim burn occurs in the hook. The router settles its adjusted deltas after the swap. Thus even the first exact-output buy can donate ETH before the router pays ETH into the initially ETH-less pool. Successful unlocks leave no hook debt, credit, funds, or claims. The workflow's generic retained-fee/claim-payout language is superseded here by its explicit same-swap LP donation requirement: there is no retained fee or pull payout.

The donation is additional to the pool's ordinary 3000 ppm LP swap fee. For exact-output swaps the base input used to compute the donation already includes the core swap fee. Routers must apply slippage limits to the **final adjusted deltas**: exact-output users need input allowance/funding for the extra donation; exact-input users receive slightly less. Core `Swap` events describe the core delta before the donation. The hook's `Donated` event and the returned swap delta supply the additional accounting.

The hook charges nothing and emits no event when the currency0 is not native ETH, the rounded amount is zero, or **post-swap** in-range liquidity is zero. In particular a swap that crosses the final funded tick completes normally without attempting a donation. Amounts below 200 unspecified base units round to zero.

There is one representational edge exception to the nominal fee: if subtracting the donation would underflow v4's `int128` trader delta on an enormous exact-output input, the hook waives the donation. This gives the explicit no-donation-induced-revert requirement precedence at v4's numerical limit. The test suite covers `int128.min`; the bound is far beyond RBTE's total supply. Absolute values are widened to `int256` before negation. The fee itself is at most `2^127 / 200`, so the donation cast and fee-growth multiplication are safe. With a valid core manager and adequate transaction gas, the active-liquidity check removes `donate`'s zero-liquidity revert condition. Ordinary swap, funding, price-limit, token-transfer, and out-of-gas failures remain possible and atomically roll back donations.

The zero-custody property describes assets generated by swaps. Anyone can transfer ERC-20 tokens or ERC-6909 claims to an address, or force ETH to it independently of this protocol. Preventing those unsolicited gifts is impossible; with no sweep function they cannot be recovered. No hook action creates or needs such balances.

## Recipients and data

Donations reach **whoever is in range at the post-swap tick**, proportional to their active liquidity. This includes **JIT liquidity added in the same block**, and a swap can finish in a different LP range than where it started. There is no holding period or anti-JIT mechanism. Standard v4 fee-growth rounding can leave sub-unit remainders; the event records the exact amount donated, not a promise that every unit is immediately collectible by a particular position. Out-of-range liquidity earns no donation.

All cumulative donation state is keyed by the full `PoolId` and currency. Any native-ETH pool using this hook can accrue its own totals; there is no mutable registry or token allowlist. Non-native pools are inert. `sender` identifies the router, not an authenticated trader. `hookData` is unauthenticated and deliberately ignored, including malformed or empty bytes. No user or router receives a personal credit from this hook.

See [the ABI guide](docs/ABI.md), [RBTE ABI](docs/abi/RBTE.json), and [LPDonateHook ABI](docs/abi/LPDonateHook.json).

## Deployment and rehearsal parameters

| Parameter | Value |
| --- | --- |
| Network | Sepolia, 11155111 |
| Manager constructor argument | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| Pool currencies | native ETH at currency0, deployed RBTE at currency1 |
| Pool fee / tick spacing | 3000 / 60 |
| Token constructor arguments | none |
| Hook permissions | `0x0044` under mask `0x3fff` |
| Rehearsal initial sqrtPriceX96 | `792281625142643375935439503360000` |
| Rehearsal initial price | 100,000,000 RBTE per ETH; 0.00000001 ETH per RBTE |
| Rehearsal LP ticks | -887220 to 184200 |
| Rehearsal seed budget | 1,000,000,000 RBTE, zero ETH |

**Price, tick range, and seed allocation are explicit rehearsal assumptions.** The supplied workflow does not contain a numerical manifest price, a factory source/address, or supply-split amounts. `test/helpers/LaunchParameters.sol` is the single source for the rehearsal assumptions; `docs/deployment-parameters.json` makes them available to the manifest author. They are not represented as an already approved manifest. The initial price is above the position's upper tick, so all seeded assets are RBTE, the manager holds zero ETH, and the first buy crosses into active liquidity. Seed liquidity is rounded down; the factory retains only the unspent rounding remainder.

The local `test/helpers/LaunchFactory.sol` models the described call sequence: CREATE the token into the factory, CREATE2 the hook, initialize the pool, and unlock/modify liquidity/sync/transfer RBTE/settle. It tests both first-buy modes and a subsequent sale using the upstream `PoolSwapTest` router. It is a test model, not a replacement production factory or a claim to reproduce unspecified factory internals.

Deployment services must reconcile these assumptions with the final manifest and actual factory, then rerun the rehearsal if the parameters differ. Mine the CREATE2 salt using the **actual CREATE2 deployer address** and `keccak256(LPDonateHook.creationCode ++ abi.encode(manager))`; constructor arguments, compiler settings, and source changes affect the address. `test/helpers/HookMiner.sol` demonstrates this exact computation without bypassing constructor checks. Salt searches in tests are bounded at 200,000 attempts. Do not reuse a salt mined for the test factory in production.

Before publishing/deploying, services verify manager and router code on the intended Sepolia chain, agree the final initialization price and token allocation, and obtain the independent adversarial review of accepted sources plus `launch.json`. Policy and signed artifact linkage are service responsibilities. The review should exercise the concrete settlement, sign/currency mapping, zero-liquidity, rounding, gas, and JIT cases. Source/constructor/authorization conflicts remain review findings. No independent security review or live-chain rehearsal is claimed by these local tests.

## Build and checks

All imported Solidity dependencies are ordinary vendored files, pinned in [docs/dependencies.json](docs/dependencies.json), with their upstream licenses. No submodules, package manager, network, environment variables, FFI, or filesystem cheatcode permissions are needed to build or run tests. Foundry must have Solidity **0.8.26** installed. `foundry.toml` pins that version, targets Cancun, enables the optimizer at 200 runs, and sets `bytecode_hash = "none"`.

```sh
forge build
forge test
forge fmt --check
```

Tests cover the real v4 core, CREATE2 permissions and invalid salts, every callback's caller restriction, all four swap modes, comparison with hook-free execution, donation-specific fee growth, LP collection/JIT capture, dust and rounding thresholds, partial fills, zero-liquidity exits, non-native pools, pool isolation, failed-payment rollback, and the one-sided launch. Fuzz tests use 256 cases; stateful invariants run 64 sequences of 64 swaps with failures enabled, checking cumulative donations, custody, deltas, and ETH/token conservation. Token tests cover allocation, metadata, transfers, allowances, failures, and absent administrative selectors. Runtime checks also reject proxy/destructive opcodes and enforce EIP-170 size. Tests are isolated and do not consume environment configuration.

See [local validation results](docs/validation.md) for the clean build, empty-environment parallel run, gas observations, and remaining stage responsibilities.

To regenerate the machine-readable ABI exports after a source change:

```sh
forge inspect RBTE abi --json > docs/abi/RBTE.json
forge inspect LPDonateHook abi --json > docs/abi/LPDonateHook.json
```

Pinned upstream references: [v4-core](https://github.com/Uniswap/v4-core/tree/46c6834698c48bc4a463a86d8420f4eb1d7f3b75), [OpenZeppelin ERC-20](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/acd4ff74de833399287ed6b31b4debf6b2b35527/contracts/token/ERC20). Uniswap core uses per-file MIT/BUSL-1.1 licensing; this project's original sources use MIT. See the vendored license files.
