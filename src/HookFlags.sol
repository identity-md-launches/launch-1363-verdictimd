// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title HookFlags
/// @notice Uniswap v4 decides which hook callbacks to invoke from the lowest 14 bits of the hook
///         contract's address. This library names the flag the launch's initialization guard needs
///         and checks whether a candidate address carries exactly a given set of flags.
/// @dev Every function is internal so the compiler inlines it: a public or external library function
///      would leave an unlinked placeholder in the bytecode, which the launch can neither hash nor deploy.
library HookFlags {
    /// @notice The `beforeInitialize` permission bit (v4-core `Hooks.BEFORE_INITIALIZE_FLAG`).
    uint160 internal constant BEFORE_INITIALIZE = 1 << 13;

    /// @notice Mask covering all fourteen permission bits.
    uint160 internal constant ALL_FLAGS = (1 << 14) - 1;

    /// @notice True when `hook`'s permission bits are exactly `flags`: every requested callback is
    ///         enabled and no other one is, so the PoolManager never calls a function the hook does
    ///         not implement.
    /// @param hook The candidate hook address.
    /// @param flags The permission bits it must carry, and no others.
    function matches(address hook, uint160 flags) internal pure returns (bool) {
        return (uint160(hook) & ALL_FLAGS) == flags;
    }
}
