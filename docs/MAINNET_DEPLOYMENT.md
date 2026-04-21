# OddMaki — Base Mainnet Deployment Guide

End-to-end playbook for deploying the OddMaki Diamond to Base mainnet (chainId **8453**) from a dedicated, encrypted, mainnet-only signer. The testnet workflow on Base Sepolia is unchanged by this process.

> Applies to: `oddmaki-core` (Foundry / Solidity 0.8.28). Deploy script: [`script/DeployOddMaki.s.sol`](../script/DeployOddMaki.s.sol).

---

## 0. Prerequisites

- Foundry installed (`forge`, `cast`) — same toolchain you use for Sepolia.
- Funded **Base mainnet** EOA for the deployer (budget ~0.05–0.1 ETH for full Diamond + facets + verification).
- Basescan API key for contract verification (https://basescan.org/myapikey).
- A **Safe multisig** on Base mainnet that will own the Diamond after deployment. The hot deployer key should never remain owner.
- Recent `forge test` on the branch you're deploying — mainnet is not the place to discover a regression.

---

## 1. Mainnet external-dependency addresses

These are the on-chain contracts the Diamond configures itself against. **Verify each with `cast code` before using** — redeployments and migrations do happen.

| Dependency | Address on Base mainnet (8453) | Status |
|---|---|---|
| **UMA Optimistic Oracle V3** | `0x2aBf1Bd76655de80eDb3086114315Eec75AF500c` | Canonical (UMA networks/8453.json) |
| **Pyth Network** | `0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a` | Canonical (Pyth docs) |
| **Gnosis ConditionalTokens (CTF)** | *None canonical on Base mainnet* | **Deploy your own — see §3** |
| **USDC (collateral)** | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | Native USDC on Base |

### Sepolia equivalents (for reference)

| Dependency | Address on Base Sepolia (84532) |
|---|---|
| UMA Optimistic Oracle V3 | `0x0F7fC5E6482f096380db6158f978167b57388deE` |
| Pyth Network | `0xA2aa501b19aff244D90cc15a4Cf739D2725B5729` |
| ConditionalTokens | `0x7364747372Ac4a175B5326f5B2C9CB1C271d32e8` *(self-deployed via `DeployCTF.s.sol`)* |

Verify an address is actually a contract:
```bash
cast code 0x2aBf1Bd76655de80eDb3086114315Eec75AF500c --rpc-url https://mainnet.base.org | head -c 16
# → "0x60806040..." (anything other than "0x" means code is present)
```

---

## 2. Create a dedicated mainnet keystore

**Do not reuse your `deployer` keystore for mainnet.** Separate keys → separate blast radius, and you can give the mainnet key a stronger password and stricter backup.

### Import from an existing private key (hardware wallet export or offline-generated key)

```bash
cast wallet import deployer-mainnet --interactive
# → paste the private key at the prompt
# → enter a strong password (different from testnet)
```

### Or generate a fresh key inside the keystore

```bash
cast wallet new-mnemonic --words 24
# write the 24 words down on paper, store them offline (NOT in a password manager alone)
cast wallet import deployer-mainnet --interactive
# paste the corresponding private key
```

Confirm:
```bash
cast wallet list
# → deployer         (Local)
# → deployer-mainnet (Local)

cast wallet address --account deployer-mainnet
# → 0x...  (this is your mainnet deployer address)
```

### Security hygiene

- Keys live encrypted at rest in `~/.foundry/keystores/deployer-mainnet`. Without the password, the file is useless.
- **Back up** `~/.foundry/keystores/deployer-mainnet` to encrypted storage (1Password attachment, encrypted USB). If you lose it, you lose the funds in that address — there is no recovery.
- Use a password manager entry for the mainnet password. Never keep it in shell history, env files, or commit messages.
- Treat this key as a **hot deployer only**. Fund it just-in-time, deploy, transfer ownership to the Safe, then drain any leftover ETH back.

---

## 3. Deploy ConditionalTokens (CTF) first

There is no canonical Gnosis ConditionalTokens on Base mainnet. The repo includes [`script/DeployCTF.s.sol`](../script/DeployCTF.s.sol) which deploys the Gnosis CTF from raw bytecode (it's Solidity 0.5.1, hence the bytecode path).

```bash
cd oddmaki-core
forge script script/DeployCTF.s.sol:DeployCTFScript \
  --rpc-url https://mainnet.base.org \
  --account deployer-mainnet \
  --sender $(cast wallet address --account deployer-mainnet) \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

Record the returned address — you'll pass it as `CTF_ADDRESS` to the Diamond deploy in §5.

> If you later re-run the Diamond deploy in a fresh environment, you can reuse the same CTF — it does not need to be redeployed.

---

## 4. Configure `.env.mainnet`

Keep testnet and mainnet configuration in **separate files** so a wrong `source` can never mix them up. Add both `.env` and `.env.mainnet` to `.gitignore`.

```bash
# oddmaki-core/.env.mainnet

# --- RPC & verification ---
RPC_URL=https://mainnet.base.org           # or your Alchemy/QuickNode mainnet URL (faster, fewer rate limits)
ETHERSCAN_API_KEY=<your basescan key>      # from basescan.org — NOT sepolia.basescan.org

# --- Broadcaster (MUST match `deployer-mainnet` keystore address) ---
DEPLOYER_ADDRESS=0x<output of `cast wallet address --account deployer-mainnet`>

# --- Final Diamond owner: a Base mainnet Safe multisig ---
OWNER=0x<your Safe address on Base mainnet>

# --- Protocol treasury (fee recipient) ---
PROTOCOL_TREASURY=0x<treasury Safe address>

# --- External dependencies (see §1) ---
CTF_ADDRESS=0x<deployed in §3>
UMA_ORACLE_ADDRESS=0x2aBf1Bd76655de80eDb3086114315Eec75AF500c
PYTH_ADDRESS=0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a

# --- Collateral to whitelist (native USDC on Base) ---
# The deploy script whitelists this and sanity-checks decimals()==6 and logs symbol().
USDC_ADDRESS=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913

# Do NOT set DEPLOY_MOCK_USDC on mainnet.
```

### Why `DEPLOYER_ADDRESS` is required

See [`DeployOddMaki.s.sol:105-114`](../script/DeployOddMaki.s.sol#L105-L114). In `forge script`, `msg.sender` inside Solidity is **not** the broadcaster set by `--account`. The script reads `DEPLOYER_ADDRESS` to know who the real signer is, so owner bootstrapping (deployer → Safe) works correctly. Setting this wrong produces a Diamond whose initial owner doesn't match the broadcaster, and configuration calls revert.

---

## 5. Two script changes required for mainnet

Two things in the current scripts are testnet-shaped. Patch them once before your first mainnet run.

### 5a. UMA identifier (`ASSERT_TRUTH` → `ASSERT_TRUTH2`)

[`DeployOddMaki.s.sol:254-258`](../script/DeployOddMaki.s.sol#L254-L258) hardcodes `ASSERT_TRUTH`. Per the inline comment, mainnet OOv3 requires `ASSERT_TRUTH2`. Two options:

**Option A — branch on chain ID (preferred, one-time change):**
```solidity
bytes32 umaIdentifier = block.chainid == 8453 ? bytes32("ASSERT_TRUTH2") : bytes32("ASSERT_TRUTH");
ProtocolFacet(address(protocol)).setUmaIdentifier(umaIdentifier);
```

**Option B — deploy as-is, then fix post-deploy** from the owner Safe:
```bash
cast send $DIAMOND "setUmaIdentifier(bytes32)" \
  $(cast format-bytes32-string "ASSERT_TRUTH2") \
  --rpc-url $RPC_URL --account <safe-signer>
```
Option B only works before ownership transfer (or via the Safe after transfer). Prefer Option A.

### 5b. Add `base` to `save-deployment.js`

[`script/save-deployment.js:38-41`](../script/save-deployment.js#L38-L41) only knows `base-sepolia` and `localhost`. Extend:

```js
const NETWORKS = {
  'base-sepolia': { chainId: 84532, explorer: 'https://sepolia.basescan.org' },
  'base':         { chainId: 8453,  explorer: 'https://basescan.org' },
  'localhost':    { chainId: 31337, explorer: 'http://localhost:8545' },
};
```

Without this change, step 8 below fails.

---

## 6. Dry-run on a mainnet fork

Always simulate first. A dry-run catches bad env values, missing dependencies, and reverts **before** you spend real ETH.

```bash
cd oddmaki-core
set -a && source .env.mainnet && set +a

forge script script/DeployOddMaki.s.sol:DeployOddMakiScript \
  --rpc-url $RPC_URL \
  --account deployer-mainnet \
  --sender $DEPLOYER_ADDRESS
# enter keystore password when prompted — simulation uses it but broadcasts nothing
```

Check the trace output:
- `Chain ID: 8453` (NOT 84532 — that would mean your RPC is pointing at Sepolia)
- `Deployer:` matches `DEPLOYER_ADDRESS`
- `Owner:` matches your Safe
- `Treasury:` matches `PROTOCOL_TREASURY`
- No `revert` or `require` failures
- Gas estimate is sane (~20–40M total across all txs)

If anything looks wrong, fix env and re-run the dry-run. Do not proceed to broadcast until the simulation is clean.

---

## 7. Broadcast + verify

```bash
forge script script/DeployOddMaki.s.sol:DeployOddMakiScript \
  --rpc-url $RPC_URL \
  --account deployer-mainnet \
  --sender $DEPLOYER_ADDRESS \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --slow
```

Flag-by-flag:
- `--account deployer-mainnet` — Foundry prompts for the keystore password and signs with that key.
- `--sender $DEPLOYER_ADDRESS` — needed so forge-script's static-analysis `msg.sender` matches the real broadcaster (avoids the "sender is not deployer" pitfall).
- `--broadcast` — actually sends the transactions.
- `--verify --etherscan-api-key` — submits every facet + the Diamond to Basescan for source verification as they confirm.
- `--slow` — waits for each tx to be mined before sending the next. **Use this on mainnet.** It protects you from nonce-race issues during a gas spike and from sending a later tx that depends on state from a not-yet-mined earlier one.

Expect ~1–3 minutes total. Keep the keystore password dialog in view; Foundry may prompt once per transaction depending on your version.

### If `--verify` partially fails

Basescan occasionally rate-limits or chokes on verifying large contracts mid-script. You can re-verify individual contracts afterwards:

```bash
forge verify-contract <contract-address> <ContractName> \
  --chain base \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --watch
```

The Diamond itself can be verified this way too — `forge verify-contract $DIAMOND OddMaki --chain base …`.

---

## 8. Save the deployment snapshot

After broadcast (and the `save-deployment.js` patch in §5b):

```bash
node script/save-deployment.js base v1.0.0 "Initial Base mainnet deployment"
```

This writes `deployments/base/v1.0.0.json` and mirrors it to `deployments/base/latest.json` — the same pattern the Sepolia history uses. Commit the result:

```bash
git add deployments/base/v1.0.0.json deployments/base/latest.json
git commit -m "deploy: initial Base mainnet v1.0.0"
```

---

## 9. Verify ownership was handed to the Safe

The deploy script auto-transfers ownership to `OWNER` at the end of `run()` when `OWNER != deployer` ([`DeployOddMaki.s.sol:151-155`](../script/DeployOddMaki.s.sol#L151-L155)). Confirm on-chain:

```bash
cast call $DIAMOND "owner()(address)" --rpc-url $RPC_URL
# → must equal your Safe multisig, NOT deployer-mainnet
```

If for any reason it still shows the deployer EOA (e.g., you forgot to set `OWNER`), transfer now before doing anything else:

```bash
cast send $DIAMOND "transferOwnership(address)" <safe-address> \
  --rpc-url $RPC_URL --account deployer-mainnet
```

Once ownership is with the Safe, the hot deployer EOA has no privileged authority over the protocol. A future compromise of that key cannot touch the Diamond.

---

## 10. Smoke tests on mainnet

Run these read-only checks to confirm configuration landed correctly. Substitute `$DIAMOND` with the deployed address.

```bash
export DIAMOND=0x...
export RPC=https://mainnet.base.org

# Owner is the Safe
cast call $DIAMOND "owner()(address)" --rpc-url $RPC

# CTF wired
cast call $DIAMOND "getCtfAddress()(address)" --rpc-url $RPC
# → must equal $CTF_ADDRESS

# UMA wired
cast call $DIAMOND "getUmaOracle()(address)" --rpc-url $RPC
# → 0x2aBf1Bd76655de80eDb3086114315Eec75AF500c

# UMA identifier is ASSERT_TRUTH2 (after §5a)
cast call $DIAMOND "getUmaIdentifier()(bytes32)" --rpc-url $RPC
# → 0x41535345... (hex of "ASSERT_TRUTH2")

# Protocol fee and treasury
cast call $DIAMOND "getProtocolFeeBps()(uint256)" --rpc-url $RPC      # → 50
cast call $DIAMOND "getProtocolTreasury()(address)" --rpc-url $RPC    # → your treasury

# Pyth wired
cast call $DIAMOND "getPythContract()(address)" --rpc-url $RPC
# → 0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a
```

Any mismatch here = fix via a Safe tx before announcing the deployment.

---

## 11. Confirm collateral was whitelisted

The deploy script whitelists `USDC_ADDRESS` automatically (non-mock path, before ownership transfer), sanity-checking `decimals() == 6` and logging `symbol()` during the run. Confirm on-chain:

```bash
cast call $DIAMOND "isCollateralWhitelisted(address)(bool)" \
  0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 --rpc-url $RPC
# → true
```

If you need to whitelist additional collateral later (e.g., a second stablecoin), do it via Safe multisig since the Diamond is now owned by the Safe:

```
Target: $DIAMOND
Function: setCollateralWhitelisted(address,bool)
Args: (<new collateral address>, true)
```

---

## 12. Quick-reference command table

| Task | Command |
|---|---|
| Create mainnet keystore | `cast wallet import deployer-mainnet --interactive` |
| List keystores | `cast wallet list` |
| Show mainnet address | `cast wallet address --account deployer-mainnet` |
| Check address has code | `cast code <addr> --rpc-url $RPC_URL` |
| Deploy CTF | `forge script script/DeployCTF.s.sol:DeployCTFScript --rpc-url $RPC_URL --account deployer-mainnet --sender $DEPLOYER_ADDRESS --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY` |
| Dry-run Diamond deploy | `forge script script/DeployOddMaki.s.sol:DeployOddMakiScript --rpc-url $RPC_URL --account deployer-mainnet --sender $DEPLOYER_ADDRESS` |
| Broadcast Diamond deploy | add `--broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY --slow` |
| Save snapshot | `node script/save-deployment.js base v1.0.0 "notes"` |
| Re-verify a contract | `forge verify-contract <addr> <Name> --chain base --etherscan-api-key $ETHERSCAN_API_KEY --watch` |

---

## Appendix A — Separation of testnet and mainnet workflows

The `--account <name>` flag is the sole thing that determines which key signs. Everything else (`.env`, `RPC_URL`, `DEPLOYER_ADDRESS`) is just data Forge reads. This means:

- **Testnet (unchanged):** `--account deployer` + `.env` (Sepolia values) → signs with Sepolia key.
- **Mainnet:** `--account deployer-mainnet` + `.env.mainnet` (mainnet values) → signs with mainnet key.

The two cannot cross-contaminate as long as:
1. You source the right env file before each run.
2. `DEPLOYER_ADDRESS` in the sourced env matches the `--account` keystore address.
3. You back up `~/.foundry/keystores/deployer-mainnet` separately.

## Appendix B — Sources for on-chain addresses

- UMA OptimisticOracleV3 addresses: [UMAprotocol/protocol — `packages/core/networks/8453.json`](https://github.com/UMAprotocol/protocol/blob/master/packages/core/networks/8453.json)
- Pyth contract addresses: [Pyth Network EVM contract reference](https://docs.pyth.network/price-feeds/contract-addresses/evm)
- USDC on Base: [Circle — Native USDC on Base](https://developers.circle.com/stablecoins/docs/usdc-on-main-networks)
