# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OddMaki is a permissionless prediction market protocol with a fully on-chain CLOB, built on Base. It uses the EIP-2535 Diamond proxy pattern — a single proxy (`OddMaki.sol`) delegates all calls to stateless facets. All state lives in namespaced Diamond storage.

## Build & Test Commands

```bash
forge build              # Build the project (via_ir enabled, Solidity 0.8.28, Cancun EVM)
forge test -vvv          # Run all 423 tests
forge test --mt testName # Run a single test by name
forge test --mc Contract # Run all tests in a specific contract
forge test -vvvv         # Max verbosity (includes traces)
```

Deployment (local Anvil):
```bash
forge script script/DeployOddMaki.s.sol --fork-url http://localhost:8545 --broadcast
```

## Architecture

### Layered Design

Calls flow through a strict pipeline: **Facet → Validator → Service → Aggregate → Storage**

- **Facets** (`src/facets/`) — Public entry points. Stateless. Delegate to validators, services, and aggregates. Never contain business logic directly.
- **Validators** (`src/validators/`) — Read-only guard checks that enforce domain invariants. Called early in facet functions.
- **Services** (`src/services/`) — Business logic libraries. Orchestrate multi-step transactions (saga pattern). May read storage but never mutate it directly.
- **Aggregates** (`src/aggregates/`) — Mutation-only libraries that write to storage. No getters. Called by services to persist state changes.
- **Storage** (`src/storage/`) — 13 namespaced Diamond storage libraries using `keccak256("oddmaki.storage.<name>")` position hashing.

### Three-Layer Market Storage

Markets are split across three storage namespaces:
- **Registry** (`LibMarketRegistryStorage`) — Identity, lifecycle, venue link, snapshotted fees
- **Oracle** (`LibMarketOracleStorage`) — CTF condition, outcomes, UMA assertion data
- **Trading** (`LibMarketTradingStorage`) — Collateral, positions, volume, tick size

### Three Settlement Paths (Matching Engine)

The matching engine in `LibMatchingService` tries fills in priority order:
1. **NORMAL** (`LibNormalFillService`) — Same outcome, opposite sides (BUY crosses SELL)
2. **MINT** (`LibMintFillService`) — YES buy + NO buy cross (split collateral into outcome tokens)
3. **MERGE** (`LibMergeFillService`) — YES sell + NO sell cross (merge tokens into collateral)

### Fee Model

```
Total = Protocol (20 bps) + Venue (1-200 bps) + Operator (10 bps)
```
Venue fee splits into creator share + venue net. Fees are snapshotted per market at creation to protect resting orders. Distributed to 4 recipients: protocol treasury, venue treasury, market creator, operator.

### Order Book Structure

Doubly-linked list per market. Each tick level has head/tail order pointers. `TickList` tracks best bid (head) and worst (tail). Orders within a tick are FIFO.

### Multi-Tenant Model

Each **venue** is an independent marketplace. Venue operators configure: fee structure, access control (whitelist, token-gated, or NFT-gated), oracle parameters, and market creation fees.

### Market Groups (Neg-Risk)

N mutually exclusive binary markets sharing collateral via `WrappedCollateralToken`. One resolves YES, the rest cascade to NO. NO positions can be converted to complementary YES positions + collateral via `NegRiskFacet`.

### Access Control

Three pluggable implementations in `src/access-control/`:
- `WhitelistAccessControl` — Address whitelist
- `TokenGatedAccessControl` — ERC-20 balance threshold
- `NFTGatedAccessControl` — ERC-721 ownership

### External Dependencies

- **Gnosis CTF** — ERC-1155 outcome tokens
- **UMA Optimistic Oracle V3** — Market resolution assertions
- **Pyth Network** — Price feeds for Up/Down markets
- **OpenZeppelin** — ReentrancyGuard, ERC20 interfaces

### Test Infrastructure

Tests use `test/helpers/DiamondSetup.sol` which deploys the full Diamond with all facets. Mock contracts: `MockCTF` (ERC-1155), `MockERC20`, `MockUmaOracle`, `ReentrancyAttacker`.
