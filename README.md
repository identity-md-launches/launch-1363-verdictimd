# VerdictIMD (VERDICT)

A fixed-supply ERC-20 for an IMD custom-token launch on Ethereum (chain id 1), paired with IMD.

| | |
|---|---|
| Contract (Solidity name) | `VerdictToken` (`src/VerdictToken.sol`) |
| `name()` | `VerdictIMD` |
| `symbol()` | `VERDICT` |
| `decimals()` | `18` |
| Total supply (minor units) | `1000000000000000000000000000` (1,000,000,000 × 10¹⁸) |
| Constructor arguments | none |
| Owner / admin | none |
| Mint after deployment | impossible |

## What the token does

`VerdictToken` is OpenZeppelin v5's `ERC20` with a constructor that mints the whole supply once to
`msg.sender` and nothing else. There is no owner, no `mint`, no `burn`, no pause, no blocklist, no
transfer fee and no transfer hook. Every transfer moves exactly the amount stated, so each launch flow
(factory → MerkleDistributor, distributor → claimant, factory → PoolManager seed, trader ↔ PoolManager)
arrives whole. The runtime contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`.

Because the constructor takes no arguments and calls no other contract, the manifest's
`constructorArgs` is empty and the token deploys on an empty chain. The constructor's `msg.sender` is
whoever deploys it: on the launch that is the ProjectFactory, which pays the supply out.

## Launch support contracts

The protected launch floor imports three helpers from `src/`. They are part of this delivery so the
floor compiles and runs against this token; none of them is deployed as a project contract and none
holds or is allocated any VERDICT.

- `src/HookFlags.sol` — `HookFlags.BEFORE_INITIALIZE` (Uniswap v4's `beforeInitialize` permission bit,
  `1 << 13`) and `HookFlags.matches(address, flags)`, true when an address carries exactly those
  permission bits and no others.
- `src/PoolInitializationGuard.sol` — a v4 hook with only the `beforeInitialize` permission. It records
  its deployer as `factory` and reverts unless the PoolManager is relaying an `initialize` call made by
  that factory, so nobody can open the launch pool at a price of their choosing before the factory does.
  Its address must carry exactly `BEFORE_INITIALIZE`, which the factory achieves by CREATE2 salt search.
- `src/LaunchLiquidity.sol` — internal library used inside `PoolManager.unlock` callbacks. `Seed` is one
  single-sided position (`PoolKey`, `tickLower`, `tickUpper`, `liquidity`). `settleSeed` decodes a `Seed`,
  mints the liquidity and pays the resulting debt from the caller's own balance; `settle` closes a single
  currency delta (pay a debt from the caller's balance, take a credit to the caller, or do nothing for
  zero). Debts are paid by direct transfer after `sync`, never through an allowance, so nothing has to
  be approved to seed or trade.

All library functions are `internal`, so the compiler inlines them and no bytecode is left unlinked.

## Launch parameters (decided by the launch, not open)

| Setting | Value |
|---|---|
| Chain | Ethereum, chain id 1 |
| Pair currency | IMD, `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` (18 decimals) |
| Pool fee | `12500` (1.25%) |
| Tick spacing | `60` |
| `pool.initialPrice` (provenance only) | `79228162514264337593543950336` |
| `economics.poolBps` | `8000` |
| `economics.initialMarketCapWei` | `2500000000000000000000` (2,500 IMD for the whole supply) |
| `economics.remainderTo` | `0x612a9bb008e16ef2d24f41dae9fc661831d93367` |

Supply split performed by the factory after the constructor mints everything to it:

| Share | Amount (VERDICT) | Destination |
|---|---|---|
| 10% | 100,000,000 | Launch MerkleDistributor (swarm: 2% contributors, 8% paired seats) |
| 80% | 800,000,000 | Single-sided Uniswap v4 liquidity, opened at a 2,500 IMD cap |
| 10% | 100,000,000 | `economics.remainderTo` |

The deployer derives the pool's opening price from the market cap, the supply and the token's address
(which decides whether VERDICT sorts as `currency0` or `currency1`); that is not fixed here.

`launch.json` is written by the manifest step after this work is accepted. This repository deliberately
contains none.

## Assumptions

- The requester wants a plain token: no tax, burn, reflection, vesting or governance was asked for, so
  none is implemented. Adding any of those later means a new token contract and a new launch.
- "Deployer" in the brief is the constructor's `msg.sender`. On the launch that is the ProjectFactory,
  as the custom-token flow requires; no supply is minted to IMD's launch wallet or to any wallet named
  here.
- The compiler is pinned to `solc = "0.8.26"` with `bytecode_hash = "none"`, `cbor_metadata = false`,
  `via_ir = true` and the optimizer at 200 runs (`foundry.toml`). The IR pipeline is needed to compile
  the Uniswap v4 PoolManager the tests build in place; the token's bytes are reproducible under these
  settings and the launch must build with exactly them.
- `ffi` is off and `fs_permissions` is empty.

## Operational responsibilities

- **Nobody administers the token.** There is no key, role or setting to rotate, pause or upgrade. The
  requester's only post-launch holding is the remainder sent to `economics.remainderTo`; securing that
  wallet is the requester's responsibility.
- **Supply is final.** Nothing in this code can mint. Tokens sent to the zero address are refused by the
  ERC-20, so the supply does not change by accident either.
- **Pool initialization** is gated to the factory by `PoolInitializationGuard`; after initialization the
  guard is never called again and has no further power.
- **Explorer verification** of the deployed token is the network deployer's job (`forge verify-contract`
  with the pinned settings above). No deployment, broadcast or key handling is part of this work.
- **Security review.** Tests passing is not an audit. The token is unmodified OpenZeppelin ERC-20 with
  a one-line constructor; the launch helpers move the factory's own tokens inside PoolManager unlocks.
  Only `forge build`, `forge test` and `forge fmt --check` ran here; no static analyser was available
  in the task's toolset.

## Layout

```
foundry.toml, remappings.txt      Foundry configuration (solc 0.8.26, bytecode_hash none)
src/VerdictToken.sol              The token
src/HookFlags.sol                 Hook-permission helper (internal library)
src/PoolInitializationGuard.sol   beforeInitialize-only v4 hook
src/LaunchLiquidity.sol           Seed / settle helpers (internal library)
test/VerdictToken.t.sol           Token unit tests: metadata, mint, transfers, allowances, failure paths, fuzz
test/LaunchFlow.t.sol             Launch flows on a real PoolManager: guard, seed, buy/sell, both currency orders
lib/forge-std                     forge-std (vendored, src only)
lib/v4-core                       Uniswap v4-core (vendored, src only; src/test removed)
lib/solmate                       solmate `Owned` (v4-core's ProtocolFees dependency)
lib/openzeppelin-contracts        OpenZeppelin v5 ERC20 subset
```

Dependencies are vendored as ordinary files (no submodules) so the project builds offline.

## Build and test

```
forge build
forge test
forge fmt --check
```
