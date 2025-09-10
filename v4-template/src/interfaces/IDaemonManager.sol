// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IDaemonManager {
    // Events
    event DaemonAdded(address indexed daemon, uint16 id, address indexed owner);
    event DaemonActivated(address indexed daemon, uint16 id);
    event DaemonDeactivated(address indexed daemon, uint16 id);
    event DaemonBanned(address indexed daemon, uint16 id);

    // Core functions
    function addDaemon(address daemon, address owner) external;
    function addManyDaemons(address[] calldata daemons, address[] calldata owners) external;
    function activateDaemon(address daemon) external;
    function deactivateDaemon(address daemon) external;
    function banDaemon(address daemon) external;
    
    // View functions
    function exists(address daemon) external view returns (bool);
    function active(address daemon) external view returns (bool);
    function banned(address daemon) external view returns (bool);
    function getDaemonOwner(address daemon) external view returns (address);
    function getDaemonById(uint16 id) external view returns (address);
    function getDaemonId(address daemon) external view returns (uint16);
    function getTotalDaemons() external view returns (uint256);
    
    // Aggregation functions
    function aggregateRebateAmounts(uint256 start, uint256 count, uint256 blockNumber) 
        external view returns (int128[] memory);
    function aggregateActiveDaemonRebates(uint256 blockNumber) 
        external view returns (int128[] memory);
}
