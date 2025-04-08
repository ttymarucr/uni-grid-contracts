// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import "forge-std/Script.sol";
import "../src/GridPositionManager.sol";
import "../src/GridManager.sol";

contract DeployGridPositionManager is Script {
    function run() external {
        vm.createSelectFork("base");
        vm.startBroadcast();

        // Deploy the GridPositionManager implementation contract
        // GridPositionManager gridPositionManagerImplementation = new GridPositionManager();
        address gridPositionManagerImplementation = 0x0e4FE67d89609B2394EB23bfF1206e82A639bB36;
        // Deploy the UpgradeableBeacon with the implementation address
        GridManager gridManager = new GridManager(address(gridPositionManagerImplementation));

        address gridPositionManager = gridManager.delployGridPositionManager(
            0xd0b53D9277642d899DF5C87A3966A349A798F224, // Replace with actual pool address
            0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1, // Replace with actual position manager address
            20, // Replace with actual grid size
            10 // Replace with actual grid step
        );

        // Log the deployed proxy contract address
        console.log("GridPositionManager Implementation deployed at:", address(gridPositionManagerImplementation));
        console.log("GridManager deployed at:", address(gridManager));
        console.log("GridPositionManager Proxy deployed at:", gridPositionManager);

        vm.stopBroadcast();
    }
}
