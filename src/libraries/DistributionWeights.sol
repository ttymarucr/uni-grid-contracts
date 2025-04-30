// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;

library DistributionWeights {
    enum DistributionType {
        FLAT,
        LINEAR,
        REVERSE_LINEAR,
        SIGMOID,
        FIBONACCI,
        LOGARITHMIC
    }

    function getWeights(uint256 gridLength, DistributionType distributionType)
        internal
        pure
        returns (uint256[] memory)
    {
        uint256[] memory weights = new uint256[](gridLength);

        if (distributionType == DistributionType.FLAT) {
            // Flat distribution: All grid intervals receive equal weight.
            for (uint256 i = 0; i < gridLength; i++) {
                weights[i] = 10000 / gridLength; // Equal distribution
            }
        } else if (distributionType == DistributionType.LINEAR) {
            // Curved distribution: Weights increase linearly from the first to the last interval.
            // This creates a triangular distribution where later intervals receive more weight.
            for (uint256 i = 0; i < gridLength; i++) {
                weights[i] = (i + 1) * 10000 / (gridLength * (gridLength + 1) / 2); // Linear growth
            }
        } else if (distributionType == DistributionType.REVERSE_LINEAR) {
            // Linear distribution: Weights decrease linearly from the first to the last interval.
            // This creates a linear decay where earlier intervals receive more weight.
            for (uint256 i = 0; i < gridLength; i++) {
                weights[i] = (gridLength - i) * 10000 / (gridLength * (gridLength + 1) / 2); // Linear decay
            }
        } else if (distributionType == DistributionType.SIGMOID) {
            // Sigmoid distribution: Not implemented. Typically, this would create an S-shaped curve.
            revert("E11"); // Sigmoid distribution not implemented
        } else if (distributionType == DistributionType.FIBONACCI) {
            // Fibonacci distribution: Weights are based on the Fibonacci sequence.
            // Each interval's weight is proportional to its Fibonacci number.
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
            // Logarithmic distribution: Not implemented. Typically, this would create a logarithmic curve.
            revert("E11"); // Logarithmic distribution not implemented
        }

        return weights;
    }
}
