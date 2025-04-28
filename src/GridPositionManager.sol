// SPDX-License-Identifier: MIT
pragma abicoder v2;
pragma solidity ^0.7.6;

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IERC20Metadata.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import { UD60x18 } from "@prb/math/src/UD60x18.sol";
import "./proxy/utils/Initializable.sol";
import "./access/OwnableUpgradeable.sol";
import "./security/ReentrancyGuardUpgradeable.sol";
import "./interfaces/IGridPositionManager.sol";

/**
 * @title GridPositionManager
 * @dev Manages grid-based liquidity positions on Uniswap V3.
 *      Allows depositing, withdrawing, compounding, and sweeping liquidity positions.
 */
contract GridPositionManager is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable, IGridPositionManager {
    using SafeMath for uint256;
    /// @custom:storage-location erc7201:tty0.unigrids.GridPositionManager

    struct GridPositionManagerStorage {
        IUniswapV3Pool pool; // Uniswap V3 pool
        INonfungiblePositionManager positionManager; // Position manager for Uniswap V3
        Position[] positions; // Array of all positions
        uint256[] activePositionIndexes; // List of indexes for active positions with liquidity
        uint256 gridQuantity; // Total grid quantity
        uint256 gridStep; // Step size for grid prices
        uint256 token0MinFees; // Minimum fees for token0
        uint256 token1MinFees; // Minimum fees for token1
    }

    // keccak256(abi.encode(uint256(keccak256("tty0.unigrids.GridPositionManager")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant GridPositionManagerStorageLocation =
        0x0bdaf5e1f6918a0fb3644e9dc0c6846de7a35515893b30847706d10786f4c100;

    function _getStorage() private pure returns (GridPositionManagerStorage storage $) {
        assembly {
            $.slot := GridPositionManagerStorageLocation
        }
    }

    /**
     * @dev Initializes the contract. Replaces the constructor for UUPS proxies.
     * @param _pool Address of the Uniswap V3 pool.
     * @param _positionManager Address of the Uniswap V3 position manager.
     * @param _gridQuantity Total grid quantity.
     * @param _gridStep Step size for grid prices.
     */
    function initialize(address _pool, address _positionManager, uint256 _gridQuantity, uint256 _gridStep)
        public
        initializer
    {
        require(_pool != address(0), "E01: Invalid pool address");
        require(_positionManager != address(0), "E02: Invalid position manager address");
        require(_gridQuantity > 0, "E03: Grid quantity must be greater than 0");
        require(_gridStep > 0, "E04: Grid step must be greater than 0");
        __Ownable_init();
        __ReentrancyGuard_init();

        GridPositionManagerStorage storage $ = _getStorage();
        $.pool = IUniswapV3Pool(_pool);
        $.positionManager = INonfungiblePositionManager(_positionManager);
        $.gridQuantity = _gridQuantity;
        $.gridStep = _gridStep;
        $.token0MinFees = 0;
        $.token1MinFees = 0;

        // Approve max token amounts for token0 and token1
        TransferHelper.safeApprove(IUniswapV3Pool(_pool).token0(), _positionManager, type(uint256).max);
        TransferHelper.safeApprove(IUniswapV3Pool(_pool).token1(), _positionManager, type(uint256).max);
    }

    /**
     * @dev Deposits liquidity into grid positions with a specified distribution type.
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
        DistributionType distributionType
    ) public override nonReentrant onlyOwner {
        require(slippage <= 500, "E06: Slippage must be less than or equal to 500 (5%)");

        if (gridType == GridType.NEUTRAL) {
            require(token0Amount > 0 && token1Amount > 0, "E05: Token amounts must be greater than 0");
        } else if (gridType == GridType.BUY) {
            require(token1Amount > 0, "E14: Token1 amount must be zero for BUY grid type");
        } else if (gridType == GridType.SELL) {
            require(token0Amount > 0, "E14: Token0 amount must be zero for SELL grid type");
        }

        GridPositionManagerStorage storage $ = _getStorage();

        // Transfer tokens to the contract using TransferHelper
        if (token0Amount > 0) {
            TransferHelper.safeTransferFrom($.pool.token0(), msg.sender, address(this), token0Amount);
        }
        if (token1Amount > 0) {
            TransferHelper.safeTransferFrom($.pool.token1(), msg.sender, address(this), token1Amount);
        }

        // Distribute liquidity based on the chosen distribution type
        _distributeLiquidity(token0Amount, token1Amount, slippage, gridType, distributionType);
    }

    /**
     * @dev Distributes liquidity across grid positions based on the chosen distribution type.
     * @param token0Amount Amount of token0 to distribute.
     * @param token1Amount Amount of token1 to distribute.
     * @param slippage Maximum allowable slippage for adding liquidity.
     * @param gridType The type of grid (NEUTRAL, BUY, SELL).
     * @param distributionType The type of liquidity distribution.
     */
    function _distributeLiquidity(
        uint256 token0Amount,
        uint256 token1Amount,
        uint256 slippage,
        GridType gridType,
        DistributionType distributionType
    ) internal {
        GridPositionManagerStorage storage $ = _getStorage();
        (, int24 currentTick,,,,,) = $.pool.slot0();
        int24[] memory gridTicks = _calculateGridTicks(currentTick, gridType);

        uint256 gridLength = gridTicks.length - 1;
        uint256[] memory distributionWeights = _getDistributionWeights(gridLength, distributionType);
        uint256 positionsLength = gridType == GridType.NEUTRAL ? gridLength.div(2) : gridLength;

        for (uint256 i = 0; i < gridLength; i++) {
            uint256 weight = distributionWeights[i];
            uint256 token0Share = token0Amount.mul(weight).div(10000);
            uint256 token1Share = token1Amount.mul(weight).div(10000);

            _handlePosition(gridTicks[i], gridTicks[i + 1], currentTick, positionsLength - (i % positionsLength), slippage, token0Share, token1Share);
        }
    }

    /**
     * @dev Returns the distribution weights for the specified distribution type.
     * @param gridLength The number of grid intervals.
     * @param distributionType The type of liquidity distribution.
     * @return An array of distribution weights.
     */
    function _getDistributionWeights(uint256 gridLength, DistributionType distributionType)
        internal
        pure
        returns (uint256[] memory)
    {
        uint256[] memory weights = new uint256[](gridLength);

        if (distributionType == DistributionType.FLAT) {
            for (uint256 i = 0; i < gridLength; i++) {
                weights[i] = 10000 / gridLength; // Equal distribution
            }
        } else if (distributionType == DistributionType.CURVED) {
            for (uint256 i = 0; i < gridLength; i++) {
                weights[i] = (i + 1) * 10000 / (gridLength * (gridLength + 1) / 2); // Triangular distribution
            }
        } else if (distributionType == DistributionType.LINEAR) {
            for (uint256 i = 0; i < gridLength; i++) {
                weights[i] = (gridLength - i) * 10000 / (gridLength * (gridLength + 1) / 2); // Linear decay
            }
        } else if (distributionType == DistributionType.SIGMOID) {
            for (uint256 i = 0; i < gridLength; i++) {
                // Use PRBMath's exp function for the sigmoid curve
                uint256 x = UD60x18.div(
                    int256(i * 2e18 - gridLength * 1e18), // Scale input to 18 decimals
                    int256(gridLength * 1e18)
                );
                weights[i] = uint256(10000 / (1 + UD60x18.exp(-x)));
            }
        } else if (distributionType == DistributionType.FIBONACCI) {
            uint256[] memory fib = new uint256[](gridLength);
            fib[0] = 1;
            fib[1] = 1;
            for (uint256 i = 2; i < gridLength; i++) {
                fib[i] = fib[i - 1] + fib[i - 2];
            }
            uint256 total = 0;
            for (uint256 i = 0; i < gridLength; i++) {
                total += fib[i];
            }
            for (uint256 i = 0; i < gridLength; i++) {
                weights[i] = fib[i] * 10000 / total;
            }
        } else if (distributionType == DistributionType.LOGARITHMIC) {
            for (uint256 i = 0; i < gridLength; i++) {
                // Use PRBMath's ln function for logarithmic decay
                weights[i] = uint256(10000 / (1 + UD60x18.ln(i + 1)));
            }
        }

        return weights;
    }

    /**
     * @dev Handles the logic for calculating desired amounts and managing positions.
     * @param tickLower The lower tick of the grid.
     * @param tickUpper The upper tick of the grid.
     * @param currentTick The current tick of the pool.
     * @param positionsLength The number of positions to be created.
     * @param slippage Maximum allowable slippage for adding liquidity (in basis points).
     * @param token0Share The share of token0 to allocate to this position.
     * @param token1Share The share of token1 to allocate to this position.
     */
    function _handlePosition(
        int24 tickLower,
        int24 tickUpper,
        int24 currentTick,
        uint256 positionsLength,
        uint256 slippage,
        uint256 token0Share,
        uint256 token1Share
    ) internal {
        GridPositionManagerStorage storage $ = _getStorage();
        require(tickLower < tickUpper, "E07: Invalid tick range");
        require(
            tickLower % $.pool.tickSpacing() == 0 && tickUpper % $.pool.tickSpacing() == 0,
            "E08: Ticks must align with spacing"
        );

        uint256 token0Balance = IERC20Metadata($.pool.token0()).balanceOf(address(this));
        uint256 token1Balance = IERC20Metadata($.pool.token1()).balanceOf(address(this));
        uint256 amount0Desired = token0Share;
        uint256 amount1Desired = token1Share;

        if (tickUpper < currentTick) {
            amount1Desired = token1Share.div(positionsLength);
            amount0Desired = 0;
        } else if (tickLower > currentTick) {
            amount0Desired = token0Share.div(positionsLength);
            amount1Desired = 0;
        }

        // Calculate slippage-adjusted amounts
        uint256 amount0Slippage = amount0Desired.mul(uint256(10000).sub(slippage)).div(10000);
        uint256 amount1Slippage = amount1Desired.mul(uint256(10000).sub(slippage)).div(10000);

        // Check if the position already exists
        (uint256 existingTokenId, uint256 index) = _getPositionFromTicks(tickLower, tickUpper);
        if (existingTokenId > 0) {
            _addLiquidityToExistingPosition(
                existingTokenId, index, amount0Desired, amount1Desired, amount0Slippage, amount1Slippage
            );
            return;
        }

        // Mint a new position
        _mintNewPosition(tickLower, tickUpper, amount0Desired, amount1Desired, amount0Slippage, amount1Slippage);
    }

    /**
     * @dev Withdraws all liquidity from active positions.
     *      Only callable by the contract owner.
     */
    function withdraw() external override onlyOwner nonReentrant {
        GridPositionManagerStorage storage $ = _getStorage();
        while ($.activePositionIndexes.length > 0) {
            uint256 i = $.activePositionIndexes.length - 1;
            uint256 index = $.activePositionIndexes[i];
            uint256 tokenId = $.positions[index].tokenId;
            uint128 liquidity = $.positions[index].liquidity;
            $.positionManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: liquidity,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp + 1 hours
                })
            );

            $.positionManager.collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: tokenId,
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );

            // Remove the position from the active positions list
            _removeActivePosition(i);
            // Update the position's liquidity to 0
            $.positions[index].liquidity = 0;
        }
        uint256 token0Balance = IERC20Metadata($.pool.token0()).balanceOf(address(this));
        uint256 token1Balance = IERC20Metadata($.pool.token1()).balanceOf(address(this));
        if (token0Balance > 0) {
            TransferHelper.safeTransfer($.pool.token0(), msg.sender, token0Balance);
        }
        if (token1Balance > 0) {
            TransferHelper.safeTransfer($.pool.token1(), msg.sender, token1Balance);
        }
        emit Withdraw(msg.sender, token0Balance, token1Balance);
    }

    /**
     * @dev Compounds collected fees into liquidity for the closest active position.
     * @param slippage Maximum allowable slippage for adding liquidity (in basis points, e.g., 100 = 1%).
     * @param gridType The type of grid (NEUTRAL, BUY, SELL).
     * @param distributionType The type of liquidity distribution (FLAT, CURVED, LINEAR, SIGMOID, FIBONACCI, LOGARITHMIC).
     */
    function compound(uint256 slippage, GridType gridType, DistributionType distributionType) external override nonReentrant {
        require(slippage <= 500, "E06: Slippage must be less than or equal to 500 (5%)");

        GridPositionManagerStorage storage $ = _getStorage();
        uint256 accumulated0Fees = IERC20Metadata($.pool.token0()).balanceOf(address(this));
        uint256 accumulated1Fees = IERC20Metadata($.pool.token1()).balanceOf(address(this));
        uint256 activePositions = $.activePositionIndexes.length;

        for (uint256 i = 0; i < activePositions; i++) {
            uint256 index = $.activePositionIndexes[i];
            uint256 tokenId = $.positions[index].tokenId;

            // Collect fees
            (uint256 amount0Collected, uint256 amount1Collected) = $.positionManager.collect(
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

        // Check if there are any fees to compound
        if (accumulated0Fees > $.token0MinFees || accumulated1Fees > $.token1MinFees) {
            _distributeLiquidity(accumulated0Fees, accumulated1Fees, slippage, gridType, distributionType);
            emit Compound(msg.sender, accumulated0Fees, accumulated1Fees);
        }
    }

    /**
     * @dev Sweeps positions outside the price range and redeposits the collected tokens.
     * @param slippage Maximum allowable slippage for adding liquidity (in basis points, e.g., 100 = 1%).
     * @param gridType The type of grid (NEUTRAL, BUY, SELL).
     * @param distributionType The type of liquidity distribution (FLAT, CURVED, LINEAR, SIGMOID, FIBONACCI, LOGARITHMIC).
     */
    function sweep(uint256 slippage, GridType gridType, DistributionType distributionType) external override {
        require(slippage <= 500, "E06: Slippage must be less than or equal to 500 (5%)");
        GridPositionManagerStorage storage $ = _getStorage();
        // Fetch the current pool tick
        (, int24 currentTick,,,,,) = $.pool.slot0();
        int24 averageTick = _getTWAP();
        _validatePrice(currentTick, averageTick, 100); // Allow max deviation of 100 ticks

        int24 tickRange = int24($.gridQuantity / 2) * int24($.gridStep);
        int24 lowerBound = currentTick - tickRange;
        int24 upperBound = currentTick + tickRange;
        for (uint256 i = 0; i < $.activePositionIndexes.length; i++) {
            uint256 index = $.activePositionIndexes[i];
            uint256 tokenId = $.positions[index].tokenId;
            int24 tickLower = $.positions[index].tickLower;
            int24 tickUpper = $.positions[index].tickUpper;
            uint128 liquidity = $.positions[index].liquidity;

            // Check if the position is outside the tick range
            if (tickUpper < lowerBound || tickLower > upperBound) {
                // Remove liquidity from the position
                $.positionManager.decreaseLiquidity(
                    INonfungiblePositionManager.DecreaseLiquidityParams({
                        tokenId: tokenId,
                        liquidity: liquidity,
                        amount0Min: 0,
                        amount1Min: 0,
                        deadline: block.timestamp + 1 hours
                    })
                );

                // Collect fees and tokens
                $.positionManager.collect(
                    INonfungiblePositionManager.CollectParams({
                        tokenId: tokenId,
                        recipient: address(this),
                        amount0Max: type(uint128).max,
                        amount1Max: type(uint128).max
                    })
                );

                // Remove the position from the active positions list
                _removeActivePosition(i);
                i--; // Adjust index after removal

                // Update the position's liquidity to 0
                $.positions[index].liquidity = 0;
            }
        }

        uint256 accumulated0Fees = IERC20Metadata($.pool.token0()).balanceOf(address(this));
        uint256 accumulated1Fees = IERC20Metadata($.pool.token1()).balanceOf(address(this));
        if (accumulated0Fees > $.token0MinFees || accumulated1Fees > $.token1MinFees) {
            _distributeLiquidity(accumulated0Fees, accumulated1Fees, slippage, gridType, distributionType);
        }
    }

    /**
     * @dev Closes all positions by burning them. Can only be called if activePositionIndexes.length is zero.
     *      Assumes all positions in the positions array have zero liquidity.
     *      Only callable by the contract owner.
     */
    function close() external override onlyOwner nonReentrant {
        GridPositionManagerStorage storage $ = _getStorage();
        require($.activePositionIndexes.length == 0, "E12: Active positions must be zero");

        for (uint256 i = 0; i < $.positions.length; i++) {
            uint256 tokenId = $.positions[i].tokenId;

            // Burn the position
            $.positionManager.burn(tokenId);
        }

        // Clear the positions array
        delete $.positions;
    }

    /**
     * @dev Sets the grid step size.
     *      Only callable by the contract owner.
     * @param _newGridStep New grid step size.
     */
    function setGridStep(uint256 _newGridStep) external override onlyOwner {
        GridPositionManagerStorage storage $ = _getStorage();
        require(_newGridStep > 0 && _newGridStep < 10000, "E09: Grid step must be between 1 and 9999");
        $.gridStep = _newGridStep;
        emit GridStepUpdated(_newGridStep);
    }

    /**
     * @dev Sets the grid quantity.
     *      Only callable by the contract owner.
     * @param _newGridQuantity New grid quantity.
     */
    function setGridQuantity(uint256 _newGridQuantity) external override onlyOwner {
        GridPositionManagerStorage storage $ = _getStorage();
        require(_newGridQuantity > 0 && _newGridQuantity < 10000, "E10: Grid quantity must be between 1 and 9999");
        $.gridQuantity = _newGridQuantity;
        emit GridQuantityUpdated(_newGridQuantity);
    }

    /**
     * @dev Sets the minimum fees for token0 and token1.
     *      Only callable by the contract owner.
     * @param _token0MinFees New minimum fees for token0.
     * @param _token1MinFees New minimum fees for token1.
     */
    function setMinFees(uint256 _token0MinFees, uint256 _token1MinFees) external override onlyOwner {
        GridPositionManagerStorage storage $ = _getStorage();
        $.token0MinFees = _token0MinFees;
        $.token1MinFees = _token1MinFees;
        emit MinFeesUpdated(_token0MinFees, _token1MinFees);
    }

    /**
     * @dev Returns the total number of positions.
     * @return The length of the positions array.
     */
    function getPositionsLength() external view override returns (uint256) {
        GridPositionManagerStorage storage $ = _getStorage();
        return $.positions.length;
    }

    /**
     * @dev Returns the indexes of active positions.
     * @return An array of active position indexes.
     */
    function getActivePositionIndexes() external view override returns (uint256[] memory) {
        GridPositionManagerStorage storage $ = _getStorage();
        return $.activePositionIndexes;
    }

    /**
     * @dev Adds liquidity to an existing position.
     * @param tokenId The token ID of the existing position.
     * @param index The index of the position in the positions array.
     * @param amount0Desired Desired amount of token0.
     * @param amount1Desired Desired amount of token1.
     * @param amount0Min Minimum amount of token0 (after slippage).
     * @param amount1Min Minimum amount of token1 (after slippage).
     */
    function _addLiquidityToExistingPosition(
        uint256 tokenId,
        uint256 index,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) internal {
        GridPositionManagerStorage storage $ = _getStorage();
        (uint128 newLiquidity, uint256 amount0, uint256 amount1) = $.positionManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: block.timestamp + 1 hours
            })
        );
        $.positions[index].liquidity += newLiquidity;
        if (!_isActivePosition(index)) {
            $.activePositionIndexes.push(index);
        }
        emit Deposit(msg.sender, amount0, amount1);
    }

    /**
     * @dev Mints a new position.
     * @param tickLower The lower tick of the grid.
     * @param tickUpper The upper tick of the grid.
     * @param amount0Desired Desired amount of token0.
     * @param amount1Desired Desired amount of token1.
     * @param amount0Min Minimum amount of token0 (after slippage).
     * @param amount1Min Minimum amount of token1 (after slippage).
     */
    function _mintNewPosition(
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) internal {
        GridPositionManagerStorage storage $ = _getStorage();
        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = $.positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: $.pool.token0(),
                token1: $.pool.token1(),
                fee: $.pool.fee(),
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                recipient: address(this),
                deadline: block.timestamp + 1 hours
            })
        );

        // Store the position in the array
        $.positions.push(
            Position({
                tokenId: tokenId,
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidity: liquidity,
                index: $.positions.length
            })
        );

        // Add the new position to the active positions list
        $.activePositionIndexes.push($.positions.length - 1); // Use positions.length - 1 directly
        emit Deposit(msg.sender, amount0, amount1);
    }

    /**
     * @dev Calculates grid ticks based on the target tick and pool's tick spacing.
     *      Ignores the grid that is within the range of the target tick.
     * @param targetTick The target tick for the grid.
     * @param gridType The type of grid (NEUTRAL, BUY, SELL).
     * @return An array of grid ticks.
     */
    function _calculateGridTicks(int24 targetTick, GridType gridType) internal view returns (int24[] memory) {
        GridPositionManagerStorage storage $ = _getStorage();
        require($.gridQuantity > 0, "E03: Grid quantity must be greater than 0");

        // Fetch the tick spacing from the pool
        int24 tickSpacing = $.pool.tickSpacing() * int24($.gridStep);
        require(tickSpacing > 0, "E04: Grid step must be greater than 0");

        int24 tickRange = int24(gridType == GridType.NEUTRAL ? $.gridQuantity / 2 : $.gridQuantity) * tickSpacing;

        // Ensure the lower and upper ticks are aligned with the tick spacing
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
        require(gridCount > 1, "E07: Invalid tick range");

        int24[] memory gridTicks = new int24[](gridCount);
        int24 currentTick = lowerTick;
        uint256 index = 0;

        for (uint256 i = 0; i < gridCount; i++) {
            if (currentTick < targetTick && currentTick + tickSpacing > targetTick) {
                // Skip the grid that overlaps with the target tick
                currentTick += tickSpacing;
                continue;
            }
            gridTicks[index] = currentTick;
            currentTick += tickSpacing;
            index++;
        }

        // Resize the array to exclude unused slots
        assembly {
            mstore(gridTicks, index)
        }

        return gridTicks;
    }

    /**
     * @dev Finds a position by its lower and upper ticks.
     * @param tickLower The lower tick of the position.
     * @param tickUpper The upper tick of the position.
     * @return The token ID and index of the position.
     */
    function _getPositionFromTicks(int24 tickLower, int24 tickUpper) internal view returns (uint256, uint256) {
        GridPositionManagerStorage storage $ = _getStorage();
        for (uint256 i = 0; i < $.positions.length; i++) {
            if ($.positions[i].tickLower == tickLower && $.positions[i].tickUpper == tickUpper) {
                return ($.positions[i].tokenId, i);
            }
        }
        return (0, 0);
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
    function _removeActivePosition(uint256 index) internal {
        GridPositionManagerStorage storage $ = _getStorage();
        if (index < $.activePositionIndexes.length - 1) {
            $.activePositionIndexes[index] = $.activePositionIndexes[$.activePositionIndexes.length - 1];
        }
        $.activePositionIndexes.pop();
    }

    /**
     * @dev Checks if a position is active.
     * @param index The index of the position to check.
     * @return True if the position is active, false otherwise.
     */
    function _isActivePosition(uint256 index) internal view returns (bool) {
        GridPositionManagerStorage storage $ = _getStorage();
        uint256 length = $.activePositionIndexes.length;
        for (uint256 i = 0; i < length; i++) {
            if ($.activePositionIndexes[i] == index) {
                return true;
            }
        }
        return false;
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

    function getPool() external view override returns (address) {
        GridPositionManagerStorage storage $ = _getStorage();
        return address($.pool);
    }

    function getPositionManager() external view override returns (address) {
        GridPositionManagerStorage storage $ = _getStorage();
        return address($.positionManager);
    }

    function getGridQuantity() external view override returns (uint256) {
        GridPositionManagerStorage storage $ = _getStorage();
        return $.gridQuantity;
    }

    function getGridStep() external view override returns (uint256) {
        GridPositionManagerStorage storage $ = _getStorage();
        return $.gridStep;
    }

    function getPosition(uint256 index) external view override returns (Position memory) {
        GridPositionManagerStorage storage $ = _getStorage();
        require(index < $.positions.length, "E15: Index out of bounds");
        return $.positions[index];
    }

    function getActivePositions() external view override returns (Position[] memory) {
        GridPositionManagerStorage storage $ = _getStorage();
        Position[] memory activePositions = new Position[]($.activePositionIndexes.length);
        for (uint256 i = 0; i < $.activePositionIndexes.length; i++) {
            activePositions[i] = $.positions[$.activePositionIndexes[i]];
        }
        return activePositions;
    }

    function getPoolInfo() external view override returns (GridInfo memory) {
        GridPositionManagerStorage storage $ = _getStorage();
        return (
            GridInfo({
                pool: address($.pool),
                positionManager: address($.positionManager),
                gridStep: $.gridStep,
                gridQuantity: $.gridQuantity,
                fee: $.pool.fee(),
                token0MinFees: $.token0MinFees,
                token1MinFees: $.token1MinFees,
                token0Decimals: IERC20Metadata($.pool.token0()).decimals(),
                token1Decimals: IERC20Metadata($.pool.token1()).decimals(),
                token0Symbol: IERC20Metadata($.pool.token0()).symbol(),
                token1Symbol: IERC20Metadata($.pool.token1()).symbol(),
                token0: $.pool.token0(),
                token1: $.pool.token1()
            })
        );
    }

    /**
     * @dev Returns the sum of all active positions' liquidity.
     * @return token0Liquidity The total liquidity in token0.
     * @return token1Liquidity The total liquidity in token1.
     */
    function getLiquidity() external view override returns (uint256 token0Liquidity, uint256 token1Liquidity) {
        GridPositionManagerStorage storage $ = _getStorage();
        (uint160 sqrtPriceX96,,,,,,) = $.pool.slot0();
        for (uint256 i = 0; i < $.activePositionIndexes.length; i++) {
            uint256 index = $.activePositionIndexes[i];
            Position memory position = $.positions[index];
            uint160 sqrtPriceLowerX96 = TickMath.getSqrtRatioAtTick(position.tickLower);
            uint160 sqrtPriceUpperX96 = TickMath.getSqrtRatioAtTick(position.tickUpper);

            (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, position.liquidity
            );
            token0Liquidity = token0Liquidity.add(amount0);
            token1Liquidity = token1Liquidity.add(amount1);
        }
    }

    /**
     * @dev Checks if the current pool tick is inside any of the active positions.
     * @return True if the current tick is inside an active position, false otherwise.
     */
    function isInRange() external view override returns (bool) {
        GridPositionManagerStorage storage $ = _getStorage();
        (, int24 currentTick,,,,,) = $.pool.slot0();

        for (uint256 i = 0; i < $.activePositionIndexes.length; i++) {
            uint256 index = $.activePositionIndexes[i];
            Position memory position = $.positions[index];
            if (currentTick >= position.tickLower && currentTick <= position.tickUpper) {
                return true;
            }
        }
        return false;
    }

    /**
     * @dev Recovers Ether stored in the contract.
     *      Only callable by the contract owner.
     */
    function recoverEther() external onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        require(balance > 0, "E13: No Ether to recover");
        (bool success,) = msg.sender.call{value: balance}("");
        require(success, "Ether transfer failed");
    }

    /**
     * @dev Fetches the Time Weighted Average Price (TWAP) tick over a given time window.
     * @param secondsAgo The time window in seconds for calculating the TWAP.
     * @return averageTick The average tick over the specified time window.
     */
    function _getTWAP(int24 secondsAgo) internal view returns (int24 averageTick) {
        require(secondsAgo > 0, "E11: Invalid time window");

        GridPositionManagerStorage storage $ = _getStorage();
        // Fetch the current and historical tick data
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = uint32(secondsAgo); // Start of the time window
        secondsAgos[1] = 0; // Current time

        (int56[] memory tickCumulatives,) = $.pool.observe(secondsAgos);

        // Calculate the average tick over the time window
        int56 tickDifference = tickCumulatives[1] - tickCumulatives[0];
        averageTick = int24(tickDifference / secondsAgo);

        // Ensure the result fits within the tick range
        if (tickDifference < 0 && (tickDifference % secondsAgo != 0)) {
            averageTick--;
        }
    }

    /**
     * @dev Fetches the Time Weighted Average Price (TWAP) tick over the default time window.
     * @return The average tick over the default time window.
     */
    function _getTWAP() internal view returns (int24) {
        return _getTWAP(int24(300)); // Default time window of 5 minutes
    }

    /**
     * @dev Validates the price deviation between the current tick and TWAP tick.
     * @param currentTick The current tick of the pool.
     * @param twapTick The TWAP tick of the pool.
     * @param maxDeviation The maximum allowable deviation.
     */
    function _validatePrice(int24 currentTick, int24 twapTick, uint256 maxDeviation) internal pure {
        int24 deviation = currentTick > twapTick ? currentTick - twapTick : twapTick - currentTick;
        require(deviation <= int24(maxDeviation), "E14: Price deviation too high");
    }

    /**
     * @dev Collects all fees from active positions and sends them to the owner.
     *      Only callable by the contract owner.
     */
    function collectFees() external onlyOwner nonReentrant {
        GridPositionManagerStorage storage $ = _getStorage();
        uint256 totalCollectedToken0 = 0;
        uint256 totalCollectedToken1 = 0;

        for (uint256 i = 0; i < $.activePositionIndexes.length; i++) {
            uint256 index = $.activePositionIndexes[i];
            uint256 tokenId = $.positions[index].tokenId;

            // Collect fees from the position
            (uint256 amount0Collected, uint256 amount1Collected) = $.positionManager.collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: tokenId,
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );

            totalCollectedToken0 = totalCollectedToken0.add(amount0Collected);
            totalCollectedToken1 = totalCollectedToken1.add(amount1Collected);
        }

        // Transfer collected fees to the owner
        if (totalCollectedToken0 > 0) {
            TransferHelper.safeTransfer($.pool.token0(), msg.sender, totalCollectedToken0);
        }
        if (totalCollectedToken1 > 0) {
            TransferHelper.safeTransfer($.pool.token1(), msg.sender, totalCollectedToken1);
        }

        emit FeesCollected(msg.sender, totalCollectedToken0, totalCollectedToken1);
    }
}
