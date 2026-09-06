<div align="center">

<img src="media/logo.png" alt="Pons Family" width="96" height="96" />
 
# Pons Launchpad Contracts — V1 & V2
    
<a href="https://ponsfamily.com">
  <img src="https://readme-typing-svg.demolab.com?font=Fira+Code&weight=500&size=20&duration=2800&pause=900&color=1a2740&center=true&vCenter=true&width=680&lines=Token+launchpad+contracts+for+ponsfamily.com;V1%3A+CREATE2+factory+%2B+locked+Uniswap+V3+liquidity;V2%3A+bonding+curve+that+graduates+into+Uniswap+V4;Shared+fee+policy%2C+buyback+vault+and+permanent+locks;Deployed+on+Robinhood+Chain" alt="Typing SVG" />
</a>                
                        
[![License: MIT](https://img.shields.io/badge/license-MIT-1a2740?style=for-the-badge)](LICENSE)
[![Solidity](https://img.shields.io/badge/solidity-%5E0.8.26%20%7C%20%5E0.8.30-1a2740?style=for-the-badge&logo=solidity&logoColor=white)](#repository-layout)
[![Chain](https://img.shields.io/badge/chain-Robinhood%20Chain-1a2740?style=for-the-badge)](#stack)
[![Website](https://img.shields.io/badge/website-ponsfamily.com-1a2740?style=for-the-badge&logo=googlechrome&logoColor=white)](https://ponsfamily.com)
[![X](https://img.shields.io/badge/follow-%40ponsdotfamily-1a2740?style=for-the-badge&logo=x&logoColor=white)](https://x.com/ponsdotfamily)
 
[![OpenZeppelin](https://img.shields.io/badge/security-OpenZeppelin-1a2740?style=flat-square)](#vendor-dependencies)
[![Uniswap V3](https://img.shields.io/badge/v1%20liquidity-Uniswap%20V3-1a2740?style=flat-square)](#v1--createmm2-factory--locked-uniswap-v3-liquidity)
[![Uniswap V4](https://img.shields.io/badge/v2%20liquidity-Uniswap%20V4-1a2740?style=flat-square)](#v2--bonding-curve--graduated-uniswap-v4-pool)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-1a2740?style=flat-square)](#contributing)
     
</div>

<img src="https://capsule-render.vercel.app/api?type=rect&color=0:1a2740,100:05070d&height=3&section=header" width="100%" />
   

> **Pons is to Robinhood Chain what the quiver is to Robin Hood.**

>A quiver carries what is needed for the journey ahead, keeping every arrow close until the moment it is needed. **Pons carries the same spirit into Robinhood Chain, built to give every idea its shot.** And like every arrow tells a story of where it has been and where it is going, every launch becomes part of something bigger.            
          
            

This repository holds the Solidity source for the [ponsfamily.com](https://ponsfamily.com) token launchpad on Robinhood Chain, in both generations:

- **V1** (`contractsV1/`) — a CREATE2 factory that mints a fixed-supply ERC-20, opens a one-sided Uniswap **V3** position, locks the position NFT, and can run a developer buy in the same transaction.
- **V2** (`contractsV2/`) — a launch flow where the full supply mints to a constant-product **bonding curve** that trades in the pool's future quote asset, then graduates permanently into a locked full-range Uniswap **V4** pool governed by a shared hook, with quote-denominated fees, a creator tax, a fee escrow and a five-year buyback vault.

Both generations are live source and both factories are verified on chain.

Website: [ponsfamily.com](https://ponsfamily.com) · Twitter/X: [@ponsdotfamily](https://x.com/ponsdotfamily)

## Table of contents

- [Deployed factories](#deployed-factories)
- [V1 vs V2 at a glance](#v1-vs-v2-at-a-glance)
- [V1 — CREATE2 factory + locked Uniswap V3 liquidity](#v1--create2-factory--locked-uniswap-v3-liquidity)
- [V2 — bonding curve + graduated Uniswap V4 pool](#v2--bonding-curve--graduated-uniswap-v4-pool)
- [Stack](#stack)
- [Repository layout](#repository-layout)
- [Vendor dependencies](#vendor-dependencies)
- [Generated files](#generated-files)
- [Design notes](#design-notes)
- [Security](#security)
- [Contributing](#contributing)
- [License](#license)

## Deployed factories

| Generation | Contract               | Address                                      |
| ---------- | ---------------------- | -------------------------------------------- |
| V1         | `PonsLaunchFactory`    | `0xA5aAb3F0c6EeadF30Ef1D3Eb997108E976351feB`  |
| V2         | `PonsV2LaunchFactory`  | `0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e`  |

`abi.json` and `contract-meta.json` in the repository root describe the V1 deployment. Always verify deployed bytecode against the verified sources before trusting an address.

## V1 vs V2 at a glance

| | **V1** | **V2** |
| --- | --- | --- |
| Price discovery | Uniswap V3 pool from block one | Constant-product bonding curve, then a V4 pool |
| Initial liquidity | One-sided V3 position, full supply | Full supply minted to the curve |
| Final venue | Uniswap V3 | Full-range Uniswap V4 position + singleton hook |
| Liquidity lock | Position NFT locked by a configurable locker | Position NFT permanently locked, no withdrawal path |
| Fees | V3 pool fee tier | Curve fee + hook fee, split protocol / creator / buyback |
| Creator revenue | Trading fees on the locked position | Quote-denominated fee share + optional creator tax, from the first trade |
| Buybacks | — | `PonsV2BuybackVault`, five-year linear vest instead of a burn |
| Anti-snipe | Same-block block, max wallet, cumulative buy cap | Curve price impact + reserved pool allocation |
| Dev buy | Optional, atomic in `launchToken` | Anyone (deployer included) can buy from the curve immediately |
| Graduation | Status derived from locked position principal | Two-phase, permissionless `graduate` + retryable `createGraduatedPool` |

## V1 — CREATE2 factory + locked Uniswap V3 liquidity

Launching a token normally takes several transactions: deploy, initialize the pool, add liquidity, lock it, and maybe a first buy. Each step can fail or be front-run. V1 does all of it in one call.

**Key features**

- CREATE2 factory, so the token address is predictable before deployment
- One-sided Uniswap V3 liquidity, full supply concentrated from the first block
- Position NFT locked through a configurable locker, never left in a plain wallet
- Anti-snipe limits in the launch window: same-block buy blocking, per-wallet cap, cumulative buy cap
- Optional developer buy, settled atomically in the launch transaction
- Graduation status computed from capital actually locked in the pool, not from wallet balances

**Core contracts**

### `contractsV1/src/PonsLaunchFactory.sol`
The V1 entry point used by pons.family.
- Owner-managed DEX profiles (V3 factory, position manager, swap router, fee tier, tick spacing)
- Owner-managed launch presets (pair asset, supply, anti-snipe windows, graduation threshold, initial tick)
- `launchToken(...)`: CREATE2 deploy, pool init, one-sided mint, position lock, optional swap of leftover native value into the new token
- `predictTokenAddress(...)`: deterministic address preview for frontends
- `graduationStatus(...)`: locked position principal against the stored threshold

### `contractsV1/src/PonsLauncherToken.sol`
The fixed-supply ERC-20 spawned per launch.
- Entire supply minted to the factory, then deposited as V3 liquidity
- On-chain metadata: logo, description, socials
- Early-window buy limits against the canonical pool
- Narrow, factory-controlled exemption so the atomic launch buy settles cleanly

### `contractsV1/src/interfaces/ILaunchpad.sol`
Uniswap V3 factory/pool/position-manager shapes, SwapRouter02 and classic router params, the `IPonsLaunchFactory.LaunchedToken` record, and `IPonsLaunchLocker` hooks.

### `contractsV1/src/libraries/`
`PonsLiquidityMath.sol` (concentrated-range amount math) and `PonsTickMath.sol` (Uniswap V3 tick math lineage, `GPL-2.0-or-later`).

## V2 — bonding curve + graduated Uniswap V4 pool

V2 replaces day-one concentrated liquidity with a fair-launch curve. Every launch mints its full supply to its own bonding curve, which **trades in the same quote asset its future V4 pool will use** (native ETH, or a chosen ERC-20 `pairToken`). Because the curve collects the eventual pool asset from the very first trade, graduation seeds the pool directly — no router, no swap, and no price oracle anywhere in the system.

**Key features**

- Constant-product bonding curve per launch, with a phantom quote reserve setting the opening price
- Quote-denominated fees from the first trade: fees are always charged on the quote leg, never in the memecoin
- Identical fee logic before and after graduation, read live from a shared `IPonsV2FeePolicy` and snapshotted per launch
- Optional creator tax (capped) paid entirely to the creator, on top of the protocol / creator / buyback fee split
- Two-phase graduation: `graduate` drains the curve into the factory (safe to trigger inside the crossing buy), `createGraduatedPool` seeds the V4 pool and stays retryable so reserves can never be stranded
- Full-range Uniswap V4 position, permanently locked — the locker exposes no withdrawal or arbitrary-call function
- Singleton `PonsV2MemeHook` on every graduated pool: takes an `afterSwap` cut and converts memecoin-denominated fees back to the quote currency against the pool's own liquidity, under a configurable max price-impact bound
- Buybacks are locked, not burned: `PonsV2BuybackVault` vests bought-back supply linearly over five years with a weighted-average vesting clock
- Claim-based `IPonsV2FeeEscrow` ledger for protocol and creator balances, in ETH or ERC-20
- Anyone, deployer included, can buy from the curve at any time; price impact and the reserved pool allocation are the only limits

**Core contracts** (`contractsV2/src/v2/`)

| Contract | Role |
| --- | --- |
| `PonsV2LaunchFactory.sol` | Entry point: creates each launch, enforces fee/supply bounds, orchestrates both graduation phases |
| `PonsV2LaunchDeployer.sol` | Deploys the curve + token pair and bounds metadata length (split out to stay under EIP-170) |
| `PonsV2BondingCurve.sol` | Constant-product curve, quote-leg fees, creator tax, fee sweeps, graduation trigger |
| `PonsV2LauncherToken.sol` | Fixed-supply ERC-20 (with `ERC20Burnable`) minted entirely to its curve; `deployer` is metadata only, no privileges |
| `PonsV2GraduationGuard.sol` | Stateless preflight mirroring V4's real rejections, so a curve is never drained into an unseedable position |
| `PonsV2GraduationExecutor.sol` | Performs the heavy graduation steps: optional pairToken swap, Permit2 dance, full-range mint, dust sweep |
| `PonsV2LaunchLocker.sol` | Permanently holds the graduated V4 position NFT; no `collectFees`, no withdrawal path |
| `PonsV2BuybackVault.sol` | Shared vault holding bought-back supply on a five-year linear vest, split on recorded fee shares |
| `hooks/PonsV2MemeHook.sol` | Singleton V4 hook: swap fee cut, internal memecoin→quote conversion, protocol/creator/buyback split |
| `interfaces/ILaunchpadV2.sol`, `interfaces/ILaunchpadV2Graduation.sol` | Fee escrow, fee policy snapshot, factory/curve records and graduation hooks |
| `libraries/PonsV2BondingCurveMath.sol`, `libraries/PonsV2GraduationMath.sol` | Curve pricing and graduation seed math |

**Guardrails baked into V2**

- Curve fee ≤ 10%, creator tax ≤ 10%, total trade fee ≤ 20%
- Minimum pair-token decimals and minimum launch supply enforced at creation
- Quotability preflight prices a reference trade so a launch can never be created in an unquotable configuration
- Metadata length caps (name, symbol, logo, description, socials) so `socials()` stays readable on chain

## Stack

| Item            | Value                                                              |
| --------------- | ------------------------------------------------------------------ |
| Language        | Solidity `^0.8.26` (V2) · `^0.8.30` (V1)                            |
| Chain           | Robinhood Chain (EVM L2)                                            |
| Product         | [ponsfamily.com](https://ponsfamily.com)                            |
| V1 factory      | `0xA5aAb3F0c6EeadF30Ef1D3Eb997108E976351feB`                        |
| V2 factory      | `0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e`                        |
| Liquidity       | Uniswap V3 (V1) · Uniswap V4 core + periphery + Permit2 (V2)        |
| Access control  | OpenZeppelin `Ownable2Step`                                         |
| Safety          | OpenZeppelin `ReentrancyGuard`, `SafeERC20`                         |

## Repository layout

```
.
├── README.md
├── abi.json                     # V1 factory ABI
├── contract-meta.json           # V1 build/deployment metadata
├── media/
│   └── logo.png
├── contractsV1/
│   ├── src/
│   │   ├── PonsLaunchFactory.sol
│   │   ├── PonsLauncherToken.sol
│   │   ├── interfaces/ILaunchpad.sol
│   │   └── libraries/
│   │       ├── PonsLiquidityMath.sol
│   │       └── PonsTickMath.sol
│   └── lib/openzeppelin-contracts/
└── contractsV2/
    ├── src/v2/
    │   ├── PonsV2LaunchFactory.sol
    │   ├── PonsV2LaunchDeployer.sol
    │   ├── PonsV2BondingCurve.sol
    │   ├── PonsV2LauncherToken.sol
    │   ├── PonsV2GraduationGuard.sol
    │   ├── PonsV2GraduationExecutor.sol
    │   ├── PonsV2LaunchLocker.sol
    │   ├── PonsV2BuybackVault.sol
    │   ├── hooks/PonsV2MemeHook.sol
    │   ├── interfaces/
    │   │   ├── ILaunchpadV2.sol
    │   │   └── ILaunchpadV2Graduation.sol
    │   └── libraries/
    │       ├── PonsV2BondingCurveMath.sol
    │       └── PonsV2GraduationMath.sol
    └── lib/
        ├── openzeppelin-contracts/
        ├── v4-core/
        ├── v4-periphery/         # incl. permit2 interfaces
        └── v4-hooks-public/      # BaseHook
```

## Vendor dependencies

Both generations vendor only the upstream files they actually compile against, keeping the verified source trees self-contained:

- **OpenZeppelin Contracts** — `Ownable`, `Ownable2Step`, `ERC20`, `ERC20Burnable`, `SafeERC20`, `ReentrancyGuard`, math and introspection utilities
- **Uniswap V4 core** (V2) — `IPoolManager`, `IHooks`, pool/position/tick libraries, `PoolKey`, `Currency`, `BalanceDelta` and related types
- **Uniswap V4 periphery + Permit2** (V2) — `IPositionManager`, `Actions`, `LiquidityAmounts`, `IAllowanceTransfer`
- **v4-hooks-public** (V2) — `BaseHook`

## Generated files

- `abi.json` — ABI of the live V1 factory
- `contract-meta.json` — compiler version, optimizer settings, EVM target and source list for the live V1 deployment

## Design notes

1. **V1: single-transaction launch.** Deployment, pool creation, liquidity lock and any developer buy share one `launchToken` call, so the user signs once.
2. **V1: deterministic addresses.** CREATE2 makes the token address predictable through `predictTokenAddress`.
3. **V1: temporary buy limits.** Anti-snipe rules live on the token and expire; standard ERC-20 behavior resumes afterwards.
4. **V2: one asset end to end.** The curve trades in the pool's future quote asset, so graduation needs no swap and no oracle.
5. **V2: fees are quote-denominated.** Protocol and creator revenue exists from the first trade, never as illiquid memecoin dust.
6. **V2: graduation cannot strand reserves.** The stateless guard preflights V4's real rejection paths, and seeding stays retryable.
7. **V2: locks are permanent.** Neither the locker nor any admin path can pull the graduated position; buybacks vest, they don't burn.
8. **Bytecode budget.** V2 splits deploying, seeding and preflight into separate contracts purely to stay under EIP-170's 24,576-byte limit.

## Security

- Ownership transfers use OpenZeppelin `Ownable2Step` across both generations.
- Launch and trade entry points are protected by `ReentrancyGuard`; token transfers use `SafeERC20`.
- V2's fee policy is snapshotted per launch, so a later policy change cannot retroactively alter existing launches.
- `PonsV2LaunchLocker` intentionally exposes no withdrawal or arbitrary-call function.
- `contractsV1/src/libraries/PonsTickMath.sol` keeps its `GPL-2.0-or-later` header from Uniswap V3 — keep it intact in forks.
- This repository ships source only. Verify deployed bytecode against the verified sources and `contract-meta.json` before trusting a live address.

If you find a security issue, please report it privately instead of opening a public issue. Contact details are on [ponsfamily.com](https://ponsfamily.com).

## Contributing

Issues and pull requests are welcome.

## License

- First-party Pons contracts (V1 and V2): MIT (see SPDX headers)
- `PonsTickMath.sol`: GPL-2.0-or-later (Uniswap V3 tick math lineage)
- OpenZeppelin sources: MIT (upstream)
- Uniswap V4 core/periphery and Permit2 sources: upstream licenses (MIT / GPL / BUSL as marked per file)

<div align="center">
<img src="https://capsule-render.vercel.app/api?type=waving&color=0:1a2740,100:05070d&height=100&section=footer" width="100%" />

If this project is useful to you, consider starring the repository.
</div>
