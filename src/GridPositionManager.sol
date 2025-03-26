// SPDX-License-Identifier: MIT
pragma abicoder v2;
pragma solidity ^0.7.0;

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";

contract GridPositionManager is Ownable {
    struct Position {
        uint256 tokenId;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    Position[] public positions;

    IUniswapV3Pool public immutable pool;
    INonfungiblePositionManager public immutable positionManager;

    uint256 public priceRangePercentage;
    uint256 public gridStep;

    constructor(address _pool, address _positionManager, uint256 _priceRangePercentage, uint256 _gridStep) {
        require(_pool != address(0), "Invalid pool address");
        require(_positionManager != address(0), "Invalid position manager address");
        require(_priceRangePercentage > 0, "Grid range percentage must be greater than 0");
        require(_gridStep > 0, "Grid step must be greater than 0");

        pool = IUniswapV3Pool(_pool);
        positionManager = INonfungiblePositionManager(_positionManager);
        priceRangePercentage = _priceRangePercentage;
        gridStep = _gridStep;
    }

    function calculateGridPrices(uint256 targetPrice) public view returns (uint256[] memory) {
        require(priceRangePercentage > 0, "Price range percentage must be greater than 0");

        uint256 lowerPrice = targetPrice - (targetPrice * priceRangePercentage) / 100;
        uint256 upperPrice = targetPrice + (targetPrice * priceRangePercentage) / 100;

        uint256 gridCount = (upperPrice - lowerPrice) / gridStep;
        require(gridCount > 0, "Grid count must be greater than 0");

        uint256[] memory gridPrices = new uint256[](gridCount + 1);
        for (uint256 i = 0; i <= gridCount; i++) {
            gridPrices[i] = lowerPrice + (i * gridStep);
        }

        return gridPrices;
    }

    function deposit(uint256 token0Amount, uint256 token1Amount) external onlyOwner {
        require(token0Amount > 0 || token1Amount > 0, "Token0 and Token1 amount must be greater than 0");
        // Fetch the current pool price
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        uint256 targetPrice = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) / (1 << 192);
        // Transfer token0 and token1 to the contract
        if (token0Amount == 0) {
            (token1Amount, token0Amount) = swapTokens(pool.token1(), pool.token0(), token1Amount);
        } else {
            IERC20(pool.token0()).transferFrom(msg.sender, address(this), token0Amount);
        }
        if (token1Amount == 0) {
            (token0Amount, token1Amount) = swapTokens(pool.token0(), pool.token1(), token0Amount);
        } else {
            IERC20(pool.token1()).transferFrom(msg.sender, address(this), token1Amount);
        }
        sweep();
        uint256[] memory gridPrices = calculateGridPrices(targetPrice);
        require(gridPrices.length > 2, "Invalid grid prices");

        for (uint256 i = 0; i < gridPrices.length - 1; i++) {
            uint256 lowerPrice = gridPrices[i];
            uint256 upperPrice = gridPrices[i + 1];
            uint256 amount0Desired = 0;
            uint256 amount1Desired = 0;
            if (upperPrice < targetPrice) {
                // lower grids
                amount0Desired = token0Amount / ((gridPrices.length - 1) / 2);
            } else if (lowerPrice > targetPrice) {
                // upper grids
                amount1Desired = token1Amount / ((gridPrices.length - 1) / 2);
            } else if (lowerPrice < targetPrice && upperPrice > targetPrice) {
                // middle grid
                continue;
            }

            int24 tickLower = getTickFromPrice(lowerPrice, 18);
            int24 tickUpper = getTickFromPrice(upperPrice, 18);

            // Check if the position already exists
            (uint256 existingTokenId, uint256 index) = getPositionFromTicks(tickLower, tickUpper);
            if (existingTokenId > 0) {
                // Add liquidity to the existing position
                (uint128 newLiquidity,,) = positionManager.increaseLiquidity(
                    INonfungiblePositionManager.IncreaseLiquidityParams({
                        tokenId: existingTokenId,
                        amount0Desired: amount0Desired,
                        amount1Desired: amount1Desired,
                        amount0Min: 0,
                        amount1Min: 0,
                        deadline: block.timestamp + 1 hours
                    })
                );
                positions[index].liquidity = newLiquidity;
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
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: address(this),
                    deadline: block.timestamp + 1 hours
                })
            );

            // Store the position in the array
            positions.push(
                Position({tokenId: tokenId, tickLower: tickLower, tickUpper: tickUpper, liquidity: liquidity})
            );
        }
    }

    function updateGridStep(uint256 _newGridStep) external onlyOwner {
        require(_newGridStep > 0, "Grid step must be greater than 0");
        gridStep = _newGridStep;
    }

    function updatePriceRangePercentage(uint256 _newPriceRangePercentage) external onlyOwner {
        require(_newPriceRangePercentage > 0, "Price range percentage must be greater than 0");
        priceRangePercentage = _newPriceRangePercentage;
    }

    function swapTokens(address token0, address token1, uint256 amount)
        internal
        returns (uint256 token0Amount, uint256 token1Amount)
    {
        uint256 halfToken0Amount = amount / 2;
        IERC20(token0).approve(address(positionManager), halfToken0Amount);

        // Swap half of token0Amount to token1 using Uniswap V3
        ISwapRouter swapRouter = ISwapRouter(address(positionManager));
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: token0,
            tokenOut: token1,
            fee: pool.fee(),
            recipient: address(this),
            deadline: block.timestamp + 1 hours,
            amountIn: halfToken0Amount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        token0Amount = amount - halfToken0Amount;
        token1Amount = swapRouter.exactInputSingle(params);
    }

    function getPositionFromTicks(int24 tickLower, int24 tickUpper) internal view returns (uint256, uint256) {
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].tickLower == tickLower && positions[i].tickUpper == tickUpper) {
                return (positions[i].tokenId, i);
            }
        }
        return (0, 0);
    }

    function getPositionsLength() external view returns (uint256) {
        return positions.length;
    }

    function getTickFromPrice(uint256 price, uint8) internal pure returns (int24) {
        require(price > 0, "Price must be greater than 0");

        // Convert price to sqrtPriceX96 format
        uint160 sqrtPriceX96 = uint160(sqrt(price) * (1 << 96) / 1e18);

        // Use TickMath to get the closest tick
        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        return tick;
    }

    function sqrt(uint256 x) internal pure returns (uint256) {
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }

    function withdraw() external onlyOwner {
        for (uint256 i = 0; i < positions.length; i++) {
            uint256 tokenId = positions[i].tokenId;
            uint128 liquidity = positions[i].liquidity;

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
                        recipient: msg.sender,
                        amount0Max: type(uint128).max,
                        amount1Max: type(uint128).max
                    })
                );
            }
        }
    }

    function compound() external onlyOwner {
        uint256 accumulated0Fees = IERC20(pool.token0()).balanceOf(address(this));
        uint256 accumulated1Fees = IERC20(pool.token1()).balanceOf(address(this));
        for (uint256 i = 0; i < positions.length; i++) {
            uint256 tokenId = positions[i].tokenId;
            uint128 liquidity = positions[i].liquidity;
            if (liquidity == 0) {
                continue;
            }
            // Collect fees
            (uint256 amount0Collected, uint256 amount1Collected) = positionManager.collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: tokenId,
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );
            accumulated0Fees += amount0Collected;
            accumulated1Fees += amount1Collected;
        }
        // Fetch the current pool price
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        uint256 currentPrice = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) / (1 << 192);

        if (accumulated0Fees > 0 || accumulated1Fees > 0) {
            // Determine the current pool position based on the price
            for (uint256 i = 0; i < positions.length; i++) {
                if (
                    currentPrice >= uint256(TickMath.getSqrtRatioAtTick(positions[i].tickLower))
                        && currentPrice <= uint256(TickMath.getSqrtRatioAtTick(positions[i].tickUpper))
                ) {
                    uint256 tokenId = positions[i].tokenId;

                    // Add collected fees back into this position as liquidity
                    positionManager.increaseLiquidity(
                        INonfungiblePositionManager.IncreaseLiquidityParams({
                            tokenId: tokenId,
                            amount0Desired: accumulated0Fees,
                            amount1Desired: accumulated1Fees,
                            amount0Min: 0,
                            amount1Min: 0,
                            deadline: block.timestamp + 1 hours
                        })
                    );
                    break;
                }
            }
        }
    }

    function sweep() public onlyOwner {
        // Fetch the current pool price
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        uint256 currentPrice = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) / (1 << 192);

        uint256 lowerBound = currentPrice - (currentPrice * priceRangePercentage) / 100;
        uint256 upperBound = currentPrice + (currentPrice * priceRangePercentage) / 100;

        for (uint256 i = 0; i < positions.length; i++) {
            uint256 tokenId = positions[i].tokenId;
            uint128 liquidity = positions[i].liquidity;

            // Skip positions with no liquidity
            if (liquidity == 0) {
                continue;
            }

            // Check if the position is outside the price range
            uint256 positionLowerPrice = uint256(TickMath.getSqrtRatioAtTick(positions[i].tickLower)) ** 2 / (1 << 192);
            uint256 positionUpperPrice = uint256(TickMath.getSqrtRatioAtTick(positions[i].tickUpper)) ** 2 / (1 << 192);

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

                // Update the position's liquidity to 0
                positions[i].liquidity = 0;
            }
        }
    }
}
