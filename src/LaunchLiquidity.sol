// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

/// @title LaunchLiquidity
/// @notice Settlement helpers for the launch's Uniswap v4 flows. Used inside a `PoolManager.unlock`
///         callback by whoever holds the tokens being moved: the factory when it seeds the pool
///         single-sided, and any trader when it swaps.
/// @dev Every function is internal so the compiler inlines it into the caller. Debts are paid from
///      the caller's own balance (`address(this)`), never through an allowance, so a holder never
///      has to approve anything to seed or trade.
library LaunchLiquidity {
    using BalanceDeltaLibrary for BalanceDelta;

    /// @notice One single-sided seed: the pool, the tick range and the liquidity to mint there.
    struct Seed {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    /// @dev The caller must hold the currency it owes; a transfer that fails leaves the delta open
    ///      and the PoolManager reverts the whole unlock.
    error TransferFailed(address token, uint256 amount);

    /// @notice Executes a `Seed` inside an unlock callback: mints the liquidity and pays whatever the
    ///         pool asks for from the caller's balance.
    /// @param manager The PoolManager that issued the unlock callback.
    /// @param data The abi-encoded `Seed` the caller passed to `unlock`.
    function settleSeed(IPoolManager manager, bytes memory data) internal {
        Seed memory seed = abi.decode(data, (Seed));
        (BalanceDelta delta,) = manager.modifyLiquidity(
            seed.key,
            ModifyLiquidityParams({
                tickLower: seed.tickLower,
                tickUpper: seed.tickUpper,
                liquidityDelta: int256(uint256(seed.liquidity)),
                salt: bytes32(0)
            }),
            ""
        );
        settle(manager, seed.key.currency0, delta.amount0());
        settle(manager, seed.key.currency1, delta.amount1());
    }

    /// @notice Closes one currency's delta for the caller. A negative amount is a debt, paid from the
    ///         caller's balance; a positive amount is a credit, taken to the caller; zero is a no-op.
    /// @param manager The PoolManager that issued the unlock callback.
    /// @param currency The currency the delta is in (the zero address is native ETH).
    /// @param amount The caller's delta in that currency, as the PoolManager reported it.
    function settle(IPoolManager manager, Currency currency, int128 amount) internal {
        if (amount < 0) {
            uint256 owed = uint256(uint128(-amount));
            if (currency.isAddressZero()) {
                manager.settle{value: owed}();
            } else {
                manager.sync(currency);
                _transfer(Currency.unwrap(currency), address(manager), owed);
                manager.settle();
            }
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(uint128(amount)));
        }
    }

    /// @dev ERC-20 transfer from the caller that tolerates tokens returning nothing but rejects a
    ///      `false` return or a revert.
    function _transfer(address token, address to, uint256 amount) private {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed(token, amount);
    }
}
