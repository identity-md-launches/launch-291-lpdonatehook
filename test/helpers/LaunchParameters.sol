// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Explicit rehearsal assumptions; the manifest author must reconcile these before launch.
library LaunchParameters {
    // 100,000,000 raw RBTE units per wei = 0.00000001 ETH per RBTE (both have 18 decimals).
    uint160 internal constant SQRT_PRICE_X96 = 792281625142643375935439503360000;
    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    int24 internal constant TICK_LOWER = -887220;
    int24 internal constant TICK_UPPER = 184200;
    uint256 internal constant SEED_AMOUNT = 1_000_000_000 ether;
}
