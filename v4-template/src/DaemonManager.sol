// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IDaemonManager} from "./interfaces/IDaemonManager.sol";
import {IDaemon} from "./interfaces/IDaemon.sol";
import {ZeroAddress, DuplicateDaemon, CapacityExceeded, IdDoesNotExist, NotExist, DaemonIsBanned, NotDaemonOwner, CountInvalid, StartInvalid} from "./base/Errors.sol";

contract DaemonManager is IDaemonManager {
    // Constants
    uint256 public constant MAX_DAEMONS = 3200;
    
    // Storage
    address[] private _daemonAddresses;
    mapping(address => bool) public exists;
    mapping(address => uint16) public addressToId;
    mapping(uint16 => address) public idToAddress;
    mapping(address => bool) public active;
    mapping(address => address) public daemonOwner;
    mapping(address => bool) public banned;
    
    // Access control
    address public owner;
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }
    
    modifier onlyDaemonOwner(address daemon) {
        require(msg.sender == daemonOwner[daemon], "Not daemon owner");
        _;
    }
    
    constructor(address _owner) {
        owner = _owner;
    }
    
    function addDaemon(address daemon, address daemonOwnerAddr) external onlyOwner {
        _addDaemon(daemon, daemonOwnerAddr);
    }
    
    function addManyDaemons(address[] calldata daemons, address[] calldata owners) external onlyOwner {
        require(daemons.length == owners.length, "Length mismatch");
        for (uint256 i = 0; i < daemons.length; i++) {
            _addDaemon(daemons[i], owners[i]);
        }
    }
    
    function _addDaemon(address daemon, address daemonOwnerAddr) internal {
        if (daemon == address(0)) revert ZeroAddress();
        if (exists[daemon]) revert DuplicateDaemon();
        if (_daemonAddresses.length >= MAX_DAEMONS) revert CapacityExceeded();
        
        uint16 daemonId = uint16(_daemonAddresses.length);
        exists[daemon] = true;
        addressToId[daemon] = daemonId;
        idToAddress[daemonId] = daemon;
        _daemonAddresses.push(daemon);
        daemonOwner[daemon] = daemonOwnerAddr;
        
        emit DaemonAdded(daemon, daemonId, daemonOwnerAddr);
    }
    
    function activateDaemon(address daemon) external {
        require(msg.sender == owner || msg.sender == daemonOwner[daemon], "Not authorized");
        _setActive(daemon, true);
    }
    
    function deactivateDaemon(address daemon) external {
        require(msg.sender == owner || msg.sender == daemonOwner[daemon], "Not authorized");
        _setActive(daemon, false);
    }
    
    function _setActive(address daemon, bool isActive) internal {
        if (!exists[daemon]) revert NotExist();
        if (isActive && banned[daemon]) revert DaemonIsBanned();
        
        active[daemon] = isActive;
        uint16 daemonId = addressToId[daemon];
        
        if (isActive) {
            emit DaemonActivated(daemon, daemonId);
        } else {
            emit DaemonDeactivated(daemon, daemonId);
        }
    }
    
    function banDaemon(address daemon) external onlyOwner {
        if (!exists[daemon]) revert NotExist();
        
        uint16 daemonId = addressToId[daemon];
        banned[daemon] = true;
        
        if (active[daemon]) {
            active[daemon] = false;
            emit DaemonDeactivated(daemon, daemonId);
        }
        
        emit DaemonBanned(daemon, daemonId);
    }
    
    // View functions
    function getDaemonOwner(address daemon) external view returns (address) {
        return daemonOwner[daemon];
    }
    
    function getDaemonById(uint16 id) external view returns (address) {
        address daemon = idToAddress[id];
        if (daemon == address(0)) revert IdDoesNotExist();
        return daemon;
    }
    
    function getDaemonId(address daemon) external view returns (uint16) {
        if (!exists[daemon]) revert NotExist();
        return addressToId[daemon];
    }
    
    function getTotalDaemons() external view returns (uint256) {
        return _daemonAddresses.length;
    }
    
    // Aggregation functions
    function aggregateRebateAmounts(uint256 start, uint256 count, uint256 blockNumber) 
        external view returns (int128[] memory amounts) 
    {
        if (!(count > 0 && count <= 800)) revert CountInvalid();
        uint256 total = _daemonAddresses.length;
        if (start > total) revert StartInvalid();
        
        uint256 available = total > start ? total - start : 0;
        uint256 toTake = count < available ? count : available;
        amounts = new int128[](toTake);
        
        for (uint256 i = 0; i < toTake; i++) {
            address daemon = _daemonAddresses[start + i];
            if (!active[daemon]) {
                amounts[i] = 0;
                continue;
            }
            
            try IDaemon(daemon).getRebateAmount(blockNumber) returns (int128 value) {
                amounts[i] = value;
            } catch {
                amounts[i] = 0;
            }
        }
    }
    
    function aggregateActiveDaemonRebates(uint256 blockNumber) 
        external view returns (int128[] memory amounts) 
    {
        uint256 total = _daemonAddresses.length;
        amounts = new int128[](total);
        
        for (uint256 i = 0; i < total; i++) {
            address daemon = _daemonAddresses[i];
            if (!active[daemon]) {
                amounts[i] = 0;
                continue;
            }
            
            try IDaemon(daemon).getRebateAmount(blockNumber) returns (int128 value) {
                amounts[i] = value;
            } catch {
                amounts[i] = 0;
            }
        }
    }
}
