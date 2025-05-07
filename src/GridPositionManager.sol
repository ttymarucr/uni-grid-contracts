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
import "./proxy/utils/Initializable.sol";
import "./access/OwnableUpgradeable.sol";
import "./security/ReentrancyGuardUpgradeable.sol";
import "./interfaces/IGridPositionManager.sol";
import "./libraries/GridTickCalculator.sol";

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
        // TokenId => Position
        mapping(uint256 => Position) positions;
        uint256[] activePositionTokens; // List of indexes for active positions with liquidity
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
        require(_pool != address(0), "E01");
        require(_positionManager != address(0), "E02");
        require(_gridQuantity > 0 && _gridQuantity <= 1_000, "E03");
        require(_gridStep > 0 && _gridStep <= 10_000, "E04");
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
        GridTickCalculator.GridType gridType,
        DistributionWeights.DistributionType distributionType
    ) public override nonReentrant onlyOwner {
        if (gridType == GridTickCalculator.GridType.NEUTRAL) {
            require(token0Amount > 0 && token1Amount > 0, "E05");
        } else if (gridType == GridTickCalculator.GridType.BUY) {
            require(token1Amount > 0, "E12");
        } else if (gridType == GridTickCalculator.GridType.SELL) {
            require(token0Amount > 0, "E13");
        }
        require(slippage <= 500, "E06");

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

    function withdraw() external override onlyOwner nonReentrant {
        _removeActiveLiquidity();
        GridPositionManagerStorage storage $ = _getStorage();
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
    function compound(
        uint256 slippage,
        GridTickCalculator.GridType gridType,
        DistributionWeights.DistributionType distributionType
    ) external override onlyOwner nonReentrant {
        require(slippage <= 500, "E06");

        GridPositionManagerStorage storage $ = _getStorage();
        uint256 accumulated0Fees = 0;
        uint256 accumulated1Fees = 0;
        uint256 length = $.activePositionTokens.length;

        for (uint256 i = 0; i < length; i++) {
            uint256 tokenId = $.activePositionTokens[i];

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
        } else {
            // If no fees are available, revert the transaction
            revert("E09");
        }
    }

    /**
     * @dev Sweeps positions outside the price range and redeposits the collected tokens.
     * @param slippage Maximum allowable slippage for adding liquidity (in basis points, e.g., 100 = 1%).
     * @param gridType The type of grid (NEUTRAL, BUY, SELL).
     * @param distributionType The type of liquidity distribution (FLAT, CURVED, LINEAR, SIGMOID, FIBONACCI, LOGARITHMIC).
     */
    function sweep(
        uint256 slippage,
        GridTickCalculator.GridType gridType,
        DistributionWeights.DistributionType distributionType
    ) external override onlyOwner nonReentrant {
        require(slippage <= 500, "E06");
        GridPositionManagerStorage storage $ = _getStorage();
        // Fetch the current pool tick
        int24 currentTick = _getCurrentTick();
        int24 averageTick = _getTWAP();
        _validatePrice(currentTick, averageTick, 100); // Allow max deviation of 100 ticks
        _removeActiveLiquidity();
        uint256 token0Balance = IERC20Metadata($.pool.token0()).balanceOf(address(this));
        uint256 token1Balance = IERC20Metadata($.pool.token1()).balanceOf(address(this));
        if (token0Balance > $.token0MinFees || token1Balance > $.token1MinFees) {
            _distributeLiquidity(token0Balance, token1Balance, slippage, gridType, distributionType);
        } else {
            // If no tokens are available, revert the transaction
            revert("E09");
        }
    }

    /**
     * @dev Collects all fees from active positions and the contract available balance and sends them to the owner.
     *      Only callable by the contract owner.
     */
    function withdrawAvailable() external override onlyOwner nonReentrant {
        GridPositionManagerStorage storage $ = _getStorage();
        uint256 length = $.activePositionTokens.length;
        for (uint256 i = 0; i < length; i++) {
            uint256 tokenId = $.activePositionTokens[i];

            // Collect fees from the position
            $.positionManager.collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: tokenId,
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );
        }

        uint256 token0Available = IERC20Metadata($.pool.token0()).balanceOf(address(this));
        uint256 token1Available = IERC20Metadata($.pool.token1()).balanceOf(address(this));
        if (token0Available > 0) {
            TransferHelper.safeTransfer($.pool.token0(), msg.sender, token0Available);
        }
        if (token1Available > 0) {
            TransferHelper.safeTransfer($.pool.token1(), msg.sender, token1Available);
        }

        emit Withdraw(msg.sender, token0Available, token1Available);
    }

    /**
     * @dev Adds liquidity to an existing position using specified token amounts.
     * @param tokenId The token ID of the existing position.
     * @param slippage Maximum allowable slippage for adding liquidity (in basis points, e.g., 100 = 1%).
     * @param token0Amount Amount of token0 to add.
     * @param token1Amount Amount of token1 to add.
     */
    function addLiquidityToPosition(uint256 tokenId, uint256 slippage, uint256 token0Amount, uint256 token1Amount)
        external
        override
        onlyOwner
        nonReentrant
    {
        require(slippage <= 500, "E06");
        require(token0Amount > 0 || token1Amount > 0, "E14");
        GridPositionManagerStorage storage $ = _getStorage();
        require($.positions[tokenId].tokenId > 0, "E11");

        // Transfer tokens to the contract using TransferHelper
        if (token0Amount > 0) {
            TransferHelper.safeTransferFrom($.pool.token0(), msg.sender, address(this), token0Amount);
        }
        if (token1Amount > 0) {
            TransferHelper.safeTransferFrom($.pool.token1(), msg.sender, address(this), token1Amount);
        }

        // Calculate slippage
        uint256 amount0Min = token0Amount.mul(uint256(10_000).sub(slippage)).div(10_000);
        uint256 amount1Min = token1Amount.mul(uint256(10_000).sub(slippage)).div(10_000);

        // Add liquidity to the existing position
        _addLiquidityToExistingPosition(tokenId, token0Amount, token1Amount, amount0Min, amount1Min);
    }

    /**
     * @dev Sets the grid step size.
     *      Only callable by the contract owner.
     * @param _newGridStep New grid step size.
     */
    function setGridStep(uint256 _newGridStep) external override onlyOwner {
        GridPositionManagerStorage storage $ = _getStorage();
        require(_newGridStep > 0 && _newGridStep < 10_000, "E04");
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
        require(_newGridQuantity > 0 && _newGridQuantity <= 1_000, "E03");
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
        return $.activePositionTokens.length;
    }

    /**
     * @dev Returns the indexes of active positions.
     * @return An array of active position indexes.
     */
    function getActivePositionIndexes() external view override returns (uint256[] memory) {
        GridPositionManagerStorage storage $ = _getStorage();
        return $.activePositionTokens;
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
        GridTickCalculator.GridType gridType,
        DistributionWeights.DistributionType distributionType
    ) internal {
        int24 currentTick = _getCurrentTick();
        int24[] memory gridTicks = _calculateGridTicks(currentTick, gridType);
        uint256 gridLength = gridTicks.length;
        uint256 positionsLength = gridType == GridTickCalculator.GridType.NEUTRAL ? gridLength.div(2) : gridLength;
        uint256[] memory distributionWeights = DistributionWeights.getWeights(positionsLength, distributionType);
        for (uint256 i = 0; i < gridLength - 1; i++) {
            uint256 weightIndex = (i >= positionsLength) ? gridLength - 2 - i : i;
            PositionParams memory params = PositionParams({
                tickLower: gridTicks[i],
                tickUpper: gridTicks[i + 1],
                currentTick: currentTick,
                slippage: slippage,
                token0Amount: token0Amount,
                token1Amount: token1Amount,
                weight: distributionWeights[weightIndex]
            });
            _handlePosition(params);
        }
    }

    /**
     * @dev Handles the position creation and liquidity addition.
     * @param params The parameters for the position.
     */
    function _handlePosition(PositionParams memory params) internal {
        GridPositionManagerStorage storage $ = _getStorage();
        require(params.tickLower % $.pool.tickSpacing() == 0 && params.tickUpper % $.pool.tickSpacing() == 0, "E08");

        uint256 amount0Desired = params.token0Amount.mul(params.weight).div(10_000);
        uint256 amount1Desired = params.token1Amount.mul(params.weight).div(10_000);
        uint256 token0Available = IERC20Metadata($.pool.token0()).balanceOf(address(this));
        uint256 token1Available = IERC20Metadata($.pool.token1()).balanceOf(address(this));
        amount0Desired = amount0Desired > token0Available ? token0Available : amount0Desired;
        amount1Desired = amount1Desired > token1Available ? token1Available : amount1Desired;

        if (params.tickUpper < params.currentTick) {
            amount0Desired = 0;
        } else if (params.tickLower > params.currentTick) {
            amount1Desired = 0;
        }
        if (amount0Desired == 0 && amount1Desired == 0) {
            // no tokens are needed
            return;
        }
        uint256 amount0Slippage = amount0Desired.mul(uint256(10_000).sub(params.slippage)).div(10_000);
        uint256 amount1Slippage = amount1Desired.mul(uint256(10_000).sub(params.slippage)).div(10_000);
        if (amount0Desired > 0 && amount1Desired > 0) {
            // both tokens are needed
            amount0Slippage = 0;
            amount1Slippage = 0;
        }
        // Check if the desired amounts are valid
        if (_calculateLiquidity(amount0Desired, amount1Desired, params.tickLower, params.tickUpper) == 0) {
            return;
        }

        (uint256 existingTokenId) = _getPositionFromTicks(params.tickLower, params.tickUpper);
        if (existingTokenId > 0) {
            _addLiquidityToExistingPosition(
                existingTokenId, amount0Desired, amount1Desired, amount0Slippage, amount1Slippage
            );
            return;
        }

        _mintNewPosition(
            params.tickLower, params.tickUpper, amount0Desired, amount1Desired, amount0Slippage, amount1Slippage
        );
    }

    /**
     * @dev Adds liquidity to an existing position.
     * @param tokenId The token ID of the existing position.
     * @param amount0Desired Desired amount of token0.
     * @param amount1Desired Desired amount of token1.
     * @param amount0Min Minimum amount of token0 (after slippage).
     * @param amount1Min Minimum amount of token1 (after slippage).
     */
    function _addLiquidityToExistingPosition(
        uint256 tokenId,
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
        $.positions[tokenId].liquidity += newLiquidity;
        emit GridDeposit(msg.sender, amount0, amount1);
        assert(amount0 > 0 || amount1 > 0); // Ensure at least one token is deposited
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
        require($.activePositionTokens.length + 1 <= 1_000, "E07");
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
        $.positions[tokenId] =
            Position({tokenId: tokenId, tickLower: tickLower, tickUpper: tickUpper, liquidity: liquidity});

        // Add the new position to the active positions list
        $.activePositionTokens.push(tokenId); // Use positions.length - 1 directly
        emit GridDeposit(msg.sender, amount0, amount1);
        assert(amount0 > 0 || amount1 > 0); // Ensure at least one token is deposited
    }

    /**
     * @dev Decreases liquidity and collects tokens for a given position.
     * @param tokenId The token ID of the position.
     * @param liquidity The amount of liquidity to decrease.
     */
    function _decreaseLiquidityAndCollect(uint256 tokenId, uint128 liquidity) internal {
        GridPositionManagerStorage storage $ = _getStorage();
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
    }

    /**
     * @dev Removes all active liquidity positions.
     */
    function _removeActiveLiquidity() internal {
        GridPositionManagerStorage storage $ = _getStorage();
        uint256 length = $.activePositionTokens.length;
        for (uint256 i = 0; i < length; i++) {
            Position memory position = $.positions[$.activePositionTokens[i]];
            // Collect fees from the position
            _decreaseLiquidityAndCollect(position.tokenId, position.liquidity);
            // Update the position's liquidity to 0
            delete $.positions[position.tokenId];
        }
        delete $.activePositionTokens;
    }

    /**
     * @dev Calculates grid ticks based on the target tick and pool's tick spacing.
     *      Ignores the grid that is within the range of the target tick.
     * @param targetTick The target tick for the grid.
     * @param gridType The type of grid (NEUTRAL, BUY, SELL).
     * @return An array of grid ticks.
     */
    function _calculateGridTicks(int24 targetTick, GridTickCalculator.GridType gridType)
        internal
        view
        returns (int24[] memory)
    {
        GridPositionManagerStorage storage $ = _getStorage();
        return GridTickCalculator.calculateGridTicks(
            targetTick, gridType, $.gridQuantity, $.gridStep, $.pool.tickSpacing()
        );
    }

    /**
     * @dev Finds a position by its lower and upper ticks.
     * @param tickLower The lower tick of the position.
     * @param tickUpper The upper tick of the position.
     * @return The token ID the position.
     */
    function _getPositionFromTicks(int24 tickLower, int24 tickUpper) internal view returns (uint256) {
        GridPositionManagerStorage storage $ = _getStorage();
        uint256 lenght = $.activePositionTokens.length;
        for (uint256 i = 0; i < lenght; i++) {
            uint256 tokenId = $.activePositionTokens[i];
            Position memory position = $.positions[tokenId];
            if (position.tickLower == tickLower && position.tickUpper == tickUpper) {
                return tokenId;
            }
        }
        return 0;
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

    function getGridQuantity() external view override returns (uint256) {
        GridPositionManagerStorage storage $ = _getStorage();
        return $.gridQuantity;
    }

    function getGridStep() external view override returns (uint256) {
        GridPositionManagerStorage storage $ = _getStorage();
        return $.gridStep;
    }

    function getPosition(uint256 tokenId) external view override returns (Position memory) {
        GridPositionManagerStorage storage $ = _getStorage();
        return $.positions[tokenId];
    }

    function getActivePositions() external view override returns (Position[] memory) {
        GridPositionManagerStorage storage $ = _getStorage();
        Position[] memory activePositions = new Position[]($.activePositionTokens.length);
        for (uint256 i = 0; i < $.activePositionTokens.length; i++) {
            activePositions[i] = $.positions[$.activePositionTokens[i]];
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
        uint256 length = $.activePositionTokens.length;
        for (uint256 i = 0; i < length; i++) {
            uint256 tokenId = $.activePositionTokens[i];
            Position memory position = $.positions[tokenId];
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
        int24 currentTick = _getCurrentTick();

        for (uint256 i = 0; i < $.activePositionTokens.length; i++) {
            uint256 tokenId = $.activePositionTokens[i];
            Position memory position = $.positions[tokenId];
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
        require(balance > 0, "E09");
        (bool success,) = msg.sender.call{value: balance}("");
        require(success, "Ether transfer failed");
    }

    /**
     * @dev Fetches the Time Weighted Average Price (TWAP) tick over a given time window.
     * @return averageTick The average tick over the specified time window.
     */
    function _getTWAP() internal view returns (int24 averageTick) {
        int24 secondsAgo = int24(300); // 5 minutes

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
     * @dev Validates the price deviation between the current tick and TWAP tick.
     * @param currentTick The current tick of the pool.
     * @param twapTick The TWAP tick of the pool.
     * @param maxDeviation The maximum allowable deviation.
     */
    function _validatePrice(int24 currentTick, int24 twapTick, uint256 maxDeviation) internal pure {
        int24 deviation = currentTick > twapTick ? currentTick - twapTick : twapTick - currentTick;
        require(deviation <= int24(maxDeviation), "E10");
    }

    function _getCurrentTick() internal view returns (int24) {
        GridPositionManagerStorage storage $ = _getStorage();
        (, int24 currentTick,,,,,) = $.pool.slot0();
        return currentTick;
    }

    function _calculateLiquidity(uint256 amount0Desired, uint256 amount1Desired, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint128 liquidity)
    {
        GridPositionManagerStorage storage $ = _getStorage();
        (uint160 sqrtPriceX96,,,,,,) = $.pool.slot0();
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, amount0Desired, amount1Desired
        );
    }
}
