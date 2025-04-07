// SPDX-License-Identifier: MIT
pragma abicoder v2;
pragma solidity ^0.7.6;

import "@openzeppelin/contracts/proxy/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/BeaconProxy.sol";
import "./utils/AddressUpgradeable.sol";
import "./GridPositionManager.sol";
import "./access/OwnableUpgradeable.sol";

contract GridManager is UpgradeableBeacon {

    event GridManagerDeployed(
        address indexed owner,
        address indexed pool,
        address indexed positionManager,
        uint256 gridSize,
        uint256 gridStep
    );

    constructor(address implementation_) UpgradeableBeacon(implementation_) {}

    function delployGridPositionManager(
        address pool,
        address positionManager,
        uint256 gridSize,
        uint256 gridStep
    ) external returns (address) {
        bytes memory data = abi.encodeWithSelector(
            GridPositionManager.initialize.selector,
            pool,
            positionManager,
            gridSize,
            gridStep
        );
        BeaconProxy proxy = new BeaconProxy(address(this), data);
        AddressUpgradeable.functionCall(
            address(proxy),
            abi.encodeWithSelector(OwnableUpgradeable.transferOwnership.selector, msg.sender)
        );
        emit GridManagerDeployed(msg.sender, pool, positionManager, gridSize, gridStep);
        return address(proxy);
    }
}