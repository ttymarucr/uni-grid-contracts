// SPDX-License-Identifier: MIT
pragma abicoder v2;
pragma solidity ^0.7.0;

import "../libraries/DistributionWeights.sol";

interface IGridPositionManager {
    struct Position {
        uint256 tokenId; // Token ID of the position
        int24 tickLower; // Lower tick of the position
        int24 tickUpper; // Upper tick of the position
        uint128 liquidity; // Liquidity of the position
        uint256 index; // Index of the position in the positions array
    }

    struct PositionParams {
        int24 tickLower; // Lower tick of the position
        int24 tickUpper; // Upper tick of the position
        int24 currentTick; // Current tick of the pool
        uint256 positionsLength; // Total number of positions
        uint256 slippage; // Slippage for adding liquidity (in basis points, e.g., 100 = 1%)
        uint256 token0Amount; // Amount of token0 to deposit
        uint256 token1Amount; // Amount of token1 to deposit
        uint256 weight; // Weight of the position in the grid based on the distribution type
    }

    struct GridInfo {
        address pool; // Address of the Uniswap V3 pool
        address positionManager; // Address of the Uniswap V3 position manager
        uint256 gridStep; // Step size for the grid
        uint256 gridQuantity; // Quantity of positions in the grid
        uint24 fee; // Fee tier of the pool
        uint256 token0MinFees; // Minimum fees for token0
        uint256 token1MinFees; // Minimum fees for token1
        uint8 token0Decimals; // Decimals for token0
        uint8 token1Decimals; // Decimals for token1
        string token0Symbol; // Symbol for token0
        string token1Symbol; // Symbol for token1
        address token0; // Address of token0
        address token1; // Address of token1
    }

    enum GridType {
        NEUTRAL,
        BUY,
        SELL
    }

    // Events
    /**
     * @dev Emitted when liquidity is deposited.
     * @param owner Address of the depositor.
     * @param token0Amount Amount of token0 deposited.
     * @param token1Amount Amount of token1 deposited.
     */
    event Deposit(address indexed owner, uint256 token0Amount, uint256 token1Amount);

    /**
     * @dev Emitted when liquidity is withdrawn.
     * @param owner Address of the withdrawer.
     * @param token0Amount Amount of token0 deposited.
     * @param token1Amount Amount of token1 deposited.
     */
    event Withdraw(address indexed owner, uint256 token0Amount, uint256 token1Amount);

    /**
     * @dev Emitted when fees are compounded into liquidity.
     * @param owner Address of the caller.
     * @param accumulated0Fees Total token0 fees compounded.
     * @param accumulated1Fees Total token1 fees compounded.
     */
    event Compound(address indexed owner, uint256 accumulated0Fees, uint256 accumulated1Fees);

    /**
     * @dev Emitted when fees are collected from active positions.
     * @param owner The address of the owner who collected the fees.
     * @param amount0 The amount of token0 collected.
     * @param amount1 The amount of token1 collected.
     */
    event FeesCollected(address indexed owner, uint256 amount0, uint256 amount1);

    event GridStepUpdated(uint256 newGridStep);
    event GridQuantityUpdated(uint256 newGridQuantity);
    event MinFeesUpdated(uint256 token0MinFees, uint256 token1MinFees);

    /**
     * @dev Returns the address of the Uniswap V3 pool.
     * @return The address of the pool.
     */
    function getPool() external view returns (address);

    /**
     * @dev Returns the address of the Uniswap V3 position manager.
     * @return The address of the position manager.
     */
    function getPositionManager() external view returns (address);

    /**
     * @dev Returns the total grid quantity.
     * @return The total grid quantity.
     */
    function getGridQuantity() external view returns (uint256);

    /**
     * @dev Returns the grid step size.
     * @return The grid step size.
     */
    function getGridStep() external view returns (uint256);

