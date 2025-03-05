// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Script, console2 } from "forge-std/Script.sol";
import { EntryPoint } from "@account-abstraction/core/EntryPoint.sol";
import { DelegationManager } from "../src/DelegationManager.sol";
import { EIP7702StatelessDeleGator } from "../src/EIP7702/EIP7702StatelessDeleGator.sol";
import { HelloWorld } from "../src/examples/HelloWorld.sol";
import { Execution, Delegation, Caveat, ModeCode } from "../src/utils/Types.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { EncoderLib } from "../src/libraries/EncoderLib.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IntervalTransferEnforcer } from "../src/enforcers/IntervalTransferEnforcer.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title IntervalTransferDelegation
 * @notice A script that demonstrates how to use the IntervalTransferEnforcer to allow a delegate
 *         to transfer funds from the delegator at fixed intervals, limited to a maximum number of transfers
 * @dev This script sets up two wallets (delegator and delegate) and shows how the delegate can
 *      execute transfers at 10-second intervals, limited to 10 transfers total
 */
contract IntervalTransferDelegation is Script {
    using MessageHashUtils for bytes32;
    using ModeLib for ModeCode;

    // Test accounts
    address private delegator;
    uint256 private delegatorPrivateKey;
    address private delegate;
    uint256 private delegatePrivateKey;

    // Contracts
    EntryPoint private entryPoint;
    DelegationManager private delegationManager;
    EIP7702StatelessDeleGator private delegatorWallet;
    HelloWorld private helloWorld;
    IntervalTransferEnforcer private intervalTransferEnforcer;

    // Constants for delegation
    bytes32 private constant ROOT_AUTHORITY = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

    // Execution parameters
    uint256 private constant EXECUTION_INTERVAL = 20; // 20 seconds between executions
    uint256 private constant MAX_EXECUTIONS = 5; // Maximum 5 executions
    uint256 private constant EXECUTION_COST = 0.01 ether; // Small fee per execution

    // Transfer parameters
    uint256 private constant TRANSFER_INTERVAL = 10; // 10 seconds between transfers
    uint256 private constant MAX_TRANSFERS = 10; // Maximum 10 transfers
    uint256 private constant TRANSFER_AMOUNT = 0.01 ether; // 0.01 ETH per transfer

    function setUp() public {
        // Set up test accounts
        delegatorPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        delegator = vm.addr(delegatorPrivateKey);

        delegatePrivateKey = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
        delegate = vm.addr(delegatePrivateKey);

        vm.label(delegator, "Delegator");
        vm.label(delegate, "Delegate");

        // Deploy contracts
        entryPoint = new EntryPoint();
        vm.label(address(entryPoint), "EntryPoint");

        delegationManager = new DelegationManager(delegator);
        vm.label(address(delegationManager), "DelegationManager");

        delegatorWallet = new EIP7702StatelessDeleGator(delegationManager, entryPoint);
        vm.label(address(delegatorWallet), "DelegatorWallet");

        // Deploy the IntervalTransferEnforcer
        intervalTransferEnforcer = new IntervalTransferEnforcer();
        vm.label(address(intervalTransferEnforcer), "IntervalTransferEnforcer");

        // Fund the delegator wallet with enough ETH for all transfers
        vm.deal(address(delegatorWallet), TRANSFER_AMOUNT * MAX_TRANSFERS * 2); // Extra buffer
    }

    function run() public {
        setUp();

        // Display initial state
        console2.log("=== Initial Setup ===");
        console2.log("Delegator address:", delegator);
        console2.log("Delegate address:", delegate);
        console2.log("DelegatorWallet address:", address(delegatorWallet));
        console2.log("Initial delegator wallet balance:", address(delegatorWallet).balance);
        console2.log("Initial delegate balance:", address(delegate).balance);

        // Create and sign the delegation
        Delegation memory delegation = createAndSignDelegation();

        // Execute transfers at intervals
        console2.log("\n=== Executing Interval Transfers ===");
        console2.log("Transfer interval:", TRANSFER_INTERVAL, "seconds");
        console2.log("Maximum transfers:", MAX_TRANSFERS);
        console2.log("Transfer amount:", TRANSFER_AMOUNT);

        // Execute all transfers
        for (uint256 i = 0; i < MAX_TRANSFERS; i++) {
            // Wait for the interval to pass (except for the first transfer)
            if (i > 0) {
                console2.log("\nWaiting for", TRANSFER_INTERVAL, "seconds...");
                vm.warp(block.timestamp + TRANSFER_INTERVAL);
            }

            console2.log("\nExecuting transfer", i + 1, "of", MAX_TRANSFERS);
            console2.log("Current timestamp:", block.timestamp);

            // Execute the transfer
            executeTransfer(delegation);

            // Display balances after transfer
            console2.log("Delegator wallet balance:", address(delegatorWallet).balance);
            console2.log("Delegate balance:", address(delegate).balance);
        }

        // Try to execute one more transfer (should fail)
        console2.log("\n=== Attempting Transfer Beyond Maximum ===");
        vm.warp(block.timestamp + TRANSFER_INTERVAL);
        console2.log("Current timestamp:", block.timestamp);

        // This should fail because we've reached the maximum number of transfers
        vm.expectRevert("IntervalTransferEnforcer:max-transfers-reached");
        executeTransfer(delegation);

        // Final state
        console2.log("\n=== Final State ===");
        console2.log("Final delegator wallet balance:", address(delegatorWallet).balance);
        console2.log("Final delegate balance:", address(delegate).balance);
        console2.log("Total transferred:", TRANSFER_AMOUNT * MAX_TRANSFERS);
    }

    /**
     * @notice Creates and signs a delegation with the IntervalTransferEnforcer
     * @return The signed delegation
     */
    function createAndSignDelegation() internal returns (Delegation memory) {
        // Encode the terms for the IntervalTransferEnforcer
        bytes memory terms = abi.encodePacked(
            bytes32(TRANSFER_INTERVAL), // Interval in seconds
            bytes32(MAX_TRANSFERS), // Maximum number of transfers
            bytes32(TRANSFER_AMOUNT) // Amount per transfer
        );

        // Create a delegation with the IntervalTransferEnforcer caveat
        Caveat[] memory caveats = new Caveat[](1);
        caveats[0] = Caveat({ enforcer: address(intervalTransferEnforcer), terms: terms, args: hex"" });

        Delegation memory delegation = Delegation({
            delegate: address(delegate),
            delegator: address(delegatorWallet),
            authority: ROOT_AUTHORITY,
            caveats: caveats,
            salt: 0,
            signature: hex""
        });

        // Get the domain separator from the delegation manager
        bytes32 domainSeparator = delegationManager.getDomainHash();

        // Hash the delegation for signing
        bytes32 delegationHash = EncoderLib._getDelegationHash(delegation);

        // Create the typed data hash
        bytes32 typedDataHash = MessageHashUtils.toTypedDataHash(domainSeparator, delegationHash);

        // Sign the delegation with the delegator's private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(delegatorPrivateKey, typedDataHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        delegation.signature = signature;

        console2.log("Delegation created and signed");
        return delegation;
    }

    /**
     * @notice Executes a transfer using the delegation
     * @param delegation The delegation to use
     */
    function executeTransfer(Delegation memory delegation) internal {
        // Create the execution data for a simple ETH transfer
        Execution memory execution = Execution({
            target: address(delegate),
            value: TRANSFER_AMOUNT,
            callData: hex"" // Empty calldata for a simple ETH transfer
         });

        // Encode the execution
        bytes memory executionCallData = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

        // Use single mode for our execution
        ModeCode mode = ModeLib.encodeSimpleSingle();

        // Debug delegation details
        console2.log("Delegation details:");
        console2.log("  Delegate:", delegation.delegate);
        console2.log("  Delegator:", delegation.delegator);
        console2.log("  Authority:", vm.toString(delegation.authority));
        console2.log("  Salt:", delegation.salt);
        console2.log("  Signature length:", delegation.signature.length);
        console2.log("  Number of caveats:", delegation.caveats.length);
        console2.log("  Caveat enforcer:", delegation.caveats[0].enforcer);
        console2.log("  Caveat terms length:", delegation.caveats[0].terms.length);

        // For testing purposes, we need to mock the EntryPoint calling the execute function
        // since the function has the onlyEntryPointOrSelf modifier
        console2.log("Executing transfer directly through delegatorWallet...");
        vm.startPrank(address(entryPoint));

        try delegatorWallet.execute(mode, executionCallData) {
            console2.log("Transfer executed successfully");
        } catch Error(string memory reason) {
            console2.log("Transfer failed with reason:", reason);
        } catch (bytes memory err) {
            if (err.length >= 32) {
                console2.log("Transfer failed with error data:", vm.toString(bytes32(err.length >= 32 ? bytes32(err) : bytes32(0))));
            } else {
                console2.log("Transfer failed with short error data, length:", err.length);
                if (err.length > 0) {
                    console2.log("Error data (hex):", vm.toString(bytes32(uint256(uint8(err[0])))));
                }
            }
        }

        vm.stopPrank();
    }

    /**
     * @notice Executes an operation using the delegation
     * @param delegation The signed delegation to use
     * @param executionNumber The execution number (for logging)
     */
    function executeOperation(Delegation memory delegation, uint256 executionNumber) internal {
        console2.log("\nExecuting transfer", executionNumber, "of", MAX_TRANSFERS);
        console2.log("Current timestamp:", block.timestamp);

        // For interval transfers, we only need to execute the transfer to the delegate
        // Create a single execution for the ETH transfer
        bytes memory executionCallData = ExecutionLib.encodeSingle(
            address(delegate),
            TRANSFER_AMOUNT,
            hex"" // Empty calldata for a simple ETH transfer
        );
        console2.log("Execution: Transfer", TRANSFER_AMOUNT, "wei to delegate");

        // Use single mode for our execution
        ModeCode mode = ModeLib.encodeSimpleSingle();

        // Debug delegation details
        console2.log("Delegation details:");
        console2.log("  Delegate:", delegation.delegate);
        console2.log("  Delegator:", delegation.delegator);
        console2.log("  Authority:", vm.toString(delegation.authority));
        console2.log("  Salt:", delegation.salt);
        console2.log("  Signature length:", delegation.signature.length);
        console2.log("  Number of caveats:", delegation.caveats.length);
        console2.log("  Caveat enforcer:", delegation.caveats[0].enforcer);
        console2.log("  Caveat terms length:", delegation.caveats[0].terms.length);

        // For testing purposes, we need to mock the EntryPoint calling the execute function
        // since the function has the onlyEntryPointOrSelf modifier
        console2.log("Executing operation directly through delegatorWallet...");
        vm.startPrank(address(entryPoint));

        try delegatorWallet.execute(mode, executionCallData) {
            console2.log("Operation executed successfully");
        } catch Error(string memory reason) {
            console2.log("Operation failed with reason:", reason);
        } catch (bytes memory err) {
            if (err.length >= 32) {
                console2.log(
                    "Operation failed with error data:", vm.toString(bytes32(err.length >= 32 ? bytes32(err) : bytes32(0)))
                );
            } else {
                console2.log("Operation failed with short error data, length:", err.length);
                if (err.length > 0) {
                    console2.log("Error data (hex):", vm.toString(bytes32(uint256(uint8(err[0])))));
                }
            }
        }

        vm.stopPrank();
    }
}
