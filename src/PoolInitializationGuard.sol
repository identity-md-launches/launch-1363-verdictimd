// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @title PoolInitializationGuard
/// @notice A minimal Uniswap v4 hook with only the `beforeInitialize` permission. A pool keyed to
///         this hook can be opened only by the launch factory that deployed the guard, so nobody can
///         front-run the launch by initializing its pool at a price of their choosing.
/// @dev The guard's address must carry exactly the BEFORE_INITIALIZE flag (see `HookFlags`), which
///      the factory achieves by CREATE2 salt search. The guard takes no part in liquidity, swaps or
///      donations: with no other flag set, the PoolManager never calls it again after initialization.
contract PoolInitializationGuard {
    /// @notice The PoolManager this guard answers to. Anything else calling the hook is rejected.
    address public immutable poolManager;

    /// @notice The only address allowed to initialize a pool bearing this hook: whoever deployed it.
    address public immutable factory;

    /// @dev The hook was invoked by something other than the PoolManager.
    error NotPoolManager(address caller);

    /// @dev Someone other than the factory tried to initialize a pool bearing this hook.
    error NotFactory(address initializer);

    /// @param poolManager_ The Uniswap v4 PoolManager on the launch chain.
    constructor(address poolManager_) {
        poolManager = poolManager_;
        factory = msg.sender;
    }

    /// @notice v4 `beforeInitialize` callback. Succeeds only when the PoolManager is relaying an
    ///         `initialize` call made by the factory.
    /// @param sender The original caller of `PoolManager.initialize`.
    /// @return The function selector, as v4 requires.
    function beforeInitialize(address sender, PoolKey calldata, uint160) external view returns (bytes4) {
        if (msg.sender != poolManager) revert NotPoolManager(msg.sender);
        if (sender != factory) revert NotFactory(sender);
        return IHooks.beforeInitialize.selector;
    }
}
