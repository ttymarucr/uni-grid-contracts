import type { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox-viem";
import "@nomicfoundation/hardhat-ethers";
import "@nomiclabs/hardhat-waffle";
// import "@tenderly/hardhat-tenderly";

const config: HardhatUserConfig = {
  defaultNetwork: "hardhat",
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
        url: "https://base-mainnet.g.alchemy.com/v2/_zTD3BWOgxR-BQ1lHisJL86d8LP8XBaF", // Replace with the actual Base mainnet RPC URL
        blockNumber: 28203460, // Replace with the desired block number for forking
      },
      chainId: 8453,
    },
    // virtual_base: {
    //   url: "https://virtual.base.rpc.tenderly.co/7fca977f-3859-498e-a29b-29e23db5fa69",
    //   chainId: 8453,
    //   currency: "VETH"
    // },
  },
  paths: {
    sources: "./src"
  },
  // tenderly: {
  //   // https://docs.tenderly.co/account/projects/account-project-slug
  //   project: "project",
  //   username: "ttymarucr",
  // },
};

export default config;
