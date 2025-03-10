// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";

/**
 * @title SimpleTest
 * @notice A simple test to verify that tests can run
 */
contract SimpleTest is Test {
    function setUp() public {
        // Nothing to set up
    }

    function test_simple() public {
        assertTrue(true);
    }
}