    /**
     * @dev Deposits liquidity into grid positions.
     * @param token0Amount Amount of token0 to deposit.
     * @param token1Amount Amount of token1 to deposit.
     * @param slippage Maximum allowable slippage for adding liquidity (in basis points, e.g., 100 = 1%).
     * @param gridType The type of grid (NEUTRAL, BUY, SELL).
     * @param distributionType The type of liquidity distribution (FLAT, CURVED, LINEAR, SIGMOID, FIBONACCI, LOGARITHMIC).
     */
    function deposit(
        uint256 token0Amount,
        uint256 token1Amount,
        uint256 slippage,
        GridType gridType,
        DistributionWeights.DistributionType distributionType
    ) external;

    /**
     * @dev Withdraws all liquidity from active positions.
     *      Only callable by the contract owner.
     */
    function withdraw() external;

    /**
     * @dev Compounds collected fees into liquidity for active positions.
     * @param slippage Maximum allowable slippage for adding liquidity (in basis points, e.g., 100 = 1%).
     * @param gridType The type of grid (NEUTRAL, BUY, SELL).
     * @param distributionType The type of liquidity distribution (FLAT, CURVED, LINEAR, SIGMOID, FIBONACCI, LOGARITHMIC).
     */
    function compound(uint256 slippage, GridType gridType, DistributionWeights.DistributionType distributionType)
        external;

    /**
     * @dev Sweeps positions outside the price range and redeposits the collected tokens.
     * @param slippage Maximum allowable slippage for adding liquidity (in basis points, e.g., 100 = 1%).
     * @param gridType The type of grid (NEUTRAL, BUY, SELL).
     * @param distributionType The type of liquidity distribution (FLAT, CURVED, LINEAR, SIGMOID, FIBONACCI, LOGARITHMIC).
     */
    function sweep(uint256 slippage, GridType gridType, DistributionWeights.DistributionType distributionType)
        external;

    /**
     * @dev Closes all positions by burning them. Can only be called if activePositionIndexes.length is zero.
     *      Assumes all positions in the positions array have zero liquidity.
     *      Only callable by the contract owner.
     */
    function close() external;

    /**
     * @dev Collects all fees from active positions and sends them to the owner.
     *      Only callable by the contract owner.
     */
    function collectFees() external;

    /**
     * @dev Sets the grid step size.
     *      Only callable by the contract owner.
     * @param _newGridStep New grid step size.
     */
    function setGridStep(uint256 _newGridStep) external;

    /**
     * @dev Sets the grid quantity.
     *      Only callable by the contract owner.
     * @param _newGridQuantity New grid quantity.
     */
    function setGridQuantity(uint256 _newGridQuantity) external;

    /**
     * @dev Sets the minimum fees for token0 and token1.
     *      Only callable by the contract owner.
     * @param _token0MinFees New minimum fees for token0.
     * @param _token1MinFees New minimum fees for token1.
     */
    function setMinFees(uint256 _token0MinFees, uint256 _token1MinFees) external;

    /**
     * @dev Returns the total number of positions.
     * @return The length of the positions array.
     */
    function getPositionsLength() external view returns (uint256);

    /**
     * @dev Returns the indexes of active positions.
     * @return An array of active position indexes.
     */
    function getActivePositionIndexes() external view returns (uint256[] memory);

    /**
     * @dev Returns the details of a position by its index.
     * @param index The index of the position.
     * @return The position details.
     */
    function getPosition(uint256 index) external view returns (Position memory);

    /**
     * @dev Returns the details of all active positions.
     * @return An array of active positions.
     */
    function getActivePositions() external view returns (Position[] memory);

    /**
     * @dev Returns detailed information about the grid and pool.
     * @return A GridInfo struct containing pool and grid details.
     */
    function getPoolInfo() external view returns (GridInfo memory);

    /**
     * @dev Returns the total liquidity of token0 and token1 across all active positions.
     * @return token0Liquidity Total liquidity of token0.
     * @return token1Liquidity Total liquidity of token1.
     */
    function getLiquidity() external view returns (uint256 token0Liquidity, uint256 token1Liquidity);

    /**
     * @dev Checks if the current pool tick is inside any of the active positions.
     * @return True if the current tick is inside an active position, false otherwise.
     */
    function isInRange() external view returns (bool);
}
