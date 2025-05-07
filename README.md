# Uniswap V3 Grid Strategy

## Overview

This repository provides a set of smart contracts and tools designed to implement a grid trading strategy on Uniswap V3. Grid trading is a systematic trading approach that places buy and sell orders at predefined price intervals, enabling automated and efficient liquidity management.

## Purpose

The purpose of this project is to leverage Uniswap V3's concentrated liquidity model to implement a grid trading strategy. By utilizing the flexibility of Uniswap V3, these contracts allow users to optimize their liquidity positions, capture profits from price fluctuations within a specified range, and customize liquidity distribution across grid positions. The ability to distribute liquidity using various strategies, such as flat, linear, Fibonacci, and more, provides users with enhanced control and adaptability to different market conditions.

## Features

- **Automated Liquidity Management**: Deploy and manage liquidity positions across multiple price ranges.
- **Profit Capture**: Automatically execute buy and sell orders as prices move within the grid.
- **Customizable Parameters**: Define grid intervals, price ranges, and liquidity amounts to suit your strategy.
- **Liquidity Distribution**: Distribute liquidity across grid positions using various distribution types, such as flat, linear, reverse linear, Fibonacci, and more.
- **Gas Optimization**: Efficiently manage transactions to minimize gas costs.

## Use Cases

1. **Passive Income Generation**: Earn fees by providing liquidity within a grid structure.
2. **Market Making**: Facilitate trading by maintaining liquidity across a range of prices.
3. **Hedging Strategies**: Use grid trading to hedge against price volatility.

## Liquidity Distribution

The contracts support multiple liquidity distribution types to suit different trading strategies:

- **Flat Distribution**: Equal weight across all grid intervals.
- **Linear Distribution**: Increasing weight from the first to the last interval.
- **Reverse Linear Distribution**: Decreasing weight from the first to the last interval.
- **Fibonacci Distribution**: Weights based on the Fibonacci sequence.
- **Sigmoid Distribution**: (Not implemented) Typically creates an S-shaped curve.
- **Logarithmic Distribution**: (Not implemented) Typically creates a logarithmic curve.

These distribution types allow users to customize how liquidity is allocated across the grid, optimizing for specific market conditions or strategies.

## Error Codes and Descriptions

- **E01**: The pool address cannot be zero.
- **E02**: The position manager address cannot be zero.
- **E03**: The grid quantity must be greater than 0 and less than or equal to 1,000.
- **E04**: The grid step must be greater than 0 and less than or equal to 10,000.
- **E05**: Invalid token amounts for the specified grid type.
- **E06**: Slippage must be less than or equal to 500 basis points (5%).
- **E07**: Exceeded the maximum number of active positions (1,000).
- **E08**: Ticks must align with the pool's tick spacing.
- **E09**: No tokens or Ether available for the operation.
- **E10**: Price deviation exceeds the maximum allowable deviation.
- **E11**: Position not found or invalid token ID.
- **E12**: Missing required token1 amount for the BUY grid type.
- **E13**: Missing required token0 amount for the SELL grid type.
- **E14**: Missing required token amount for adding liquidity.
- **E99**: Distribution type not implemented (e.g., Sigmoid or Logarithmic).

## Getting Started

To use or contribute to this project, follow these steps:

1. Clone the repository:
    ```bash
    git clone https://github.com/ttymarucr/uni-grid-contracts.git
    ```
2. Install dependencies:
    ```bash
    yarn install
    ```
3. Configure your environment by setting up the required variables.
4. Deploy the smart contracts to your preferred blockchain network:
    ```bash
    npx hardhat deploy --network <network-name>
    ```
5. Interact with the contracts using the provided scripts or integrate them into your application.

## Contributing

Contributions are welcome! Please submit issues or pull requests to help improve the project. For major changes, please open an issue first to discuss your ideas.

## License

This project is licensed under the [MIT License](LICENSE).