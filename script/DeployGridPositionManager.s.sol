// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import "forge-std/Script.sol";
import "../src/GridPositionManager.sol";

contract DeployGridPositionManager is Script {
    function run() external {
        vm.startBroadcast();

        // Deploy the GridPositionManager contract
        address pool = 0xd0b53D9277642d899DF5C87A3966A349A798F224; // Replace with actual pool address
        address positionManager = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1; // Replace with actual position manager address
        uint256 gridQuantity = 40; // Replace with actual grid size
        uint256 gridStep = 20; // Replace with actual grid step
        GridPositionManager gridPositionManager = new GridPositionManager(pool, positionManager, gridQuantity, gridStep);

        // Log the deployed contract address
        console.log("GridPositionManager deployed at:", address(gridPositionManager));

        vm.stopBroadcast();
    }
}
