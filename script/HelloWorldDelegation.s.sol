// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Script, console2 } from "forge-std/Script.sol";
import { EntryPoint } from "@account-abstraction/core/EntryPoint.sol";
import { DelegationManager } from "../src/DelegationManager.sol";
import { ERC7715DeleGator } from "../src/ERC7715/ERC7715DeleGator.sol";
import { HelloWorld } from "../src/cyphera_examples/HelloWorld.sol";
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

/**
 * @title HelloWorldDelegation
 * @notice A script that demonstrates how to use the delegation framework with a HelloWorld contract
 * @dev This script sets up two wallets (delegator and delegate) and shows how the delegate can
 *      execute functions on the HelloWorld contract on behalf of the delegator
 */
contract HelloWorldDelegation is Script {
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
    ERC7715DeleGator private delegatorWallet;
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

        delegatorWallet = new ERC7715DeleGator(address(delegationManager), address(entryPoint));
        vm.label(address(delegatorWallet), "DelegatorWallet");

        // Fund the delegator wallet with some ETH
        vm.deal(address(delegatorWallet), 1 ether);

        // Deploy the HelloWorld contract owned by the delegator wallet
        helloWorld = new HelloWorld(address(delegatorWallet));
        vm.label(address(helloWorld), "HelloWorld");
    }

    function run() public {
        setUp();

        // Display initial state
        console2.log("=== Initial Setup ===");
        console2.log("Delegator address:", delegator);
        console2.log("Delegate address:", delegate);
        console2.log("DelegatorWallet address:", address(delegatorWallet));
        console2.log("HelloWorld contract address:", address(helloWorld));
        console2.log("Initial message:", helloWorld.message());
        console2.log("Initial counter:", helloWorld.counter());

        // Demonstrate direct execution by the delegator
        console2.log("\n=== Direct Execution by Delegator ===");
        executeDirectly("Hello from Delegator");

        // Demonstrate delegated execution
        console2.log("\n=== Delegated Execution ===");
        executeThroughDelegation();

        // Demonstrate batch execution
        console2.log("\n=== Batch Execution ===");
        executeBatch();

        // Demonstrate try execution with a function that will revert
        console2.log("\n=== Try Execution with Revert ===");
        executeTryWithRevert();

        // Final state
        console2.log("\n=== Final State ===");
        console2.log("Final message:", helloWorld.message());
        console2.log("Final counter:", helloWorld.counter());
    }

    /**
     * @notice Executes a direct call to update the message
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

        // Get the current nonce
        uint256 nonce = delegatorWallet.getNonce();

        // Create the hash to sign
        bytes32 structHash =
            keccak256(abi.encode(EXECUTE_TYPEHASH, keccak256(abi.encode(mode)), keccak256(executionCalldata), nonce));

        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_SEPARATOR_TYPEHASH,
                keccak256(bytes(delegatorWallet.NAME())),
                keccak256(bytes(delegatorWallet.VERSION())),
                block.chainid,
                address(delegatorWallet)
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        // Sign the message with the delegator's private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(delegatorPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Execute the transaction
        delegatorWallet.executeFromOwner(mode, executionCalldata, signature);

        console2.log("Message updated directly by delegator to:", helloWorld.message());
    }

    /**
     * @notice Executes a call through delegation to update the message
     */
    function executeThroughDelegation() internal {
        console2.log("\n=== Delegated Execution ===");

        // Deploy the TimestampEnforcer
        TimestampEnforcer timestampEnforcer = new TimestampEnforcer();

        // Set time parameters - valid for 24 hours from now
        uint128 startTime = uint128(block.timestamp);
        uint128 endTime = uint128(block.timestamp + 24 hours);

        console2.log("Delegation valid from:", startTime);
        console2.log("Delegation valid until:", endTime);

        // Create the terms as a 32-byte value (16 bytes for start time + 16 bytes for end time)
        bytes memory timestampTerms = abi.encodePacked(bytes16(bytes32(uint256(startTime))), bytes16(bytes32(uint256(endTime))));

        // Create a delegation with a timestamp caveat
        Caveat[] memory caveats = new Caveat[](1);
        caveats[0] = Caveat({ enforcer: address(timestampEnforcer), terms: timestampTerms, args: hex"" });

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

        // Create the execution data to update the message
        Execution memory execution = Execution({
            target: address(helloWorld),
            value: 0,
            callData: abi.encodeWithSelector(HelloWorld.updateMessage.selector, "Hello from Delegate")
        });

        // Encode the execution
        bytes memory executionCallData = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

        // Create arrays for the delegation manager
        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = delegation;

        bytes[] memory permissionContexts = new bytes[](1);
        permissionContexts[0] = abi.encode(delegations);

        ModeCode[] memory modes = new ModeCode[](1);
        modes[0] = ModeLib.encodeSimpleSingle();

        bytes[] memory executionCallDatas = new bytes[](1);
        executionCallDatas[0] = executionCallData;

        // Execute the call through the delegation manager
        vm.startPrank(address(delegate));
        delegationManager.redeemDelegations(permissionContexts, modes, executionCallDatas);
        vm.stopPrank();

        // Log the updated message
        string memory newMessage = helloWorld.message();
        console2.log("Message updated through delegation to:", newMessage);
    }

    /**
     * @notice Executes a batch of calls to update the message and increment the counter
     */
    function executeBatch() internal {
        // Create batch execution data
        Execution[] memory executions = new Execution[](2);

        // First execution: update message
        executions[0] = Execution({
            target: address(helloWorld),
            value: 0,
            callData: abi.encodeWithSelector(HelloWorld.updateMessage.selector, "Batch Update")
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

        // Get the current nonce
        uint256 nonce = delegatorWallet.getNonce();

        // Create the hash to sign
        bytes32 structHash =
            keccak256(abi.encode(EXECUTE_TYPEHASH, keccak256(abi.encode(mode)), keccak256(executionCalldata), nonce));

        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_SEPARATOR_TYPEHASH,
                keccak256(bytes(delegatorWallet.NAME())),
                keccak256(bytes(delegatorWallet.VERSION())),
                block.chainid,
                address(delegatorWallet)
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        // Sign the message with the delegator's private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(delegatorPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Execute the batch transaction
        delegatorWallet.executeFromOwner(mode, executionCalldata, signature);

        console2.log("Batch execution completed");
        console2.log("Message after batch:", helloWorld.message());
        console2.log("Counter after batch:", helloWorld.counter());
    }

    /**
     * @notice Executes a call that will revert, using try execution mode
     */
    function executeTryWithRevert() internal {
        // Create execution data for a function that will revert
        Execution memory execution =
            Execution({ target: address(helloWorld), value: 0, callData: abi.encodeWithSelector(HelloWorld.willRevert.selector) });

        // Encode the execution
        bytes memory executionCalldata = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

        // Create mode for try execution (using CALLTYPE_SINGLE and EXECTYPE_TRY)
        ModeCode mode = ModeLib.encode(CALLTYPE_SINGLE, EXECTYPE_TRY, MODE_DEFAULT, ModePayload.wrap(bytes22(0)));

        // Get the current nonce
        uint256 nonce = delegatorWallet.getNonce();

        // Create the hash to sign
        bytes32 structHash =
            keccak256(abi.encode(EXECUTE_TYPEHASH, keccak256(abi.encode(mode)), keccak256(executionCalldata), nonce));

        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_SEPARATOR_TYPEHASH,
                keccak256(bytes(delegatorWallet.NAME())),
                keccak256(bytes(delegatorWallet.VERSION())),
                block.chainid,
                address(delegatorWallet)
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        // Sign the message with the delegator's private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(delegatorPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Execute the transaction with try execution
        (bool success, bytes memory result) = delegatorWallet.executeFromOwner(mode, executionCalldata, signature);

        console2.log("Try execution completed");
        console2.log("Execution success:", success);
        console2.log("Has error data:", result.length > 0);
    }
}
