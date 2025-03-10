// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";

/**
 * @title IsolatedSimpleTest
 * @notice A simple test that doesn't depend on any other contracts in the codebase
 */
contract IsolatedSimpleTest is Test {
    function setUp() public {
        // Nothing to set up
    }

    function test_simple() public {
        assertTrue(true);
    }
}
