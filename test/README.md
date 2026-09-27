# Donation accounting extensions

These tests extend the accepted suite without changing production contracts or dependencies.
Both pools in `DifferentialHookBase` use the real, locally deployed v4 PoolManager. One has
the mined LPDonateHook; the other has no hook and starts with identical price and positions.
Every checked swap compares raw execution, trader assets, price, liquidity, both donation
events, lifetime totals, and the exact incremental fee growth attributable to the donation.
The oracle is the unhooked pool's actual result, not the hook's reported donation.

`DonationAccounting.t.sol` covers all four swap modes at unspecified-leg amounts 199, 200,
and 201, plus one-unit swaps. It checks partial fills, post-swap LP eligibility, collected LP
fees, leaving and reentering liquidity, and ERC-6909 take/burn settlement. Insufficient token
allowance, zero amount, and invalid price limits must revert without retaining donation
accounting or changing pool state. Fuzzed sizes and limits cross initialized LP boundaries.

`LiquidityLifecycleInvariant.t.sol` randomizes swaps, LP additions/removals, and fee collection
across broad and narrow ranges in both pools. It maintains independent cumulative donation
and fee-growth accounting, including empty-pool periods, and checks token/ETH conservation,
zero hook balances/claims/deltas, and a locked, fully settled manager. Explicit selectors
exclude setup and helper methods from the campaign. Unexpected reverts fail the campaign.
A deterministic handler test exercises all four modes, removes all liquidity, swaps in the
empty pools, restores liquidity, and collects fees.

LP amounts in that campaign are multiples of `1 ether` of liquidity, between zero and
`10_000 ether`. The upstream PoolModifyLiquidityTest router asserts that a removal returns
positive token amounts; removing one unit of liquidity can round both amounts to zero.
Swap amounts still range from one base unit to `1000 ether`. Price limits are ticks -720
and 720, around LP ranges [-600, 600] and [-60, 60]. At an already-reached limit the handler
selects the opposite direction, since v4 rejects an equal-price limit.

The launch rehearsal adds fuzzed first buys and immediate sells, plus a failed first
exact-output buy followed by a successful retry. It checks rollback to the ETH-empty,
one-sided factory seed. The existing LaunchParameters remain explicit rehearsal assumptions:
the supplied workflow has no numeric launch price or actual factory implementation, and no
launch.json is present. These tests do not establish agreement with a future manifest.

Run offline with the already-vendored dependencies and Solidity 0.8.26:

```sh
forge build
forge test
forge test --fuzz-runs 1000
```

For task-local build artifacts, add `--out test/scratch/out --cache-path test/scratch/cache`.
The process-level variables `FOUNDRY_INVARIANT_FAILURE_PERSIST_DIR=test/scratch/invariant`
and `FOUNDRY_FUZZ_FAILURE_PERSIST_DIR=test/scratch/fuzz` also redirect persisted counterexamples.
No test reads or changes environment variables, uses a network fork, replaces runtime code,
or mocks PoolManager accounting. The protected floor inputs are read-only task inputs and
are not copied into this deliverable.
