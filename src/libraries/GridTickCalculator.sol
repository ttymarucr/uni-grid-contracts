// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;

library GridTickCalculator {
    /**
     * @dev Enum representing the type of grid.
     *      NEUTRAL: Neutral grid, centered around the target tick.
     *      BUY: Buy grid, below the target tick.
     *      SELL: Sell grid, above the target tick.
     */
    enum GridType {
        NEUTRAL,
        BUY,
        SELL
    }

    /**
     * @dev Calculates grid ticks based on the target tick and pool's tick spacing.
     *      Ignores the grid that is within the range of the target tick.
     * @param targetTick The target tick for the grid.
     * @param gridType The type of grid (NEUTRAL, BUY, SELL).
     * @param gridQuantity The total grid quantity.
     * @param gridStep The step size for grid prices.
     * @param tickSpacing The tick spacing of the pool.
     * @return An array of grid ticks.
     */
    function calculateGridTicks(
        int24 targetTick,
        GridType gridType,
        uint256 gridQuantity,
        uint256 gridStep,
        int24 tickSpacing
    ) internal pure returns (int24[] memory) {
        require(gridQuantity > 0, "E03");
        require(gridStep > 0, "E04");

        tickSpacing = tickSpacing * int24(gridStep);
        int24 tickRange = int24(gridType == GridType.NEUTRAL ? gridQuantity / 2 : gridQuantity) * tickSpacing;

        int24 lowerTick = targetTick - tickRange;
        if (gridType == GridType.SELL) {
            lowerTick = targetTick;
        }
        lowerTick = lowerTick - (lowerTick % tickSpacing);

        int24 upperTick = targetTick + tickRange;
        if (gridType == GridType.BUY) {
            upperTick = targetTick;
        }
        upperTick = upperTick - (upperTick % tickSpacing);

        uint256 gridCount = uint256((upperTick - lowerTick) / tickSpacing);
        require(gridCount > 1, "E07");

        int24[] memory gridTicks = new int24[](gridCount);
        int24 currentTick = lowerTick;
        uint256 index = 0;

        for (uint256 i = 0; i < gridCount; i++) {
            gridTicks[index] = currentTick;
            currentTick += tickSpacing;
            index++;
        }

        assembly {
            mstore(gridTicks, index)
        }

        return gridTicks;
    }
}
