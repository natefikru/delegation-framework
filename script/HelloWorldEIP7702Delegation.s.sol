// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Script, console2 } from "forge-std/Script.sol";
import { EntryPoint } from "@account-abstraction/core/EntryPoint.sol";
import { DelegationManager } from "../src/DelegationManager.sol";
import { EIP7702StatelessDeleGator } from "../src/EIP7702/EIP7702StatelessDeleGator.sol";
import { HelloWorld } from "../src/examples/HelloWorld.sol";
import { Execution, Delegation, Caveat, ModeCode } from "../src/utils/Types.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import {
    ModeLib,
    CallType,
    ExecType,
    ModeSelector,
    ModePayload,
    CALLTYPE_SINGLE,
    CALLTYPE_BATCH,
    EXECTYPE_DEFAULT,
    EXECTYPE_TRY,
    MODE_DEFAULT
} from "@erc7579/lib/ModeLib.sol";
import { EncoderLib } from "../src/libraries/EncoderLib.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { TimestampEnforcer } from "../src/enforcers/TimestampEnforcer.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title HelloWorldEIP7702Delegation
 * @notice A script that demonstrates how to use the EIP-7702 delegation framework with a HelloWorld contract
 * @dev This script sets up two wallets (delegator and delegate) and shows how the delegate can
 *      execute functions on the HelloWorld contract on behalf of the delegator using EIP-7702
 */
