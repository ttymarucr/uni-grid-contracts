// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/GridPositionManager.sol";

contract GridPositionManagerTest is Test {
    GridPositionManager public manager;

    function setUp() public {
        address mockPool = address(0x123);
        address mockPositionManager = address(0x456);
        uint256 targetPrice = 1000;
        uint256 gridPercentage = 5;

        manager = new GridPositionManager(mockPool, mockPositionManager, targetPrice, gridPercentage);
    }

    function testInitialValues() public {
        assertEq(manager.targetPrice(), 1000);
        assertEq(manager.gridPercentage(), 5);
    }

    function testUpdateTargetPrice() public {
        manager.updateTargetPrice(2000);
        assertEq(manager.targetPrice(), 2000);
    }

    function testUpdateGridPercentage() public {
        manager.updateGridPercentage(10);
        assertEq(manager.gridPercentage(), 10);
    }
}
