// SPDX-License-Identifier: MIT
pragma abicoder v2;
pragma solidity ^0.7.0;

import "forge-std/Test.sol";
import "../src/GridPositionManager.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@uniswap/v3-core/contracts/interfaces/pool/IUniswapV3PoolImmutables.sol";

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
            mockPool, abi.encodeWithSelector(IUniswapV3PoolImmutables.token0.selector), abi.encode(address(token0))
        );
        vm.mockCall(
            mockPool, abi.encodeWithSelector(IUniswapV3PoolImmutables.token1.selector), abi.encode(address(token1))
        );
        vm.mockCall(mockPool, abi.encodeWithSelector(IUniswapV3PoolImmutables.tickSpacing.selector), abi.encode(60));

        manager = new GridPositionManager(mockPool, mockPositionManager, 5, 20);
    }

    function testCalculateGridPrices() public view {
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
            mockPositionManager, abi.encodeWithSelector(INonfungiblePositionManager.mint.selector), abi.encode(1, 0, 0)
        );

        manager.deposit(token0Amount, token1Amount);

        // Validate balances
        assertEq(token0.balanceOf(address(manager)), token0Amount);
        assertEq(token1.balanceOf(address(manager)), token1Amount);
    }

    function testCompound() public {
        uint256 token0Amount = 1e21; // 1000 tokens
        uint256 token1Amount = 1e21; // 1000 tokens

        token0.approve(address(manager), token0Amount);
        token1.approve(address(manager), token1Amount);

        // Mock minting positions
        vm.mockCall(
            mockPositionManager, abi.encodeWithSelector(INonfungiblePositionManager.mint.selector), abi.encode(1, 0, 0)
        );
        vm.mockCall(
            mockPositionManager, abi.encodeWithSelector(INonfungiblePositionManager.mint.selector), abi.encode(2, 0, 0)
        );

        manager.deposit(token0Amount, token1Amount);

        // Mock collecting fees
        vm.mockCall(
            mockPositionManager,
            abi.encodeWithSelector(INonfungiblePositionManager.collect.selector),
            abi.encode(500, 1000) // Collected fees for token0 and token1
        );

        // Mock increasing liquidity
        vm.mockCall(
            mockPositionManager,
            abi.encodeWithSelector(INonfungiblePositionManager.increaseLiquidity.selector),
            abi.encode(0, 0)
        );

        // Call compound
        manager.compound();

        // Validate that fees were collected and compounded
        uint256 managerToken0Balance = token0.balanceOf(address(manager));
        uint256 managerToken1Balance = token1.balanceOf(address(manager));
        assertEq(managerToken0Balance, 0); // All fees should be compounded
        assertEq(managerToken1Balance, 0); // All fees should be compounded
    }

    function testDeposit() public {
        uint256 token0Amount = 1e21; // 1000 tokens
        uint256 token1Amount = 1e21; // 1000 tokens

        token0.approve(address(manager), token0Amount);
        token1.approve(address(manager), token1Amount);

        // Mock minting positions
        vm.mockCall(
            mockPositionManager, abi.encodeWithSelector(INonfungiblePositionManager.mint.selector), abi.encode(1, 0, 0)
        );

        // Call deposit
        manager.deposit(token0Amount, token1Amount);

        // Validate balances
        assertEq(token0.balanceOf(address(manager)), token0Amount);
        assertEq(token1.balanceOf(address(manager)), token1Amount);

        // Validate that positions were created
        uint256 positionCount = manager.getPositionsLength();
        assertEq(positionCount, 1); // Ensure at least one position was created
    }

    function testWithdraw() public {
        uint256 token0Amount = 1e21; // 1000 tokens
        uint256 token1Amount = 1e21; // 1000 tokens

        token0.approve(address(manager), token0Amount);
        token1.approve(address(manager), token1Amount);

        // Mock minting positions
        vm.mockCall(
            mockPositionManager,
            abi.encodeWithSelector(INonfungiblePositionManager.mint.selector),
            abi.encode(1, 0, 0)
        );

        manager.deposit(token0Amount, token1Amount);

        // Mock position details
        vm.mockCall(
            mockPositionManager,
            abi.encodeWithSelector(INonfungiblePositionManager.positions.selector),
            abi.encode(1, 0, 0, 0, 0, 0, 0, 0, 1000, 0, 0, 0) // Mock liquidity of 1000
        );

        // Mock decreasing liquidity
        vm.mockCall(
            mockPositionManager,
            abi.encodeWithSelector(INonfungiblePositionManager.decreaseLiquidity.selector),
            abi.encode(0, 0)
        );

        // Mock collecting fees
        vm.mockCall(
            mockPositionManager,
            abi.encodeWithSelector(INonfungiblePositionManager.collect.selector),
            abi.encode(500, 1000) // Collected fees for token0 and token1
        );

        // Call withdraw
        manager.withdraw();

        // Validate that liquidity was removed and fees were collected
        uint256 managerToken0Balance = token0.balanceOf(address(manager));
        uint256 managerToken1Balance = token1.balanceOf(address(manager));
        assertEq(managerToken0Balance, 500); // Collected token0 fees
        assertEq(managerToken1Balance, 1000); // Collected token1 fees
    }
}
