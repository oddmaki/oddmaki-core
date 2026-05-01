# OddMaki Protocol

Permissionless prediction market factory with a fully on-chain Central Limit Order Book (CLOB). Built on Base.

OddMaki lets anyone launch their own prediction market platform — what we call a **venue**. Each venue is an independent marketplace where operators control who can create markets, who can trade, fee structures, and oracle configuration. Think of it as Shopify for prediction markets: the protocol provides the trading engine, order matching, and settlement infrastructure; operators bring their audience and markets.

All trading happens on-chain through a CLOB — no off-chain components, no centralized matching, no custodial risk.

## Architecture

Single [EIP-2535 Diamond](https://eips.ethereum.org/EIPS/eip-2535) proxy with modular facets:

```
src/
├── OddMaki.sol              # Diamond proxy
├── facets/                   # Public entry points
│   ├── VenueFacet.sol        # Venue creation and configuration
│   ├── MarketsFacet.sol      # Market lifecycle
│   ├── MarketGroupFacet.sol  # Mutually exclusive market groups (neg-risk)
│   ├── LimitOrdersFacet.sol  # Limit order placement and cancellation
│   ├── MarketOrdersFacet.sol # FOK / FAK market orders
│   ├── MatchingFacet.sol     # Order matching engine
│   ├── OrderBookFacet.sol    # On-chain orderbook reads
│   ├── VaultFacet.sol        # Collateral deposits and withdrawals
│   ├── ResolutionFacet.sol   # Oracle-based market resolution
│   └── ...
├── aggregates/               # Domain orchestration (write path)
├── services/                 # Business logic
├── validators/               # Domain invariants and guard checks
├── storage/                  # Namespaced Diamond storage
└── libraries/                # Pure utilities
```

### Key Concepts

- **Venues** — Permissionless market factories. Each venue defines who can create markets, who can trade, fee structure, and oracle configuration.
- **Matching Engine** — Three settlement paths: direct fill (existing tokens), mint-to-fill (split collateral into YES + NO), and merge-to-fill (redeem YES + NO to collateral).
- **Market Groups** — N mutually exclusive binary markets sharing collateral. One resolves YES, the rest cascade to NO.
- **Fees** — Protocol fee, venue fee, creator fee, and operator fee. Fee rates are snapshotted per market at creation to protect resting orders.

### External Dependencies

- [Gnosis Conditional Token Framework (CTF)](https://github.com/gnosis/conditional-tokens-contracts) — ERC-1155 outcome tokens
- [UMA Optimistic Oracle V3](https://docs.uma.xyz/) — Market resolution
- [OpenZeppelin](https://github.com/OpenZeppelin/openzeppelin-contracts) — Security primitives

## Deployments

### Base mainnet (chainId 8453)

**Diamond:** [`0x025d086a62d93e24f3cb3f161612ca8e9530127d`](https://basescan.org/address/0x025d086a62d93e24f3cb3f161612ca8e9530127d)

All protocol calls go through the Diamond proxy. Full facet manifest: [`deployments/base/v1.0.0.json`](./deployments/base/v1.0.0.json).

### Base Sepolia (testnet)

See [`deployments/base-sepolia/latest.json`](./deployments/base-sepolia/latest.json).

## Build

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
forge build
```

## Test

```bash
forge test -vvv
```

423 tests covering matching, settlement, fees, market groups, resolution, access control, and edge cases.

## Security

This protocol handles real funds. The matching engine, fee calculations, and settlement paths are designed to be provably correct.

If you find a vulnerability, please report it responsibly to **team@oddmaki.com**.

## Related Repositories

- [oddmaki-sdk](https://github.com/OddMaki/oddmaki-sdk) — TypeScript SDK
- [oddmaki-subgraph](https://github.com/OddMaki/oddmaki-subgraph) — Subgraph for indexed reads
- [oddmaki-venue-starter](https://github.com/OddMaki/oddmaki-venue-starter) — Starter template for venue operators

## Links

- **Protocol** — [oddmaki.com](https://oddmaki.com)
- **Maintainer** — [predictablereality.com](https://predictablereality.com)
- **Contact** — team@oddmaki.com

## License

[Business Source License 1.1](./LICENSE) — see LICENSE for details. Converts to MIT on January 1, 2030. Copyright (c) 2025-2026 Predictable Reality, Inc.
