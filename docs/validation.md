# Local validation

Executed with Foundry 1.8.3 and the configured Solidity 0.8.26 compiler. These are contributor-local checks, not independent review or service admission evidence.

| Check | Result |
| --- | --- |
| `forge build`, including a clean rebuild | Pass; 86 source files compiled |
| `forge test` | 30 tests passed, 0 failed, 0 skipped |
| `forge fmt --check` | Pass |
| Clean rebuild with `env -i PATH=/root/.local/bin:/usr/bin:/bin forge build` | Pass |
| `env -i PATH=/root/.local/bin:/usr/bin:/bin forge test --threads 4` | 30 tests passed, 0 failed, 0 skipped |
| Stateful invariant campaign | 64 sequences, 4,096 swap calls, 0 reverts; three invariants checked |
| Exported ABI arrays compared to clean compiler artifacts | Exact matches for both contracts |
| Runtime size | RBTE: 1,723 bytes; LPDonateHook: 3,854 bytes |

Foundry reports the three stateful invariants as one invariant suite result, included in the 30-test total. The fuzz tests each run 256 cases. No input environment is consumed by tests; the PATH above only locates host executables.

The compiler succeeds; Forge's additional lint pass emits conservative warnings around signed casts, an unused deterministic `donate` return, and the event emitted after the manager call. Cast bounds are explained in the source and README. The manager's donation delta is defined as the negation of the supplied amounts; the hook has no need to use the returned copy. The called core donation implementation does not transfer tokens or invoke this hook's disabled donation callbacks, so it cannot reenter a swap through this path. Logs are emitted only after a successful donation. No lint suppression or unsafe compiler setting is enabled.

## Gas observations

Command:

```sh
forge test --match-test '^test_exact(In|Out)(Buy|Sell)Donates' -vvvv
```

The nested `LPDonateHook::afterSwap` trace entries report:

| One-unit trade at the test's 1:1 pool price | Callback gas |
| --- | --- |
| Exact-input buy | 57,201 |
| Exact-input sell | 57,152 |
| Exact-output buy | 35,306 |
| Exact-output sell | 35,355 |

These are local trace observations including the nested donation call, under the test's storage and account access conditions. They are not transaction gas limits or universal upper bounds. A separate `--gas-report` run also passed all four modes. The callback has no loops; CREATE2 mining is deployment/test work only.

## Remaining stage responsibilities

The supplied workflow did not provide a numerical manifest price, token allocation, actual factory source, or factory address. Rehearsal assumptions are explicit in `LaunchParameters.sol` and `deployment-parameters.json`; the manifest author and deployment services must reconcile those values and repeat the factory rehearsal against the accepted parameters. The same-swap accounting and both first-buy modes have been exercised against a locally deployed real PoolManager, without runtime relocation, bypassed constructor validation, pre-seeded ETH, mocks of core accounting, or live RPC access.

The synthetic `int128.min` test exercises only the waived-donation boundary through an authorized-manager prank; all ordinary swap, fee-growth, settlement, launch, fuzz and invariant paths run through the real manager.

No independent adversarial review, launch manifest, source publication, attestation, admission decision, Sepolia deployment, live router verification, fork rehearsal, or frontend is claimed here. Those belong to the separately assigned review/manifest roles and later services.