contract HelloWorldEIP7702Delegation is Script {
    using MessageHashUtils for bytes32;
    using ModeLib for ModeCode;
    using ECDSA for bytes32;

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

    // Constants for delegation
    bytes32 private constant DOMAIN_SEPARATOR_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant EXECUTE_TYPEHASH = keccak256("Execute(bytes mode,bytes executionCalldata,uint256 nonce)");
    bytes32 private constant ROOT_AUTHORITY = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

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

        // Deploy the EIP7702StatelessDeleGator
        // Note: In a real EIP-7702 implementation, this would be the same address as the delegator
        // But for this emulation, we need to deploy a contract
        delegatorWallet = new EIP7702StatelessDeleGator(delegationManager, entryPoint);
        vm.label(address(delegatorWallet), "EIP7702DelegatorWallet");

        // Fund the delegator wallet with some ETH
        vm.deal(address(delegatorWallet), 1 ether);

        // Deploy the HelloWorld contract owned by the delegator wallet
        helloWorld = new HelloWorld(address(delegatorWallet));
        vm.label(address(helloWorld), "HelloWorld");
    }

    function run() public {
        setUp();

        // Log initial setup
        console2.log("=== Initial Setup ===");
        console2.log("Delegator address:", delegator);
        console2.log("Delegate address:", delegate);
        console2.log("EIP7702DelegatorWallet address:", address(delegatorWallet));
        console2.log("HelloWorld contract address:", address(helloWorld));
        console2.log("Initial message:", helloWorld.message());
        console2.log("Initial counter:", helloWorld.counter());

        // Execute functions directly
        executeDirectly("Hello from EIP-7702 Delegator");

        // Execute batch functions
        executeBatch();

        // Execute function that will revert with try execution
        executeTryWithRevert();

        // Log final state
        console2.log("\n=== Final State ===");
        console2.log("Final message:", helloWorld.message());
        console2.log("Final counter:", helloWorld.counter());

        // Summary
        console2.log("\n=== EIP-7702 Emulation Summary ===");
        console2.log("This script demonstrates how the EIP-7702 implementation can be used with the HelloWorld contract.");
        console2.log("In a real EIP-7702 implementation, the EOA would directly execute code without deploying a contract.");
        console2.log("This emulation uses a deployed contract (EIP7702StatelessDeleGator) to simulate the behavior.");
        console2.log("The key features demonstrated are:");
        console2.log("1. Direct execution of single transactions");
        console2.log("2. Batch execution of multiple transactions in a single call");
        console2.log("3. Try execution mode that handles reverts gracefully");
    }

    /**
     * @notice Executes a direct call to update the message using EIP-7702 style
     * @param newMessage The new message to set
     */
    function executeDirectly(string memory newMessage) internal {
        // Create execution data to update the message
        Execution memory execution = Execution({
            target: address(helloWorld),
            value: 0,
            callData: abi.encodeWithSelector(HelloWorld.updateMessage.selector, newMessage)
        });

        // Encode the execution
        bytes memory executionCalldata = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

        // Create mode (simple single execution)
        ModeCode mode = ModeLib.encodeSimpleSingle();

        // In EIP-7702, we would directly execute this from the EOA
        // But for this emulation, we need to use the delegatorWallet

        // For testing purposes, we need to mock the EntryPoint calling the execute function
        // since the function has the onlyEntryPointOrSelf modifier
        vm.startPrank(address(entryPoint));

        // Execute the transaction
        // In a real EIP-7702 implementation, this would be a direct call from the EOA
        // But for this emulation, we use the execute method through the EntryPoint
        delegatorWallet.execute(mode, executionCalldata);

        vm.stopPrank();

        console2.log("Message updated directly by EIP-7702 delegator to:", helloWorld.message());
    }

    /**
     * @notice Executes a batch of calls to update the message and increment the counter using EIP-7702 style
     */
    function executeBatch() internal {
        // Create batch execution data
        Execution[] memory executions = new Execution[](2);

        // First execution: update message
        executions[0] = Execution({
            target: address(helloWorld),
            value: 0,
            callData: abi.encodeWithSelector(HelloWorld.updateMessage.selector, "EIP-7702 Batch Update")
        });

        // Second execution: increment counter
        executions[1] = Execution({
            target: address(helloWorld),
            value: 0,
            callData: abi.encodeWithSelector(HelloWorld.incrementCounter.selector)
        });

        // Encode the batch execution
        bytes memory executionCalldata = ExecutionLib.encodeBatch(executions);

        // Create mode (batch execution)
        ModeCode mode = ModeLib.encodeSimpleBatch();

        // In EIP-7702, we would directly execute this from the EOA
        // But for this emulation, we need to use the delegatorWallet

        // For testing purposes, we need to mock the EntryPoint calling the execute function
        // since the function has the onlyEntryPointOrSelf modifier
        vm.startPrank(address(entryPoint));

        // Execute the batch transaction
        // In a real EIP-7702 implementation, this would be a direct call from the EOA
        // But for this emulation, we use the execute method through the EntryPoint
        delegatorWallet.execute(mode, executionCalldata);

        vm.stopPrank();

        console2.log("EIP-7702 Batch execution completed");
        console2.log("Message after batch:", helloWorld.message());
        console2.log("Counter after batch:", helloWorld.counter());
    }

    /**
     * @dev Execute a function that will revert using try execution mode
     */
    function executeTryWithRevert() internal {
        console2.log("\n=== Try Execution with Revert (EIP-7702 Style) ===");

        // Create an execution that will revert
        Execution memory execution =
            Execution({ target: address(helloWorld), value: 0, callData: abi.encodeWithSelector(HelloWorld.willRevert.selector) });

        bytes memory encodedExecution = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

        // Create a mode code for try execution
        ModeCode mode = ModeLib.encode(CALLTYPE_SINGLE, EXECTYPE_TRY, MODE_DEFAULT, ModePayload.wrap(bytes22(0)));

        vm.startPrank(address(entryPoint));

        // In EIP-7702, the try execution mode allows the transaction to continue
        // even if the function call reverts
        delegatorWallet.execute(mode, encodedExecution);

        // The function reverted, but the transaction succeeded because of try execution mode
        console2.log("Try execution completed successfully despite function revert");

        vm.stopPrank();

        console2.log("EIP-7702 Try execution completed");
    }
}
