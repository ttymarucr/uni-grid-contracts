// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import "forge-std/Test.sol";
import "../src/GridPositionManager.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol, uint256 initialSupply) ERC20(name, symbol) {
        _mint(msg.sender, initialSupply);
    }
}

contract GridPositionManagerTest is Test {
    GridPositionManager public manager;
    MockERC20 public token0;
    MockERC20 public token1;
    address public owner = address(this);
    address public mockPool = address(0x123);
    address public mockPositionManager = address(0x456);

    function setUp() public {
        token0 = new MockERC20("Token0", "TK0", 1e24); // 1 million tokens
        token1 = new MockERC20("Token1", "TK1", 1e24); // 1 million tokens

        vm.mockCall(
            mockPool,
            abi.encodeWithSelector(IUniswapV3Pool.token0.selector),
            abi.encode(address(token0))
        );
        vm.mockCall(
            mockPool,
            abi.encodeWithSelector(IUniswapV3Pool.token1.selector),
            abi.encode(address(token1))
        );
        vm.mockCall(
            mockPool,
            abi.encodeWithSelector(IUniswapV3Pool.tickSpacing.selector),
            abi.encode(60)
        );

        manager = new GridPositionManager(mockPool, mockPositionManager, 5, 20);
    }

    function testCalculateGridPrices() public {
        uint256 targetPrice = 1000 * 1e18; // Example target price
        uint256[] memory gridPrices = manager.calculateGridPrices(targetPrice);

        assertEq(gridPrices.length, 9); // Example: 8 grids + 1
        assertEq(gridPrices[0], 800 * 1e18); // Lower bound
        assertEq(gridPrices[8], 1200 * 1e18); // Upper bound
    }

    function testCreateGridPositions() public {
        uint256 token0Amount = 1e21; // 1000 tokens
        uint256 token1Amount = 1e21; // 1000 tokens

        token0.approve(address(manager), token0Amount);
        token1.approve(address(manager), token1Amount);

        vm.mockCall(
            mockPositionManager,
            abi.encodeWithSelector(INonfungiblePositionManager.mint.selector),
            abi.encode(1, 0, 0)
        );

        manager.createGridPositions(token0Amount, token1Amount);

        // Validate balances
        assertEq(token0.balanceOf(address(manager)), token0Amount);
        assertEq(token1.balanceOf(address(manager)), token1Amount);
    }

    function testUpdateGridPercentage() public {
        uint256 newGridPercentage = 10;
        manager.updateGridPercentage(newGridPercentage);

        assertEq(manager.gridPercentage(), newGridPercentage);
    }

    function testUpdateTargetPrice() public {
        uint256 newTargetPrice = 1500 * 1e18;
        manager.updateTargetPrice(newTargetPrice);

        // Mocking not needed for this test
        assertEq(manager.targetPrice(), newTargetPrice);
    }
}
