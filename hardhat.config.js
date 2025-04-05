require("@nomicfoundation/hardhat-toolbox");

// Load environment variables (.env file)
require("dotenv").config({ silent: true });

// Define constants for readability (optional)
const ALCHEMY_API_KEY = process.env.ALCHEMY_API_KEY || "YOUR_DEFAULT_ALCHEMY_KEY_HERE"; // Replace with a placeholder or ensure .env exists
const MAINNET_FORK_URL = `https://eth-mainnet.g.alchemy.com/v2/DL2Hs7iCi5K22CtMp9lrL3OTNyvyTnHv`;

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    compilers: [
      {
        version: "0.8.19", // For FlashSwap.sol
        settings: {
          optimizer: { enabled: true, runs: 200 }, // Basic optimizer settings
        },
      },
      {
        version: "0.7.6", // For Uniswap V3 Periphery compatibility
        settings: {
          optimizer: { enabled: true, runs: 200 },
        },
      },
    ],
  },
  networks: {
    hardhat: {
      // Configuration for the local Hardhat Network when run with --network hardhat
      forking: {
        url: MAINNET_FORK_URL,
        // Optional: Pin block number for consistent fork state during testing
        // blockNumber: 19000000 // Example block number
      },
      // Increase timeout for potentially long-running fork tests/scripts
      // timeout: 120000 // 120 seconds
    },
    // Add other networks like sepolia, mainnet later if needed for deployment
    // sepolia: {
    //   url: process.env.SEPOLIA_RPC_URL || "",
    //   accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
    // },
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts",
  },
  etherscan: {
    // Add your Etherscan API key for verification (best practice: use env variable)
    apiKey: process.env.ETHERSCAN_API_KEY || "",
  },
  // Optional: Gas reporter configuration
  // gasReporter: {
  //   enabled: process.env.REPORT_GAS !== undefined,
  //   currency: "USD",
  // },
};
