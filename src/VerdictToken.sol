// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title VerdictIMD (VERDICT)
/// @notice A plain, fixed-supply ERC-20. The whole supply of 1,000,000,000 VERDICT (18 decimals)
///         is minted exactly once, in the constructor, to the deployer (`msg.sender`). On the IMD
///         launch the deployer is the ProjectFactory, which pays the supply out: the swarm's share
///         to the launch's MerkleDistributor, the pool share into the Uniswap v4 pool, and the
///         remainder to the requester's address.
/// @dev There is deliberately no owner, no mint, no pause, no blocklist, no fee and no burn hook:
///      nothing can grow the supply after deployment and no privileged hand can move or freeze a
///      holder's balance. Transfers are the unmodified OpenZeppelin v5 ERC-20 semantics, so every
///      launch flow (factory -> distributor, distributor -> claimant, factory -> PoolManager,
///      trader <-> PoolManager) moves exactly what it says.
contract VerdictToken is ERC20 {
    /// @notice The token's full name as returned by `name()`.
    string internal constant NAME = "VerdictIMD";

    /// @notice The token's symbol as returned by `symbol()`.
    string internal constant SYMBOL = "VERDICT";

    /// @notice Total supply in minor units: 1,000,000,000 * 10**18. Minted once; never changes upward.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    /// @notice Mints the entire supply to the deployer.
    /// @dev Takes no arguments and calls no other contract, so it deploys on an empty chain and the
    ///      launch manifest's `constructorArgs` is empty.
    constructor() ERC20(NAME, SYMBOL) {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
