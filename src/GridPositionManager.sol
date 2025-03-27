// SPDX-License-Identifier: MIT
pragma abicoder v2;
pragma solidity ^0.7.0;

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IERC20Metadata.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";

/**
 * @title GridPositionManager
 * @dev Manages grid-based liquidity positions on Uniswap V3.
 *      Allows depositing, withdrawing, compounding, and sweeping liquidity positions.
 */
contract GridPositionManager is Ownable, ReentrancyGuard {
    using SafeMath for uint256;

    struct Position {
        uint256 tokenId; // Token ID of the position
        int24 tickLower; // Lower tick of the position
        int24 tickUpper; // Upper tick of the position
        uint128 liquidity; // Liquidity of the position
        uint256 index; // Index of the position in the positions array
    }

    IUniswapV3Pool public immutable pool; // Uniswap V3 pool
    INonfungiblePositionManager public immutable positionManager; // Position manager for Uniswap V3

    Position[] public positions; // Array of all positions
    uint256 public gridQuantity; // Total grid quantity
    uint256 public gridStep; // Step size for grid prices

    uint256[] public activePositionIndexes; // List of indexes for active positions with liquidity

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

    /**
     * @dev Constructor to initialize the contract.
     * @param _pool Address of the Uniswap V3 pool.
     * @param _positionManager Address of the Uniswap V3 position manager.
     * @param _gridQuantity Total grid quantity.
     * @param _gridStep Step size for grid prices.
     */
    constructor(address _pool, address _positionManager, uint256 _gridQuantity, uint256 _gridStep) {
        require(_pool != address(0), "E1"); // E1: Invalid pool address
        require(_positionManager != address(0), "E2"); // E2: Invalid position manager address
        require(_gridQuantity > 0, "E3"); // E3: Grid range percentage must be greater than 0
        require(_gridStep > 0, "E4"); // E4: Grid step must be greater than 0

        pool = IUniswapV3Pool(_pool);
        positionManager = INonfungiblePositionManager(_positionManager);
        gridQuantity = _gridQuantity;
        gridStep = _gridStep;
    }

    /**
     * @dev Deposits liquidity into grid positions.
     * @param token0Amount Amount of token0 to deposit.
     * @param token1Amount Amount of token1 to deposit.
     */
    function deposit(uint256 token0Amount, uint256 token1Amount) public nonReentrant {
        require(token0Amount > 0 && token1Amount > 0, "E5"); // E5: Token0 and Token1 amount must be greater than 0

        // Fetch the current pool price
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        uint256 targetPrice = uint256(sqrtPriceX96).mul(uint256(sqrtPriceX96)).div(1 << 192);

        // Transfer tokens to the contract using TransferHelper
        TransferHelper.safeTransferFrom(pool.token0(), msg.sender, address(this), token0Amount);
        TransferHelper.safeTransferFrom(pool.token1(), msg.sender, address(this), token1Amount);

        uint256[] memory gridPrices = calculateGridPrices(targetPrice);
        require(gridPrices.length > 2, "Invalid grid prices");

        uint256 gridLength = gridPrices.length - 1;
        uint256 halfGridLength = gridLength.div(2);

        for (uint256 i = 0; i < gridLength; i++) {
            uint256 lowerPrice = gridPrices[i];
            uint256 upperPrice = gridPrices[i + 1];
            uint256 amount0Desired = 0;
            uint256 amount1Desired = 0;

            if (upperPrice < targetPrice) {
                amount0Desired = token0Amount.div(halfGridLength);
            } else if (lowerPrice > targetPrice) {
                amount1Desired = token1Amount.div(halfGridLength);
            } else {
                continue; // Skip middle grid
            }

            int24 tickLower = getTickFromPrice(lowerPrice);
            int24 tickUpper = getTickFromPrice(upperPrice);

            // Check if the position already exists
            (uint256 existingTokenId, uint256 index) = getPositionFromTicks(tickLower, tickUpper);
            if (existingTokenId > 0) {
                // Add liquidity to the existing position
                (uint128 newLiquidity,,) = positionManager.increaseLiquidity(
                    INonfungiblePositionManager.IncreaseLiquidityParams({
                        tokenId: existingTokenId,
                        amount0Desired: amount0Desired,
                        amount1Desired: amount1Desired,
                        amount0Min: amount0Desired,
                        amount1Min: amount1Desired,
                        deadline: block.timestamp + 1 hours
                    })
                );
                positions[index].liquidity = newLiquidity;
                if (!isActivePosition(index)) {
                    activePositionIndexes.push(index);
                }
                continue;
            }

            // Mint position and store the token ID
            (uint256 tokenId, uint128 liquidity,,) = positionManager.mint(
                INonfungiblePositionManager.MintParams({
                    token0: pool.token0(),
                    token1: pool.token1(),
                    fee: pool.fee(),
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    amount0Desired: amount0Desired,
                    amount1Desired: amount1Desired,
                    amount0Min: amount0Desired,
                    amount1Min: amount1Desired,
                    recipient: address(this),
                    deadline: block.timestamp + 1 hours
                })
            );

            // Store the position in the array
            positions.push(
                Position({
                    tokenId: tokenId,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidity: liquidity,
                    index: positions.length
                })
            );

            // Add the new position to the active positions list
            activePositionIndexes.push(positions.length - 1); // Use positions.length - 1 directly
        }

        emit Deposit(msg.sender, token0Amount, token1Amount);
    }

    /**
     * @dev Withdraws all liquidity from active positions.
     *      Only callable by the contract owner.
     */
    function withdraw() external onlyOwner nonReentrant {
        for (uint256 i = 0; i < activePositionIndexes.length; i++) {
            uint256 index = activePositionIndexes[i];
            uint256 tokenId = positions[index].tokenId;
            uint128 liquidity = positions[index].liquidity;

            // Collect fees and remove liquidity
            if (liquidity > 0) {
                positionManager.decreaseLiquidity(
                    INonfungiblePositionManager.DecreaseLiquidityParams({
                        tokenId: tokenId,
                        liquidity: liquidity,
                        amount0Min: 0,
                        amount1Min: 0,
                        deadline: block.timestamp + 1 hours
                    })
                );

                positionManager.collect(
                    INonfungiblePositionManager.CollectParams({
                        tokenId: tokenId,
                        recipient: address(this),
                        amount0Max: type(uint128).max,
                        amount1Max: type(uint128).max
                    })
                );

                // Remove the position from the active positions list
                removeActivePosition(index);
            }
        }
        uint256 accumulated0Fees = IERC20Metadata(pool.token0()).balanceOf(address(this));
        uint256 accumulated1Fees = IERC20Metadata(pool.token1()).balanceOf(address(this));
        if (accumulated0Fees > 0) {
            TransferHelper.safeTransfer(pool.token0(), msg.sender, accumulated0Fees);
        }
        if (accumulated1Fees > 0) {
            TransferHelper.safeTransfer(pool.token1(), msg.sender, accumulated1Fees);
        }
        emit Withdraw(msg.sender, accumulated0Fees, accumulated1Fees);
    }

    /**
     * @dev Compounds collected fees into liquidity for active positions.
     * @param slippage Maximum allowable slippage for adding liquidity (in basis points, e.g., 100 = 1%).
     */
    function compound(uint256 slippage) external nonReentrant {
        require(slippage <= 10000, "E11"); // E11: Slippage must be less than or equal to 10000 (100%)

        uint256 accumulated0Fees = IERC20Metadata(pool.token0()).balanceOf(address(this));
        uint256 accumulated1Fees = IERC20Metadata(pool.token1()).balanceOf(address(this));
        for (uint256 i = 0; i < activePositionIndexes.length; i++) {
            uint256 index = activePositionIndexes[i];
            uint256 tokenId = positions[index].tokenId;
            // Collect fees
            (uint256 amount0Collected, uint256 amount1Collected) = positionManager.collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: tokenId,
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );
            accumulated0Fees = accumulated0Fees.add(amount0Collected);
            accumulated1Fees = accumulated1Fees.add(amount1Collected);
        }

        // Fetch the current pool price
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        uint256 currentPrice = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) / (1 << 192);

        if (accumulated0Fees > 0 || accumulated1Fees > 0) {
            // Determine the current pool position based on the price
            for (uint256 i = 0; i < activePositionIndexes.length; i++) {
                uint256 index = activePositionIndexes[i];
                if (
                    currentPrice >= uint256(TickMath.getSqrtRatioAtTick(positions[index].tickLower))
                        && currentPrice <= uint256(TickMath.getSqrtRatioAtTick(positions[index].tickUpper))
                ) {
                    uint256 tokenId = positions[index].tokenId;

                    // Calculate slippage-adjusted minimum amounts
                    uint256 amount0Slippage = accumulated0Fees.mul(uint256(10000).sub(slippage)).div(10000);
                    uint256 amount1Slippage = accumulated1Fees.mul(uint256(10000).sub(slippage)).div(10000);

                    // Add collected fees back into this position as liquidity
                    (uint128 newLiquidity, uint256 amount0, uint256 amount1) = positionManager.increaseLiquidity(
                        INonfungiblePositionManager.IncreaseLiquidityParams({
                            tokenId: tokenId,
                            amount0Desired: accumulated0Fees,
                            amount1Desired: accumulated1Fees,
                            amount0Min: amount0Slippage,
                            amount1Min: amount1Slippage,
                            deadline: block.timestamp + 1 hours
                        })
                    );
                    positions[index].liquidity = newLiquidity;
                    emit Compound(msg.sender, amount0, amount1);
                    break;
                }
            }
        }
    }

    /**
     * @dev Sweeps positions outside the price range and redeposits the collected tokens.
     */
    function sweep() external {
        // Fetch the current pool price
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        uint256 currentPrice = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) / (1 << 192);

        uint256 priceDiff = (gridQuantity / 2) * gridStep;
        uint256 lowerBound = currentPrice - priceDiff;
        uint256 upperBound = currentPrice + priceDiff;

        for (uint256 i = 0; i < activePositionIndexes.length; i++) {
            uint256 index = activePositionIndexes[i];
            uint256 tokenId = positions[index].tokenId;
            uint128 liquidity = positions[index].liquidity;

            // Check if the position is outside the price range
            uint256 positionLowerPrice =
                uint256(TickMath.getSqrtRatioAtTick(positions[index].tickLower)) ** 2 / (1 << 192);
            uint256 positionUpperPrice =
                uint256(TickMath.getSqrtRatioAtTick(positions[index].tickUpper)) ** 2 / (1 << 192);

            if (positionUpperPrice < lowerBound || positionLowerPrice > upperBound) {
                // Remove liquidity from the position
                positionManager.decreaseLiquidity(
                    INonfungiblePositionManager.DecreaseLiquidityParams({
                        tokenId: tokenId,
                        liquidity: liquidity,
                        amount0Min: 0,
                        amount1Min: 0,
                        deadline: block.timestamp + 1 hours
                    })
                );

                // Collect fees and tokens
                positionManager.collect(
                    INonfungiblePositionManager.CollectParams({
                        tokenId: tokenId,
                        recipient: address(this),
                        amount0Max: type(uint128).max,
                        amount1Max: type(uint128).max
                    })
                );

                // Remove the position from the active positions list
                removeActivePosition(index);

                // Update the position's liquidity to 0
                positions[index].liquidity = 0;
            }
        }
        uint256 accumulated0Fees = IERC20Metadata(pool.token0()).balanceOf(address(this));
        uint256 accumulated1Fees = IERC20Metadata(pool.token1()).balanceOf(address(this));
        if (accumulated0Fees > 0 || accumulated1Fees > 0) {
            deposit(accumulated0Fees, accumulated1Fees);
        }
    }

    /**
     * @dev Updates the grid step size.
     *      Only callable by the contract owner.
     * @param _newGridStep New grid step size.
     */
    function updateGridStep(uint256 _newGridStep) external onlyOwner {
        require(_newGridStep > 0 && _newGridStep < 10000, "E6"); // E6: Grid step must be greater than 0 and less than 10000
        gridStep = _newGridStep;
    }

    /**
     * @dev Updates the grid quantity.
     *      Only callable by the contract owner.
     * @param _newgridQuantity New grid quantity.
     */
    function updategridQuantity(uint256 _newgridQuantity) external onlyOwner {
        require(
            _newgridQuantity > 0 && _newgridQuantity < 10000,
            "E7" // E7: Price range percentage must be greater than 0 and less than 10000
        );
        gridQuantity = _newgridQuantity;
    }

    /**
     * @dev Returns the total number of positions.
     * @return The length of the positions array.
     */
    function getPositionsLength() external view returns (uint256) {
        return positions.length;
    }

    /**
     * @dev Returns the indexes of active positions.
     * @return An array of active position indexes.
     */
    function getActivePositionIndexes() external view returns (uint256[] memory) {
        return activePositionIndexes;
    }

    /**
     * @dev Calculates grid prices based on the target price.
     * @param targetPrice The target price for the grid.
     * @return An array of grid prices.
     */
    function calculateGridPrices(uint256 targetPrice) internal view returns (uint256[] memory) {
        require(gridQuantity > 0, "E8"); // E8: Price range percentage must be greater than 0
        uint256 priceDiff = (gridQuantity / 2) * gridStep;
        uint256 lowerPrice = targetPrice - priceDiff;
        uint256 upperPrice = targetPrice + priceDiff;

        uint256 gridCount = (upperPrice - lowerPrice).div(gridStep);
        require(gridCount > 0, "E9"); // E9: Grid count must be greater than 0

        uint256[] memory gridPrices = new uint256[](gridCount + 1);
        uint256 currentPrice = lowerPrice;
        for (uint256 i = 0; i <= gridCount; i++) {
            gridPrices[i] = currentPrice;
            currentPrice += gridStep; // Avoid recalculating lowerPrice + (i * gridStep)
        }

        return gridPrices;
    }

    /**
     * @dev Finds a position by its lower and upper ticks.
     * @param tickLower The lower tick of the position.
     * @param tickUpper The upper tick of the position.
     * @return The token ID and index of the position.
     */
    function getPositionFromTicks(int24 tickLower, int24 tickUpper) internal view returns (uint256, uint256) {
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].tickLower == tickLower && positions[i].tickUpper == tickUpper) {
                return (positions[i].tokenId, i);
            }
        }
        return (0, 0);
    }

    /**
     * @dev Converts a price to the closest tick.
     * @param price The price to convert.
     * @return The closest tick.
     */
    function getTickFromPrice(uint256 price) internal pure returns (int24) {
        require(price > 0, "E10"); // E10: Price must be greater than 0

        // Convert price to sqrtPriceX96 format
        uint160 sqrtPriceX96 = uint160(sqrt(price) * (1 << 96) / 1e18);

        // Use TickMath to get the closest tick
        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        return tick;
    }

    /**
     * @dev Calculates the square root of a number.
     * @param x The number to calculate the square root of.
     * @return The square root of the number.
     */
    function sqrt(uint256 x) internal pure returns (uint256) {
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }

    /**
     * @dev Removes an active position by its index.
     * @param index The index of the position to remove.
     */
    function removeActivePosition(uint256 index) internal {
        uint256 lastIndex = activePositionIndexes.length - 1;
        if (index != lastIndex) {
            activePositionIndexes[index] = activePositionIndexes[lastIndex];
        }
        activePositionIndexes.pop();
    }

    /**
     * @dev Checks if a position is active.
     * @param index The index of the position to check.
     * @return True if the position is active, false otherwise.
     */
    function isActivePosition(uint256 index) internal view returns (bool) {
        uint256 length = activePositionIndexes.length;
        for (uint256 i = 0; i < length; i++) {
            if (activePositionIndexes[i] == index) {
                return true;
            }
        }
        return false;
    }

    /**
     * @dev Emergency withdraw function to recover all funds in the contract.
     *      Only callable by the contract owner.
     */
    function emergencyWithdraw() external onlyOwner {
        // Withdraw all token0 funds
        uint256 token0Balance = IERC20Metadata(pool.token0()).balanceOf(address(this));
        if (token0Balance > 0) {
            TransferHelper.safeTransfer(pool.token0(), msg.sender, token0Balance);
        }

        // Withdraw all token1 funds
        uint256 token1Balance = IERC20Metadata(pool.token1()).balanceOf(address(this));
        if (token1Balance > 0) {
            TransferHelper.safeTransfer(pool.token1(), msg.sender, token1Balance);
        }

        // Emit an event for transparency
        emit EmergencyWithdraw(msg.sender, token0Balance, token1Balance);
    }

    /**
     * @dev Fallback function to prevent Ether transfers to the contract.
     */
    receive() external payable {
        revert("Ether transfers not allowed");
    }

    /**
     * @dev Fallback function to handle unexpected calls and prevent Ether from being locked.
     */
    fallback() external payable {
        revert("Function not supported");
    }
}
