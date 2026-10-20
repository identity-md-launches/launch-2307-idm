// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployIDMToken} from "../script/DeployIDMToken.s.sol";
import {IDMToken} from "../src/IDMToken.sol";

/// @notice Calls the script's deploy function directly: no environment, no broadcast.
contract DeployIDMTokenTest is Test {
    function test_deployMintsSupplyToTheDeployingAccount() public {
        DeployIDMToken deployer = new DeployIDMToken();
        IDMToken token = deployer.deploy();
        assertEq(token.name(), "idm");
        assertEq(token.symbol(), "IDM");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        // `new IDMToken()` runs with the script contract as msg.sender, so it holds the supply.
        assertEq(token.balanceOf(address(deployer)), 1_000_000_000 ether);
    }
}
