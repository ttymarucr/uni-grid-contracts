// SPDX-License-Identifier: MIT
pragma abicoder v2;
pragma solidity ^0.7.0;

interface IGridPositionManager {
    struct Position {
        uint256 tokenId; // Token ID of the position
        int24 tickLower; // Lower tick of the position
        int24 tickUpper; // Upper tick of the position
        uint128 liquidity; // Liquidity of the position
        uint256 index; // Index of the position in the positions array
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
     * @dev Emitted when the owner performs an emergency withdrawal.
     * @param owner Address of the owner performing the withdrawal.
     * @param token0Amount Amount of token0 withdrawn.
     * @param token1Amount Amount of token1 withdrawn.
     */
    event EmergencyWithdraw(address indexed owner, uint256 token0Amount, uint256 token1Amount);

    function getPool() external view returns (address);
    function getPositionManager() external view returns (address);
    function getGridQuantity() external view returns (uint256);
    function getGridStep() external view returns (uint256);

    /**
     * @dev Deposits liquidity into grid positions.
     * @param token0Amount Amount of token0 to deposit.
     * @param token1Amount Amount of token1 to deposit.
     * @param slippage Maximum allowable slippage for adding liquidity (in basis points, e.g., 100 = 1%).
     */
    function deposit(uint256 token0Amount, uint256 token1Amount, uint256 slippage) external;

    /**
     * @dev Withdraws all liquidity from active positions.
     *      Only callable by the contract owner.
     */
    function withdraw() external;

    /**
     * @dev Compounds collected fees into liquidity for active positions.
     * @param slippage Maximum allowable slippage for adding liquidity (in basis points, e.g., 100 = 1%).
     */
    function compound(uint256 slippage) external;

    /**
     * @dev Sweeps positions outside the price range and redeposits the collected tokens.
     * @param slippage Maximum allowable slippage for adding liquidity (in basis points, e.g., 100 = 1%).
     */
    function sweep(uint256 slippage) external;

    /**
     * @dev Updates the grid step size.
     *      Only callable by the contract owner.
     * @param _newGridStep New grid step size.
     */
    function updateGridStep(uint256 _newGridStep) external;

    /**
     * @dev Updates the grid quantity.
     *      Only callable by the contract owner.
     * @param _newgridQuantity New grid quantity.
     */
    function updategridQuantity(uint256 _newgridQuantity) external;

    /**
     * @dev Updates the minimum fees for token0 and token1.
     *      Only callable by the contract owner.
     * @param _token0MinFees New minimum fees for token0.
     * @param _token1MinFees New minimum fees for token1.
     */
    function updateMinFees(uint256 _token0MinFees, uint256 _token1MinFees) external;

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
}
