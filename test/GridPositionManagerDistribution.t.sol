// SPDX-License-Identifier: MIT
pragma abicoder v2;
pragma solidity ^0.7.6;

import "forge-std/Test.sol";
import "../src/GridPositionManager.sol";

contract GridPositionManagerDistributionTest is Test {
    GridPositionManager gridPositionManager;

    function setUp() public {
        gridPositionManager = new GridPositionManager();
    }

    function testFlatDistribution() public view {
        uint256 gridLength = 5;
        uint256[] memory weights =
            gridPositionManager._getDistributionWeights(gridLength, IGridPositionManager.DistributionType.FLAT);

        for (uint256 i = 0; i < gridLength; i++) {
            assertEq(weights[i], 2000, "Flat distribution weight mismatch");
        }
    }

    function testCurvedDistribution() public view {
        uint256 gridLength = 5;
        uint256[] memory weights =
            gridPositionManager._getDistributionWeights(gridLength, IGridPositionManager.DistributionType.LINEAR);

        uint256[] memory expectedWeights = new uint256[](5);
        expectedWeights[0] = 666; // Example values
        expectedWeights[1] = 1333;
        expectedWeights[2] = 2000;
        expectedWeights[3] = 2666;
        expectedWeights[4] = 3333;

        for (uint256 i = 0; i < gridLength; i++) {
            assertEq(weights[i], expectedWeights[i], "Curved distribution weight mismatch");
        }
    }

    function testLinearDistribution() public view {
        uint256 gridLength = 5;
        uint256[] memory weights =
            gridPositionManager._getDistributionWeights(gridLength, IGridPositionManager.DistributionType.REVERSE_LINEAR);

        uint256[] memory expectedWeights = new uint256[](5);
        expectedWeights[0] = 3333; // Example values
        expectedWeights[1] = 2666;
        expectedWeights[2] = 2000;
        expectedWeights[3] = 1333;
        expectedWeights[4] = 666;

        for (uint256 i = 0; i < gridLength; i++) {
            assertEq(weights[i], expectedWeights[i], "Linear distribution weight mismatch");
        }
    }

    function testFibonacciDistribution() public view {
        uint256 gridLength = 5;
        uint256[] memory weights =
            gridPositionManager._getDistributionWeights(gridLength, IGridPositionManager.DistributionType.FIBONACCI);

        uint256[] memory expectedWeights = new uint256[](5);
        expectedWeights[0] = 833; // Example values
        expectedWeights[1] = 833;
        expectedWeights[2] = 1666;
        expectedWeights[3] = 2500;
        expectedWeights[4] = 4166;

        for (uint256 i = 0; i < gridLength; i++) {
            assertEq(weights[i], expectedWeights[i], "Fibonacci distribution weight mismatch");
        }
    }

    function testLogarithmicDistribution() public {
        vm.expectRevert("E11: Logarithmic distribution not implemented");
        gridPositionManager._getDistributionWeights(5, IGridPositionManager.DistributionType.LOGARITHMIC);
    }

    function testSigmoidDistribution() public {
        vm.expectRevert("E11: Sigmoid distribution not implemented");
        gridPositionManager._getDistributionWeights(5, IGridPositionManager.DistributionType.SIGMOID);
    }
}
