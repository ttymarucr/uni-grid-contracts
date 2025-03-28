import type { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox-viem";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.7.6", // Updated to match the contract's Solidity version
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  networks: {
    hardhat: {
      forking: {
        url: "https://mainnet.base.org", // Replace with the actual Base mainnet RPC URL
      },
    },
  },
  paths: {
    sources: "./src"
  },
};

export default config;
