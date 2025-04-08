// SPDX-License-Identifier: MIT
pragma abicoder v2;
pragma solidity ^0.7.6;

import "@openzeppelin/contracts/proxy/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/BeaconProxy.sol";
import "./utils/AddressUpgradeable.sol";
import "./GridPositionManager.sol";
import "./access/OwnableUpgradeable.sol";

contract GridManager is UpgradeableBeacon {
    event GridDeployed(address indexed owner, address indexed gridPositionManager, address pool);

    constructor(address implementation_) UpgradeableBeacon(implementation_) {}

    function delployGridPositionManager(address pool, address positionManager, uint256 gridSize, uint256 gridStep)
        external
        returns (address)
    {
        bytes memory data =
            abi.encodeWithSelector(GridPositionManager.initialize.selector, pool, positionManager, gridSize, gridStep);
        BeaconProxy proxy = new BeaconProxy(address(this), data);
        AddressUpgradeable.functionCall(
            address(proxy), abi.encodeWithSelector(OwnableUpgradeable.transferOwnership.selector, msg.sender)
        );
        emit GridDeployed(msg.sender, address(proxy), pool);
        return address(proxy);
    }
}
