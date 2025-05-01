// SPDX-License-Identifier: MIT
pragma abicoder v2;
pragma solidity ^0.7.6;

import "forge-std/Test.sol";
import "../src/libraries/GridTickCalculator.sol";
import {console} from "forge-std/console.sol";

contract GridTickCalculatorTest is Test {
    using GridTickCalculator for int24;

    function testCalculateGridTicksNeutral() public pure {
        int24 targetTick = 1000;
        uint256 gridQuantity = 6;
        uint256 gridStep = 2;
        int24 tickSpacing = 10;

        int24[] memory gridTicks = GridTickCalculator.calculateGridTicks(
            targetTick, GridTickCalculator.GridType.NEUTRAL, gridQuantity, gridStep, tickSpacing
        );

        int24[] memory expectedTicks = new int24[](7);
        expectedTicks[0] = 940;
        expectedTicks[1] = 960;
        expectedTicks[2] = 980;
        expectedTicks[3] = 1000;
        expectedTicks[4] = 1020;
        expectedTicks[5] = 1040;
        expectedTicks[6] = 1060;

        for (uint256 i = 0; i < gridTicks.length; i++) {
            assertEq(gridTicks[i], expectedTicks[i], "Neutral grid tick mismatch");
        }
    }

    function testCalculateGridTicksBuy() public pure {
        int24 targetTick = 1000;
        uint256 gridQuantity = 4;
        uint256 gridStep = 1;
        int24 tickSpacing = 10;

        int24[] memory gridTicks = GridTickCalculator.calculateGridTicks(
            targetTick, GridTickCalculator.GridType.BUY, gridQuantity, gridStep, tickSpacing
        );

        int24[] memory expectedTicks = new int24[](5);
        expectedTicks[0] = 960;
        expectedTicks[1] = 970;
        expectedTicks[2] = 980;
        expectedTicks[3] = 990;
        expectedTicks[4] = 1000;

        for (uint256 i = 0; i < gridTicks.length; i++) {
            assertEq(gridTicks[i], expectedTicks[i], "Buy grid tick mismatch");
        }
    }

    function testCalculateGridTicksSell() public pure {
        int24 targetTick = 1000;
        uint256 gridQuantity = 4;
        uint256 gridStep = 1;
        int24 tickSpacing = 10;

        int24[] memory gridTicks = GridTickCalculator.calculateGridTicks(
            targetTick, GridTickCalculator.GridType.SELL, gridQuantity, gridStep, tickSpacing
        );

        int24[] memory expectedTicks = new int24[](5);
        expectedTicks[0] = 1000;
        expectedTicks[1] = 1010;
        expectedTicks[2] = 1020;
        expectedTicks[3] = 1030;
        expectedTicks[4] = 1040;

        for (uint256 i = 0; i < gridTicks.length; i++) {
            assertEq(gridTicks[i], expectedTicks[i], "Sell grid tick mismatch");
        }
    }

    function testRevertOnInvalidGridQuantity() public {
        vm.skip(true);
        int24 targetTick = 1000;
        uint256 gridQuantity = 0;
        uint256 gridStep = 2;
        int24 tickSpacing = 10;

        vm.expectRevert(bytes("E03"));
        GridTickCalculator.calculateGridTicks(
            targetTick, GridTickCalculator.GridType.NEUTRAL, gridQuantity, gridStep, tickSpacing
        );
    }

    function testRevertOnInvalidGridStep() public {
        vm.skip(true);
        int24 targetTick = 1000;
        uint256 gridQuantity = 6;
        uint256 gridStep = 0;
        int24 tickSpacing = 10;

        vm.expectRevert(bytes("E04"));
        GridTickCalculator.calculateGridTicks(
            targetTick, GridTickCalculator.GridType.NEUTRAL, gridQuantity, gridStep, tickSpacing
        );
    }

    function testRevertOnNegativeTickSpacing() public {
        vm.skip(true);
        int24 targetTick = 1000;
        uint256 gridQuantity = 6;
        uint256 gridStep = 2;
        int24 tickSpacing = -10;

        vm.expectRevert(bytes("E05"));
        GridTickCalculator.calculateGridTicks(
            targetTick, GridTickCalculator.GridType.NEUTRAL, gridQuantity, gridStep, tickSpacing
        );
    }

    function testRevertOnExcessiveGridQuantity() public {
        vm.skip(true);
        int24 targetTick = 1000;
        uint256 gridQuantity = 10000; // Excessive value
        uint256 gridStep = 2;
        int24 tickSpacing = 10;

        vm.expectRevert(bytes("E06"));
        GridTickCalculator.calculateGridTicks(
            targetTick, GridTickCalculator.GridType.NEUTRAL, gridQuantity, gridStep, tickSpacing
        );
    }
}
