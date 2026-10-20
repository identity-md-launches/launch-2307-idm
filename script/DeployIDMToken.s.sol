// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IDMToken} from "../src/IDMToken.sol";

/// @title Local deploy script for IDMToken
/// @notice For local and test-network use only. The production launch on Robinhood Chain is
/// performed by IMD's ProjectFactory from the attested bytecode; nobody runs this script for it.
/// @dev The constructor takes no arguments, so there is no configuration to read. `deploy()` is a
/// plain function the tests call directly; `run()` only wraps it in a broadcast.
contract DeployIDMToken is Script {
    /// @notice Deploys the token. The whole supply goes to whoever is `msg.sender` of the
    /// constructor: the broadcasting account under `run()`, or the caller's contract in a test.
    function deploy() public returns (IDMToken token) {
        token = new IDMToken();
    }

    function run() external returns (IDMToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
