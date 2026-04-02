#!/usr/bin/env node

// Saves a deployment snapshot from Forge broadcast data into deployments/<network>/<version>.json
// and updates deployments/<network>/latest.json as a quick reference.
//
// Usage:
//   node script/save-deployment.js <network> <version> [notes]
//
// Examples:
//   node script/save-deployment.js base-sepolia v1.0.0
//   node script/save-deployment.js base-sepolia v1.1.0 "Added market orders"
//   node script/save-deployment.js localhost v0.1.0

const fs = require('fs');
const path = require('path');

// Load .env file into process.env (simple parser, no dependencies)
function loadEnvFile() {
  const envPath = path.join(__dirname, '..', '.env');
  if (!fs.existsSync(envPath)) return;
  const lines = fs.readFileSync(envPath, 'utf8').split('\n');
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eqIndex = trimmed.indexOf('=');
    if (eqIndex === -1) continue;
    const key = trimmed.slice(0, eqIndex).trim();
    const value = trimmed.slice(eqIndex + 1).trim().replace(/^["']|["']$/g, '');
    if (!process.env[key]) {
      process.env[key] = value;
    }
  }
}

loadEnvFile();

// Network configuration
const NETWORKS = {
  'base-sepolia': { chainId: 84532, explorer: 'https://sepolia.basescan.org' },
  'localhost': { chainId: 31337, explorer: 'http://localhost:8545' },
};

// Parse command line arguments
function parseArgs() {
  const args = process.argv.slice(2);

  if (args.length < 2) {
    console.error('Usage: node save-deployment.js <network> <version> [notes]');
    console.error('Example: node save-deployment.js base-sepolia v1.1.0 "Added new features"');
    console.error(`\nAvailable networks: ${Object.keys(NETWORKS).join(', ')}`);
    process.exit(1);
  }

  const network = args[0];
  const version = args[1];
  const notes = args[2] || '';

  if (!NETWORKS[network]) {
    console.error(`Error: Unknown network "${network}"`);
    console.error(`Available networks: ${Object.keys(NETWORKS).join(', ')}`);
    process.exit(1);
  }

  // Validate version format (v1.2.3 or 1.2.3)
  const versionPattern = /^v?\d+\.\d+\.\d+$/;
  if (!versionPattern.test(version)) {
    console.error(`Error: Invalid version format "${version}"`);
    console.error('Expected format: v1.2.3 or 1.2.3');
    process.exit(1);
  }

  // Ensure version starts with 'v'
  const normalizedVersion = version.startsWith('v') ? version : `v${version}`;

  return { network, version: normalizedVersion, notes };
}

// Read the run-latest.json file
function readBroadcastFile(network) {
  const chainId = NETWORKS[network].chainId;
  const broadcastPath = path.join(
    __dirname,
    '..',
    'broadcast',
    'DeployOddMaki.s.sol',
    chainId.toString(),
    'run-latest.json'
  );

  if (!fs.existsSync(broadcastPath)) {
    console.error(`Error: Broadcast file not found at ${broadcastPath}`);
    console.error('Make sure you have deployed to this network first.');
    process.exit(1);
  }

  const data = fs.readFileSync(broadcastPath, 'utf8');
  return JSON.parse(data);
}

// Extract contract addresses from broadcast data
function extractContracts(broadcastData) {
  const contracts = {};

  // Diamond proxy — the main protocol entry point
  // All facets are implementation contracts behind this single address
  const DIAMOND_CONTRACTS = [
    'OddMaki',
    'DiamondCutFacet',
    'DiamondLoupeFacet',
    'OwnershipFacet',
    'VaultFacet',
    'MarketsFacet',
    'LimitOrdersFacet',
    'NegRiskFacet',
    'MatchingFacet',
    'VenueFacet',
    'OrderBookFacet',
    'ProtocolFacet',
    'MarketGroupFacet',
    'MarketOrdersFacet',
    'ResolutionFacet',
  ];

  for (const tx of broadcastData.transactions) {
    if (tx.transactionType === 'CREATE' && tx.contractAddress) {
      const name = tx.contractName;

      if (DIAMOND_CONTRACTS.includes(name)) {
        contracts[name] = tx.contractAddress;
      }

      // Mock contracts (local / testnet)
      if (name === 'MockERC20') contracts.USDC = tx.contractAddress;
      if (name === 'MockCTF') contracts.ConditionalTokens = tx.contractAddress;
      if (name === 'MockUmaOracle') contracts.UmaOracle = tx.contractAddress;
    }
  }

  // For production deployments, CTF and UMA addresses come from env vars
  // and appear as CALL transactions (setCtf, setUmaOracle) rather than CREATE.
  // Extract them from the config calls if not already set from mocks.
  if (!contracts.ConditionalTokens || !contracts.UmaOracle) {
    for (const tx of broadcastData.transactions) {
      if (tx.transactionType === 'CALL' && tx.function) {
        // setCtf(address) → extract CTF address
        if (!contracts.ConditionalTokens && tx.function.startsWith('setCtf(') && tx.arguments) {
          contracts.ConditionalTokens = tx.arguments[0];
        }
        // setUmaOracle(address) → extract UMA address
        if (!contracts.UmaOracle && tx.function.startsWith('setUmaOracle(') && tx.arguments) {
          contracts.UmaOracle = tx.arguments[0];
        }
      }
    }
  }

  // Final fallback: read from environment variables for pre-existing contracts
  // (e.g. real CTF/USDC deployments that aren't created by our deploy script)
  if (!contracts.ConditionalTokens && process.env.CTF_ADDRESS) {
    contracts.ConditionalTokens = process.env.CTF_ADDRESS;
    console.log(`  ConditionalTokens: using CTF_ADDRESS from env`);
  }
  if (!contracts.USDC && process.env.USDC_ADDRESS) {
    contracts.USDC = process.env.USDC_ADDRESS;
    console.log(`  USDC: using USDC_ADDRESS from env`);
  }
  if (!contracts.UmaOracle && process.env.UMA_ORACLE_ADDRESS) {
    contracts.UmaOracle = process.env.UMA_ORACLE_ADDRESS;
    console.log(`  UmaOracle: using UMA_ORACLE_ADDRESS from env`);
  }

  return contracts;
}

// Create deployment JSON structure
function createDeploymentData(network, version, contracts, notes) {
  const networkConfig = NETWORKS[network];

  const deployment = {
    network: network,
    chainId: networkConfig.chainId,
    version: version.replace(/^v/, ''), // Remove 'v' prefix for version field
    timestamp: new Date().toISOString(),
    contracts: contracts
  };

  // Add links for testnet
  if (network === 'base-sepolia') {
    deployment.links = {
      usdcFaucet: 'https://faucet.circle.com/',
      ethFaucet: 'https://www.coinbase.com/faucets/base-ethereum-sepolia-faucet',
      explorer: networkConfig.explorer
    };
  } else {
    deployment.links = {
      explorer: networkConfig.explorer
    };
  }

  // Add notes if provided
  if (notes) {
    deployment.notes = notes;
  }

  return deployment;
}

// Save deployment file
function saveDeployment(network, version, deploymentData) {
  const deploymentDir = path.join(__dirname, '..', 'deployments', network);

  // Create directory if it doesn't exist
  if (!fs.existsSync(deploymentDir)) {
    fs.mkdirSync(deploymentDir, { recursive: true });
  }

  const deploymentPath = path.join(deploymentDir, `${version}.json`);

  // Check if file already exists
  if (fs.existsSync(deploymentPath)) {
    console.warn(`Warning: Deployment file already exists at ${deploymentPath}`);
    console.warn('Overwriting...');
  }

  const jsonContent = JSON.stringify(deploymentData, null, 2) + '\n';
  fs.writeFileSync(deploymentPath, jsonContent);

  // Also write/update latest.json as a quick reference
  const latestPath = path.join(deploymentDir, 'latest.json');
  fs.writeFileSync(latestPath, jsonContent);

  console.log(`✅ Deployment saved to ${deploymentPath}`);
  console.log(`✅ Latest reference updated at ${latestPath}`);
  console.log(`\nContracts deployed:`);
  for (const [name, address] of Object.entries(deploymentData.contracts)) {
    console.log(`  ${name.padEnd(20)} ${address}`);
  }
}

// Main execution
function main() {
  try {
    const { network, version, notes } = parseArgs();

    console.log(`📝 Saving deployment for ${network} ${version}...`);

    const broadcastData = readBroadcastFile(network);
    console.log(`✓ Read broadcast data from chain ${broadcastData.chain}`);

    const contracts = extractContracts(broadcastData);
    console.log(`✓ Extracted ${Object.keys(contracts).length} contract addresses`);

    const deploymentData = createDeploymentData(network, version, contracts, notes);

    saveDeployment(network, version, deploymentData);

  } catch (error) {
    console.error(`Error: ${error.message}`);
    process.exit(1);
  }
}

main();
