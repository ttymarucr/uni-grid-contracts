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
import "./IGridPositionManager.sol";
/**
 * @title GridPositionManager
 * @dev Manages grid-based liquidity positions on Uniswap V3.
 *      Allows depositing, withdrawing, compounding, and sweeping liquidity positions.
 */

contract GridPositionManager is Ownable, ReentrancyGuard, IGridPositionManager {
    using SafeMath for uint256;

    IUniswapV3Pool immutable pool; // Uniswap V3 pool
    INonfungiblePositionManager immutable positionManager; // Position manager for Uniswap V3

    Position[] positions; // Array of all positions
    uint256 gridQuantity; // Total grid quantity
    uint256 gridStep; // Step size for grid prices

    uint256[] public activePositionIndexes; // List of indexes for active positions with liquidity

    uint256 public token0MinFees; // Minimum fees for token0
    uint256 public token1MinFees; // Minimum fees for token1

    /**
     * @dev Modifier to restrict access to the contract owner or the contract itself.
     */
    modifier selfOrOwner() {
        require(msg.sender == owner() || msg.sender == address(this), "E13"); // E13: Caller must be owner or contract
        _;
    }

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
        token0MinFees = 0;
        token1MinFees = 0;

        // Approve max token amounts for token0 and token1
        TransferHelper.safeApprove(IUniswapV3Pool(_pool).token0(), _positionManager, type(uint256).max);
        TransferHelper.safeApprove(IUniswapV3Pool(_pool).token1(), _positionManager, type(uint256).max);
    }

    /**
     * @dev Deposits liquidity into grid positions.
     * @param token0Amount Amount of token0 to deposit.
     * @param token1Amount Amount of token1 to deposit.
     * @param slippage Maximum allowable slippage for adding liquidity (in basis points, e.g., 100 = 1%).
     */
    function deposit(uint256 token0Amount, uint256 token1Amount, uint256 slippage)
        public
        override
        nonReentrant
        selfOrOwner
    {
        require(token0Amount > 0 && token1Amount > 0, "E5"); // E5: Token0 and Token1 amount must be greater than 0
        require(slippage <= 10000, "E11"); // E11: Slippage must be less than or equal to 10000 (100%)

        // Fetch the current pool tick
        (, int24 currentTick,,,,,) = pool.slot0();

        // Transfer tokens to the contract using TransferHelper
        TransferHelper.safeTransferFrom(pool.token0(), msg.sender, address(this), token0Amount);
        TransferHelper.safeTransferFrom(pool.token1(), msg.sender, address(this), token1Amount);

        _deposit(currentTick, slippage);
    }

    /**
     * @dev Handles the logic for calculating desired amounts and managing positions.
     * @param tickLower The lower tick of the grid.
     * @param tickUpper The upper tick of the grid.
     * @param currentTick The current tick of the pool.
     * @param halfGridLength Half the length of the grid.
     * @param slippage Maximum allowable slippage for adding liquidity (in basis points).
     */
    function _handlePosition(
        int24 tickLower,
        int24 tickUpper,
        int24 currentTick,
        uint256 halfGridLength,
        uint256 slippage
    ) internal {
        uint256 token0Balance = IERC20Metadata(pool.token0()).balanceOf(address(this));
        uint256 token1Balance = IERC20Metadata(pool.token1()).balanceOf(address(this));
        uint256 amount0Desired;
        uint256 amount1Desired;

        if (tickUpper < currentTick) {
            amount1Desired = token1Balance.div(halfGridLength);
        } else if (tickLower > currentTick) {
            amount0Desired = token0Balance.div(halfGridLength);
        } else {
            return; // Skip middle grid
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
        while (activePositionIndexes.length > 0) {
            uint256 i = activePositionIndexes.length - 1;
            uint256 index = activePositionIndexes[i];
            uint256 tokenId = positions[index].tokenId;
            uint128 liquidity = positions[index].liquidity;
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
            _removeActivePosition(i);
            // Update the position's liquidity to 0
            positions[index].liquidity = 0;
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
     * @dev Compounds collected fees into liquidity for the closest active position.
     * @param slippage Maximum allowable slippage for adding liquidity (in basis points, e.g., 100 = 1%).
     */
    function compound(uint256 slippage) external override nonReentrant {
        require(slippage <= 10000, "E11"); // E11: Slippage must be less than or equal to 10000 (100%)

        uint256 accumulated0Fees = IERC20Metadata(pool.token0()).balanceOf(address(this));
        uint256 accumulated1Fees = IERC20Metadata(pool.token1()).balanceOf(address(this));
        uint256 activePositions = activePositionIndexes.length;

        // Fetch the current pool tick
        (, int24 currentTick,,,,,) = pool.slot0();

        for (uint256 i = 0; i < activePositions; i++) {
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

        // Check if there are any fees to compound
        if (accumulated0Fees > token0MinFees || accumulated1Fees > token1MinFees) {
            _deposit(currentTick, slippage);
            emit Compound(msg.sender, accumulated0Fees, accumulated1Fees);
        }
    }

    /**
     * @dev Sweeps positions outside the price range and redeposits the collected tokens.
     * @param slippage Maximum allowable slippage for adding liquidity (in basis points, e.g., 100 = 1%).
     */
    function sweep(uint256 slippage) external override {
        require(slippage <= 10000, "E11"); // E11: Slippage must be less than or equal to 10000 (100%)
        // Fetch the current pool tick
        (, int24 currentTick,,,,,) = pool.slot0();

        int24 tickRange = int24(gridQuantity / 2) * int24(gridStep);
        int24 lowerBound = currentTick - tickRange;
        int24 upperBound = currentTick + tickRange;
        for (uint256 i = 0; i < activePositionIndexes.length; i++) {
            uint256 index = activePositionIndexes[i];
            uint256 tokenId = positions[index].tokenId;
            int24 tickLower = positions[index].tickLower;
            int24 tickUpper = positions[index].tickUpper;
            uint128 liquidity = positions[index].liquidity;

            // Check if the position is outside the tick range
            if (tickUpper < lowerBound || tickLower > upperBound) {
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
                _removeActivePosition(i);
                i--; // Adjust index after removal

                // Update the position's liquidity to 0
                positions[index].liquidity = 0;
            }
        }

        uint256 accumulated0Fees = IERC20Metadata(pool.token0()).balanceOf(address(this));
        uint256 accumulated1Fees = IERC20Metadata(pool.token1()).balanceOf(address(this));
        if (accumulated0Fees > token0MinFees || accumulated1Fees > token1MinFees) {
            _deposit(currentTick, slippage);
        }
    }

    /**
     * @dev Emergency withdraw function to recover all funds in the contract.
     *      Only callable by the contract owner.
     */
    function emergencyWithdraw() external onlyOwner {
        // Iterate over active positions and transfer tokens to the sender
        while (activePositionIndexes.length > 0) {
            uint256 i = activePositionIndexes.length - 1;
            uint256 index = activePositionIndexes[i];
            uint256 tokenId = positions[index].tokenId;

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
            _removeActivePosition(i);

            // Update the position's liquidity to 0
            positions[index].liquidity = 0;
        }

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
     * @dev Closes all positions by burning them. Can only be called if activePositionIndexes.length is zero.
     *      Assumes all positions in the positions array have zero liquidity.
     *      Only callable by the contract owner.
     */
    function close() external override onlyOwner nonReentrant {
        require(activePositionIndexes.length == 0, "E15"); // E15: Active positions must be zero

        for (uint256 i = 0; i < positions.length; i++) {
            uint256 tokenId = positions[i].tokenId;

            // Burn the position
            positionManager.burn(tokenId);
        }

        // Clear the positions array
        delete positions;
    }

    /**
     * @dev Sets the grid step size.
     *      Only callable by the contract owner.
     * @param _newGridStep New grid step size.
     */
    function setGridStep(uint256 _newGridStep) external override onlyOwner {
        require(_newGridStep > 0 && _newGridStep < 10000, "E6"); // E6: Grid step must be greater than 0 and less than 10000
        gridStep = _newGridStep;
    }

    /**
     * @dev Sets the grid quantity.
     *      Only callable by the contract owner.
     * @param _newGridQuantity New grid quantity.
     */
    function setGridQuantity(uint256 _newGridQuantity) external override onlyOwner {
        require(
            _newGridQuantity > 0 && _newGridQuantity < 10000,
            "E7" // E7: Price range percentage must be greater than 0 and less than 10000
        );
        gridQuantity = _newGridQuantity;
    }

    /**
     * @dev Sets the minimum fees for token0 and token1.
     *      Only callable by the contract owner.
     * @param _token0MinFees New minimum fees for token0.
     * @param _token1MinFees New minimum fees for token1.
     */
    function setMinFees(uint256 _token0MinFees, uint256 _token1MinFees) external override onlyOwner {
        token0MinFees = _token0MinFees;
        token1MinFees = _token1MinFees;
    }

    /**
     * @dev Returns the total number of positions.
     * @return The length of the positions array.
     */
    function getPositionsLength() external view override returns (uint256) {
        return positions.length;
    }

    /**
     * @dev Returns the indexes of active positions.
     * @return An array of active position indexes.
     */
    function getActivePositionIndexes() external view override returns (uint256[] memory) {
        return activePositionIndexes;
    }

    
    function _deposit(int24 currentTick, uint256 slippage) internal {
        int24[] memory gridTicks = _calculateGridTicks(currentTick);
        require(gridTicks.length > 2, "Invalid grid ticks");

        uint256 gridLength = gridTicks.length - 1;
        uint256 halfGridLength = gridLength.div(2);

        for (uint256 i = 0; i < gridLength; i++) {
            // Extracted logic for calculating desired amounts and handling positions
            _handlePosition(gridTicks[i], gridTicks[i + 1], currentTick, halfGridLength - (i % halfGridLength), slippage);
        }
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
        (uint128 newLiquidity, uint256 amount0, uint256 amount1) = positionManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: block.timestamp + 1 hours
            })
        );
        positions[index].liquidity = newLiquidity;
        if (!_isActivePosition(index)) {
            activePositionIndexes.push(index);
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
        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: pool.token0(),
                token1: pool.token1(),
                fee: pool.fee(),
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
        emit Deposit(msg.sender, amount0, amount1);
    }

    /**
     * @dev Calculates grid ticks based on the target tick and pool's tick spacing.
     *      Ignores the grid that is within the range of the target tick.
     * @param targetTick The target tick for the grid.
     * @return An array of grid ticks.
     */
    function _calculateGridTicks(int24 targetTick) internal view returns (int24[] memory) {
        require(gridQuantity > 0, "E8"); // E8: Grid range percentage must be greater than 0

        // Fetch the tick spacing from the pool
        int24 tickSpacing = pool.tickSpacing() * int24(gridStep);
        require(tickSpacing > 0, "E14"); // E14: Invalid tick spacing

        int24 tickRange = int24(gridQuantity / 2) * tickSpacing;

        // Ensure the lower and upper ticks are aligned with the tick spacing
        int24 lowerTick = targetTick - tickRange;
        lowerTick = lowerTick - (lowerTick % tickSpacing);

        int24 upperTick = targetTick + tickRange;
        upperTick = upperTick - (upperTick % tickSpacing);

        uint256 gridCount = uint256((upperTick - lowerTick) / tickSpacing);
        require(gridCount > 1, "E9"); // E9: Grid count must be greater than 1 to exclude the middle grid

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
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].tickLower == tickLower && positions[i].tickUpper == tickUpper) {
                return (positions[i].tokenId, i);
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
    function _isActivePosition(uint256 index) internal view returns (bool) {
        uint256 length = activePositionIndexes.length;
        for (uint256 i = 0; i < length; i++) {
            if (activePositionIndexes[i] == index) {
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
        return address(pool);
    }

    function getPositionManager() external view override returns (address) {
        return address(positionManager);
    }

    function getGridQuantity() external view override returns (uint256) {
        return gridQuantity;
    }

    function getGridStep() external view override returns (uint256) {
        return gridStep;
    }

    function getPosition(uint256 index) external view override returns (Position memory) {
        require(index < positions.length, "E12"); // E12: Index out of bounds
        return positions[index];
    }
}
