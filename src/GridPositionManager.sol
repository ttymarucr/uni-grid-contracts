// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";

contract GridPositionManager is Ownable {
    IUniswapV3Pool public immutable pool;
    INonfungiblePositionManager public immutable positionManager;

    uint256 public gridPercentage;
    uint256 public priceRangePercentage;

    constructor(address _pool, address _positionManager, uint256 _gridPercentage, uint256 _priceRangePercentage) {
        require(_pool != address(0), "Invalid pool address");
        require(_positionManager != address(0), "Invalid position manager address");
        require(_gridPercentage > 0, "Grid percentage must be greater than 0");

        pool = IUniswapV3Pool(_pool);
        positionManager = INonfungiblePositionManager(_positionManager);
        gridPercentage = _gridPercentage;
        priceRangePercentage = _priceRangePercentage;
    }

    function calculateGridPrices(uint256 targetPrice) public view returns (uint256[] memory) {
        require(priceRangePercentage > 0, "Price range percentage must be greater than 0");

        uint256 lowerPrice = targetPrice - (targetPrice * priceRangePercentage) / 100;
        uint256 upperPrice = targetPrice + (targetPrice * priceRangePercentage) / 100;

        uint256 gridCount = (upperPrice - lowerPrice) / ((targetPrice * gridPercentage) / 100);
        require(gridCount > 0, "Grid count must be greater than 0");

        uint256[] memory gridPrices = new uint256[](gridCount + 1);
        for (uint256 i = 0; i <= gridCount; i++) {
            gridPrices[i] = lowerPrice + (i * ((targetPrice * gridPercentage) / 100));
        }

        return gridPrices;
    }

    function createGridPositions(uint256 token0Amount, uint256 token1Amount) external onlyOwner {
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
            // Logic to create positions on Uniswap V3 using positionManager
            positionManager.mint(
                INonfungiblePositionManager.MintParams({
                    token0: pool.token0(),
                    token1: pool.token1(),
                    fee: pool.fee(),
                    tickLower: getTickFromPrice(lowerPrice, IERC20(pool.token0()).decimals()),
                    tickUpper: getTickFromPrice(upperPrice, IERC20(pool.token0()).decimals()),
                    amount0Desired: amount0Desired,
                    amount1Desired: amount1Desired,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: address(this),
                    deadline: block.timestamp + 1 hours
                })
            );
        }
    }

    function swapTokens(address token0, address token1, uint256 amount)
        internal
        returns (uint256 token0Amount, uint256 token1Amount)
    {
        uint256 halfToken0Amount = amount / 2;
        IERC20(token0).approve(address(positionManager), halfToken0Amount);

        // Swap half of token0Amount to token1 using Uniswap V3
        INonfungiblePositionManager.SwapParams memory params = INonfungiblePositionManager.SwapParams({
            tokenIn: token0,
            tokenOut: token1,
            fee: pool.fee(),
            recipient: address(this),
            deadline: block.timestamp + 1 hours,
            amountIn: halfToken0Amount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        (uint256 amountOut,) = positionManager.swap(params);
        token1Amount = amountOut;
        token0Amount -= halfToken0Amount;
    }

    function getTickFromPrice(uint256 price, uint8 decimals) internal pure returns (int24) {
        require(price > 0, "Price must be greater than 0");

        // Convert price to sqrtPriceX96 format
        uint160 sqrtPriceX96 = uint160(sqrt(price) * (1 << 96) / decimals);

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

    function updateTargetPrice(uint256 _newTargetPrice) external onlyOwner {
        targetPrice = _newTargetPrice;
    }

    function updateGridPercentage(uint256 _newGridPercentage) external onlyOwner {
        require(_newGridPercentage > 0, "Grid percentage must be greater than 0");
        gridPercentage = _newGridPercentage;
    }
}
