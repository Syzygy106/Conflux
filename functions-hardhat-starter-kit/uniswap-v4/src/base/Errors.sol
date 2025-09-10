// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Common custom errors to reduce bytecode size compared to revert strings

error NotHookOwner();
error ZeroAddress();
error ZeroValue();
error UnknownRequest();
error FunctionsError();
error AlreadyInitialized();
error IndexOutOfBounds();
error EmptyTop();
error LengthMismatch();

error DuplicateDaemon();
error CapacityExceeded();
error IdDoesNotExist();
error NotExist();
error DaemonIsBanned();
error NotDaemonOwner();
error CountInvalid();
error StartInvalid();
