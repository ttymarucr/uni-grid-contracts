# Uniswap V3 Grid Strategy

## Overview

This repository provides a set of smart contracts and tools designed to implement a grid trading strategy on Uniswap V3. Grid trading is a systematic trading approach that places buy and sell orders at predefined price intervals, enabling automated and efficient liquidity management.

## Purpose

The purpose of this project is to leverage Uniswap V3's concentrated liquidity model to implement a grid trading strategy. By utilizing the flexibility of Uniswap V3, these contracts allow users to optimize their liquidity positions and capture profits from price fluctuations within a specified range.

## Features

- **Automated Liquidity Management**: Deploy and manage liquidity positions across multiple price ranges.
- **Profit Capture**: Automatically execute buy and sell orders as prices move within the grid.
- **Customizable Parameters**: Define grid intervals, price ranges, and liquidity amounts to suit your strategy.
- **Gas Optimization**: Efficiently manage transactions to minimize gas costs.

## Use Cases

1. **Passive Income Generation**: Earn fees by providing liquidity within a grid structure.
2. **Market Making**: Facilitate trading by maintaining liquidity across a range of prices.
3. **Hedging Strategies**: Use grid trading to hedge against price volatility.

## Error Codes and Descriptions

- **E01**: Pool address cannot be zero.
- **E02**: Position manager address cannot be zero.
- **E03**: Grid quantity must be greater than zero.
- **E04**: Grid step must be greater than zero.
- **E05**: For NEUTRAL grid type, both token0 and token1 amounts must be greater than zero.
- **E06**: Slippage must be less than or equal to 500 basis points (5%).
- **E07**: Invalid grid configuration. Ensure `tickLower` is less than `tickUpper` and grid count is valid.
- **E08**: Ticks must align with the pool's tick spacing.
- **E09**: Grid step must be greater than zero and less than 10,000.
- **E10**: Grid quantity must be greater than zero and less than 10,000.
- **E11**: Distribution type not implemented (e.g., SIGMOID or LOGARITHMIC).
- **E12**: Cannot close positions while there are active positions.
- **E13**: No Ether balance to recover.
- **E14**: Price deviation exceeds the maximum allowable deviation or invalid token amounts for BUY/SELL grid types.
- **E15**: Position index out of bounds.

## Getting Started

To use or contribute to this project, follow these steps:

1. Clone the repository:
    ```bash
    git clone https://github.com/your-repo/uni-grid-contracts.git
    ```
2. Install dependencies:
    ```bash
    npm install
    ```
3. Configure your environment by setting up the required variables in a `.env` file.
4. Deploy the smart contracts to your preferred blockchain network:
    ```bash
    npx hardhat deploy --network <network-name>
    ```
5. Interact with the contracts using the provided scripts or integrate them into your application.

## Contributing

Contributions are welcome! Please submit issues or pull requests to help improve the project. For major changes, please open an issue first to discuss your ideas.

## License

This project is licensed under the [MIT License](LICENSE).