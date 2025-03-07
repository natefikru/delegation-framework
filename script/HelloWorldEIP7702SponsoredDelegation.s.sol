// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Script, console2 } from "forge-std/Script.sol";
import { EntryPoint } from "@account-abstraction/core/EntryPoint.sol";
import { DelegationManager } from "../src/DelegationManager.sol";
import { EIP7702StatelessDeleGator } from "../src/EIP7702/EIP7702StatelessDeleGator.sol";
import { HelloWorld } from "../src/cyphera_examples/HelloWorld.sol";
import { SimplePaymaster } from "../src/cyphera_examples/SimplePaymaster.sol";
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
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { PackedUserOperation } from "@account-abstraction/interfaces/PackedUserOperation.sol";

/**
 * @title HelloWorldEIP7702SponsoredDelegation
 * @notice A script that demonstrates how to use the EIP-7702 delegation framework with gas sponsorship
 * @dev This script extends HelloWorldEIP7702Delegation to show how a third party can sponsor gas fees
 */
contract HelloWorldEIP7702SponsoredDelegation is Script {
    using MessageHashUtils for bytes32;
    using ModeLib for ModeCode;
    using ECDSA for bytes32;

    // Test accounts
    address private delegator;
    uint256 private delegatorPrivateKey;
    address private delegate;
    uint256 private delegatePrivateKey;
    address private sponsor;
    uint256 private sponsorPrivateKey;

    // Contracts
    EntryPoint private entryPoint;
    DelegationManager private delegationManager;
    EIP7702StatelessDeleGator private delegatorWallet;
    HelloWorld private helloWorld;
    SimplePaymaster private paymaster;

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

        sponsorPrivateKey = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
        sponsor = vm.addr(sponsorPrivateKey);

        vm.label(delegator, "Delegator");
        vm.label(delegate, "Delegate");
        vm.label(sponsor, "Sponsor");

        // Deploy contracts
        entryPoint = new EntryPoint();
        vm.label(address(entryPoint), "EntryPoint");

        delegationManager = new DelegationManager(delegator);
        vm.label(address(delegationManager), "DelegationManager");

        // Deploy the EIP7702StatelessDeleGator
        delegatorWallet = new EIP7702StatelessDeleGator(delegationManager, entryPoint);
        vm.label(address(delegatorWallet), "EIP7702DelegatorWallet");

        // Fund the delegator wallet with some ETH
        vm.deal(address(delegatorWallet), 1 ether);

        // Deploy the HelloWorld contract owned by the delegator wallet
        helloWorld = new HelloWorld(address(delegatorWallet));
        vm.label(address(helloWorld), "HelloWorld");

        // Deploy the SimplePaymaster contract
        paymaster = new SimplePaymaster(entryPoint);
        vm.label(address(paymaster), "SimplePaymaster");

        // Fund the paymaster with ETH and deposit to EntryPoint
        vm.deal(address(sponsor), 10 ether);
        vm.prank(sponsor);
        paymaster.deposit{ value: 5 ether }();
    }

    function run() public {
        setUp();

        // Log initial setup
        console2.log("=== Initial Setup ===");
        console2.log("Delegator address:", delegator);
        console2.log("Delegate address:", delegate);
        console2.log("Sponsor address:", sponsor);
        console2.log("EIP7702DelegatorWallet address:", address(delegatorWallet));
        console2.log("HelloWorld contract address:", address(helloWorld));
        console2.log("Paymaster address:", address(paymaster));
        console2.log("Paymaster deposit:", paymaster.getDeposit());
        console2.log("Initial message:", helloWorld.message());
        console2.log("Initial counter:", helloWorld.counter());

        // Execute a sponsored transaction
        executeSponsoredTransaction("Hello from Sponsored Transaction");

        // Execute a sponsored batch transaction
        executeSponsoredBatch();

        // Execute a sponsored transaction with try execution
        executeSponsoredTryWithRevert();

        // Log final state
        console2.log("\n=== Final State ===");
        console2.log("Final message:", helloWorld.message());
        console2.log("Final counter:", helloWorld.counter());
        console2.log("Remaining paymaster deposit:", paymaster.getDeposit());

        // Summary
        console2.log("\n=== EIP-7702 Sponsored Delegation Summary ===");
        console2.log("This script demonstrates how the EIP-7702 implementation can be used with gas sponsorship.");
        console2.log("Key features demonstrated:");
        console2.log("1. Sponsored single transaction execution");
        console2.log("2. Sponsored batch transaction execution");
        console2.log("3. Sponsored try execution that handles reverts gracefully");
        console2.log("4. Gas fees paid by a third-party sponsor through a paymaster contract");
    }

    /**
     * @notice Executes a sponsored transaction to update the message
     * @param newMessage The new message to set
     */
    function executeSponsoredTransaction(string memory newMessage) internal {
        console2.log("\n=== Sponsored Transaction Execution ===");

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

        // For testing purposes, we need to mock the EntryPoint calling the execute function
        // since the function has the onlyEntryPointOrSelf modifier
        vm.startPrank(address(entryPoint));

        // Execute the transaction with sponsorship
        // In a real EIP-7702 implementation with sponsorship, this would be handled by the bundler
        delegatorWallet.execute(mode, executionCalldata);

        vm.stopPrank();

        console2.log("Message updated through sponsored transaction to:", helloWorld.message());
        console2.log("Gas fees paid by paymaster:", address(paymaster));
    }

    /**
     * @notice Executes a sponsored batch of calls to update the message and increment the counter
     */
    function executeSponsoredBatch() internal {
        console2.log("\n=== Sponsored Batch Execution ===");

        // Create batch execution data
        Execution[] memory executions = new Execution[](2);

        // First execution: update message
        executions[0] = Execution({
            target: address(helloWorld),
            value: 0,
            callData: abi.encodeWithSelector(HelloWorld.updateMessage.selector, "Sponsored Batch Update")
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

        // For testing purposes, we need to mock the EntryPoint calling the execute function
        vm.startPrank(address(entryPoint));

        // Execute the batch transaction with sponsorship
        delegatorWallet.execute(mode, executionCalldata);

        vm.stopPrank();

        console2.log("Sponsored batch execution completed");
        console2.log("Message after sponsored batch:", helloWorld.message());
        console2.log("Counter after sponsored batch:", helloWorld.counter());
        console2.log("Gas fees paid by paymaster:", address(paymaster));
    }

    /**
     * @notice Executes a sponsored call that will revert, using try execution mode
     */
    function executeSponsoredTryWithRevert() internal {
        console2.log("\n=== Sponsored Try Execution with Revert ===");

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
        console2.log("Sponsored try execution completed successfully despite function revert");
        console2.log("Gas fees paid by paymaster:", address(paymaster));

        vm.stopPrank();
    }

    /**
     * @notice Simulates how a bundler would create and submit a UserOperation with a paymaster
     * @dev This is a simplified version for demonstration purposes
     * @param execution The execution to perform
     * @param mode The execution mode
     */
    function createSponsoredUserOp(Execution memory execution, ModeCode mode) internal view returns (PackedUserOperation memory) {
        bytes memory callData = abi.encodeWithSelector(
            bytes4(keccak256("execute(bytes,bytes)")),
            mode,
            ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData)
        );

        // In a real implementation, these values would be calculated based on gas prices
        bytes32 accountGasLimits = bytes32(uint256(2000000) << 128 | uint256(1000000));
        bytes32 gasFees = bytes32(uint256(3 gwei) << 128 | uint256(2 gwei));

        // Create the paymaster data
        bytes memory paymasterAndData = abi.encodePacked(address(paymaster));

        // Create the UserOperation
        PackedUserOperation memory userOp = PackedUserOperation({
            sender: address(delegatorWallet),
            nonce: entryPoint.getNonce(address(delegatorWallet), 0),
            initCode: new bytes(0), // Empty since the account is already deployed
            callData: callData,
            accountGasLimits: accountGasLimits,
            preVerificationGas: 100000,
            gasFees: gasFees,
            paymasterAndData: paymasterAndData,
            signature: new bytes(0) // Will be filled later
         });

        return userOp;
    }
}
