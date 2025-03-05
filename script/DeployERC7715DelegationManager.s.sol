// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { EntryPoint } from "@account-abstraction/core/EntryPoint.sol";

import { ERC7715DelegationManager } from "../src/ERC7715/ERC7715DelegationManager.sol";
import { EIP7702StatelessDeleGator } from "../src/EIP7702/EIP7702StatelessDeleGator.sol";
import { SimpleFactory } from "../src/utils/SimpleFactory.sol";

/**
 * @title DeployERC7715DelegationManager
 * @notice Deployment script for ERC-7715 Delegation Manager
 */
contract DeployERC7715DelegationManager is Script {
    // Constants
    address payable public constant ENTRY_POINT_ADDRESS = payable(0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789);

    // State variables
    ERC7715DelegationManager public delegationManager;
    SimpleFactory public factory;
    EIP7702StatelessDeleGator public implementation;

    /**
     * @notice Main deployment function
     */
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Deploy the ERC7715DelegationManager
        delegationManager = new ERC7715DelegationManager();
        console.log("ERC7715DelegationManager deployed at:", address(delegationManager));

        // Deploy the EIP7702StatelessDeleGator implementation
        EntryPoint entryPoint = EntryPoint(ENTRY_POINT_ADDRESS);
        implementation = new EIP7702StatelessDeleGator(delegationManager, entryPoint);
        console.log("EIP7702StatelessDeleGator implementation deployed at:", address(implementation));

        // Deploy the SimpleFactory for creating new DeleGators
        factory = new SimpleFactory();
        console.log("SimpleFactory deployed at:", address(factory));

        vm.stopBroadcast();
    }
}
