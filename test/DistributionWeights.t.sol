// SPDX-License-Identifier: MIT
pragma abicoder v2;
pragma solidity ^0.7.6;

import "forge-std/Test.sol";
import "../src/libraries/DistributionWeights.sol";

contract DistributionWeightsTest is Test {
    using DistributionWeights for uint256;

    function testFlatDistribution() public pure {
        uint256 gridLength = 5;
        uint256[] memory weights = gridLength.getWeights(DistributionWeights.DistributionType.FLAT);

        for (uint256 i = 0; i < gridLength; i++) {
            assertEq(weights[i], 2000, "Flat distribution weight mismatch");
        }
    }

    function testLinearDistribution() public pure {
        uint256 gridLength = 5;
        uint256[] memory weights = gridLength.getWeights(DistributionWeights.DistributionType.LINEAR);

        uint256[] memory expectedWeights = new uint256[](5);
        expectedWeights[0] = 666; // Example values
        expectedWeights[1] = 1333;
        expectedWeights[2] = 2000;
        expectedWeights[3] = 2666;
        expectedWeights[4] = 3333;

        for (uint256 i = 0; i < gridLength; i++) {
            assertEq(weights[i], expectedWeights[i], "Linear distribution weight mismatch");
        }
    }

    function testReverseLinearDistribution() public pure {
        uint256 gridLength = 5;
        uint256[] memory weights = gridLength.getWeights(DistributionWeights.DistributionType.REVERSE_LINEAR);

        uint256[] memory expectedWeights = new uint256[](5);
        expectedWeights[0] = 3333; // Example values
        expectedWeights[1] = 2666;
        expectedWeights[2] = 2000;
        expectedWeights[3] = 1333;
        expectedWeights[4] = 666;

        for (uint256 i = 0; i < gridLength; i++) {
            assertEq(weights[i], expectedWeights[i], "Reverse linear distribution weight mismatch");
        }
    }

    function testFibonacciDistribution() public pure {
        uint256 gridLength = 5;
        uint256[] memory weights = gridLength.getWeights(DistributionWeights.DistributionType.FIBONACCI);

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
        vm.skip(true);
        vm.expectRevert("E11: Logarithmic distribution not implemented");
        uint256(5).getWeights(DistributionWeights.DistributionType.LOGARITHMIC);
    }

    function testSigmoidDistribution() public {
        vm.skip(true);
        vm.expectRevert("E11: Sigmoid distribution not implemented");
        uint256(5).getWeights(DistributionWeights.DistributionType.SIGMOID);
    }
}
