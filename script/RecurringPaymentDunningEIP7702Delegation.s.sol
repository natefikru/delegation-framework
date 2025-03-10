// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Script, console2 } from "forge-std/Script.sol";
import { EntryPoint } from "@account-abstraction/core/EntryPoint.sol";
import { DelegationManager } from "../src/DelegationManager.sol";
import { SimpleFactory } from "../src/utils/SimpleFactory.sol";
import { EIP7702StatelessDeleGator } from "../src/EIP7702/EIP7702StatelessDeleGator.sol";
import { Execution, Delegation, Caveat, ModeCode } from "../src/utils/Types.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { EncoderLib } from "../src/libraries/EncoderLib.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { RecurringPaymentDunningEnforcer } from "../src/cyphera_enforcers/RecurringPaymentDunningEnforcer.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";
import { IEntryPoint } from "@account-abstraction/interfaces/IEntryPoint.sol";

/**
 * @title RecurringPaymentEIP7702Delegation
 * @notice Script to demonstrate the integration of RecurringPaymentEnforcer with EIP-7702 delegation framework
 */
contract RecurringPaymentEIP7702Delegation is Script {
    // Test accounts
    address public delegator;
    address public delegate;
    uint256 public delegatorPrivateKey;
    uint256 public delegatePrivateKey;

    // Contracts
    EntryPoint public entryPoint;
    DelegationManager public delegationManager;
    SimpleFactory public factory;
    EIP7702StatelessDeleGator public implementation;
    EIP7702StatelessDeleGator public delegatorWallet;
    EIP7702StatelessDeleGator public delegateWallet;
    RecurringPaymentDunningEnforcer public recurringPaymentDunningEnforcer;

    // Payment parameters
    address public recipient;
    uint256 public constant PAYMENT_AMOUNT = 0.01 ether;
    uint256 public constant PAYMENT_INTERVAL = 1 days;
    uint256 public constant MAX_PAYMENTS = 3;
    uint256 public constant MAX_DUNNING_ATTEMPTS = 2;

    /**
     * @notice Set up test accounts and deploy contracts
     */
    function setUp() public {
        // Set up test accounts
        delegatorPrivateKey = 0xA11CE;
        delegatePrivateKey = 0xB0B;
        delegator = vm.addr(delegatorPrivateKey);
        delegate = vm.addr(delegatePrivateKey);

        // Set up payment recipient
        recipient = address(0x123456);

        // Deploy contracts
        vm.startBroadcast();

        // Deploy EntryPoint
        entryPoint = new EntryPoint();

        // Deploy DelegationManager
        delegationManager = new DelegationManager(delegator); // Pass owner address

        // Deploy SimpleFactory
        factory = new SimpleFactory();

        // Deploy RecurringPaymentDunningEnforcer
        recurringPaymentDunningEnforcer = new RecurringPaymentDunningEnforcer();

        // Deploy implementation
        implementation = new EIP7702StatelessDeleGator(
            IDelegationManager(address(delegationManager)), IEntryPoint(address(entryPoint))
        );

        // Create wallet proxies using deploy method
        bytes memory initCode = abi.encodePacked(
            type(EIP7702StatelessDeleGator).creationCode,
            abi.encode(IDelegationManager(address(delegationManager)), IEntryPoint(address(entryPoint)))
        );

        // Deploy delegator wallet proxy
        bytes32 salt = keccak256(abi.encodePacked("delegator", delegator));
        address delegatorWalletAddress = factory.deploy(initCode, salt);
        delegatorWallet = EIP7702StatelessDeleGator(payable(delegatorWalletAddress));

        // Deploy delegate wallet proxy
        salt = keccak256(abi.encodePacked("delegate", delegate));
        address delegateWalletAddress = factory.deploy(initCode, salt);
        delegateWallet = EIP7702StatelessDeleGator(payable(delegateWalletAddress));

        // Fund the delegator wallet
        (bool success,) = address(delegatorWallet).call{ value: 1 ether }("");
        require(success, "Failed to fund delegator wallet");

        vm.stopBroadcast();
    }

    /**
     * @notice Run the script
     */
    function run() public {
        // Set up accounts and deploy contracts
        setUp();

        // Create and sign delegation
        console2.log("=== Creating and Signing Delegation ===");
        Delegation memory delegation = createAndSignDelegation();
        bytes32 delegationHash = EncoderLib._getDelegationHash(delegation);

        // Display initial balances
        console2.log("\n=== Initial Balances ===");
        console2.log("Delegator balance:", address(delegatorWallet).balance);
        console2.log("Delegate balance:", address(delegateWallet).balance);
        console2.log("Recipient balance:", address(recipient).balance);

        // Execute payments
        console2.log("\n=== Executing Payments ===");
        for (uint256 i = 0; i < MAX_PAYMENTS; i++) {
            // Execute the payment
            executePayment(delegation, delegationHash, i + 1);

            // Display balances after payment
            console2.log("\nBalances after payment #", i + 1);
            console2.log("Delegator balance:", address(delegatorWallet).balance);
            console2.log("Delegate balance:", address(delegateWallet).balance);
            console2.log("Recipient balance:", address(recipient).balance);

            // Wait for the next interval
            vm.warp(block.timestamp + PAYMENT_INTERVAL);
        }

        // Simulate payment failure and dunning
        console2.log("\n=== Simulating Payment Failure and Dunning ===");
        simulatePaymentFailureAndDunning(delegation, delegationHash);

        // Final state
        console2.log("\n=== Final State ===");
        console2.log("Delegator balance:", address(delegatorWallet).balance);
        console2.log("Delegate balance:", address(delegateWallet).balance);
        console2.log("Recipient balance:", address(recipient).balance);
    }

    /**
     * @notice Create and sign a delegation for recurring payments
     * @return delegation The created and signed delegation
     */
    function createAndSignDelegation() internal returns (Delegation memory) {
        // Encode the terms for the RecurringPaymentEnforcer
        bytes memory terms = abi.encodePacked(
            bytes32(PAYMENT_INTERVAL), // Interval between payments
            bytes32(MAX_PAYMENTS), // Maximum number of payments
            bytes32(PAYMENT_AMOUNT), // Payment amount
            bytes32(MAX_DUNNING_ATTEMPTS) // Maximum dunning attempts
        );

        // Create the caveat
        Caveat[] memory caveats = new Caveat[](1);
        caveats[0] = Caveat({ enforcer: address(recurringPaymentDunningEnforcer), terms: terms, args: hex"" });

        // Create the delegation
        Delegation memory delegation = Delegation({
            delegator: address(delegatorWallet),
            delegate: address(delegateWallet),
            authority: bytes32(0),
            caveats: caveats,
            salt: 0,
            signature: hex""
        });

        // Hash the delegation for signing
        bytes32 delegationHash = EncoderLib._getDelegationHash(delegation);
        bytes32 messageHash = MessageHashUtils.toEthSignedMessageHash(delegationHash);

        // Sign the delegation
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(delegatorPrivateKey, messageHash);
        delegation.signature = abi.encodePacked(r, s, v);

        // Log delegation details
        console2.log("Created delegation:");
        console2.log("  Delegator:", delegation.delegator);
        console2.log("  Delegate:", delegation.delegate);
        console2.log("  Signature length:", delegation.signature.length);
        console2.log("  Number of caveats:", delegation.caveats.length);
        console2.log("  Caveat enforcer:", delegation.caveats[0].enforcer);
        console2.log("  Caveat terms length:", delegation.caveats[0].terms.length);

        return delegation;
    }

    /**
     * @notice Execute a payment using the delegation
     * @param delegation The delegation to use
     * @param delegationHash The hash of the delegation
     * @param paymentNumber The payment number (for logging)
     */
    function executePayment(Delegation memory delegation, bytes32 delegationHash, uint256 paymentNumber) internal {
        console2.log("\nExecuting payment #", paymentNumber);

        // Create the execution for a simple ETH transfer
        Execution memory execution = Execution({ target: recipient, value: PAYMENT_AMOUNT, callData: hex"" });

        // Encode the execution
        bytes memory executionCallData =
            ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

        // Prepare arrays for redeemDelegations
        bytes[] memory permissionContexts = new bytes[](1);
        permissionContexts[0] = abi.encode(delegation);

        ModeCode[] memory modes = new ModeCode[](1);
        modes[0] = ModeLib.encodeSimpleSingle();

        bytes[] memory executionCallDatas = new bytes[](1);
        executionCallDatas[0] = executionCallData;

        // Log the delegation details
        console2.log("Delegation details:");
        console2.log("  Delegate:", delegation.delegate);
        console2.log("  Delegator:", delegation.delegator);
        console2.log("  Signature length:", delegation.signature.length);

        // Execute the payment through the delegation manager
        vm.startPrank(delegate);
        try delegationManager.redeemDelegations(permissionContexts, modes, executionCallDatas) {
            console2.log("Payment executed successfully");
        } catch Error(string memory reason) {
            console2.log("Payment execution failed:", reason);
        } catch (bytes memory) {
            console2.log("Payment execution failed with no reason");
        }
        vm.stopPrank();
    }

    /**
     * @notice Simulate payment failures and dunning
     * @param delegation The delegation to use
     * @param delegationHash The hash of the delegation
     */
    function simulatePaymentFailureAndDunning(Delegation memory delegation, bytes32 delegationHash) internal {
        console2.log("\nSimulating payment failures and dunning");

        // Create the execution for a simple ETH transfer
        Execution memory execution = Execution({ target: recipient, value: PAYMENT_AMOUNT, callData: hex"" });

        // Encode the execution
        bytes memory executionCallData =
            ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

        // Simulate multiple payment failures
        for (uint256 i = 0; i < MAX_DUNNING_ATTEMPTS; i++) {
            console2.log("\nSimulating payment failure #", i + 1);

            bool nullified = recurringPaymentDunningEnforcer.recordPaymentFailure(
                delegation.caveats[0].terms,
                delegationHash,
                delegation.delegator,
                delegation.delegate,
                executionCallData
            );

            if (nullified) {
                console2.log("Subscription has been nullified due to too many failures");
                break;
            } else {
                console2.log("Payment failed, dunning attempt recorded");
            }
        }

        // Try one more failure to nullify the subscription
        // Instead of trying to access the struct directly, we'll use a boolean variable
        // to track if we should attempt to nullify the subscription
        bool shouldAttemptNullify = true;

        // We can check if the subscription is already nullified by trying to call beforeHook
        // If it reverts with "subscription-nullified", then we know it's already nullified
        try recurringPaymentDunningEnforcer.beforeHook(
            delegation.caveats[0].terms,
            hex"",
            ModeLib.encodeSimpleSingle(),
            executionCallData,
            delegationHash,
            delegation.delegator,
            delegation.delegate
        ) {
            // If it doesn't revert, the subscription is not nullified
            shouldAttemptNullify = true;
        } catch Error(string memory reason) {
            if (
                bytes(reason).length > 0
                    && keccak256(bytes(reason)) == keccak256(bytes("RecurringPaymentEnforcer:subscription-nullified"))
            ) {
                shouldAttemptNullify = false;
                console2.log("Subscription is already nullified");
            }
        }

        if (shouldAttemptNullify) {
            console2.log("\nSimulating final payment failure");

            bool nullified = recurringPaymentDunningEnforcer.recordPaymentFailure(
                delegation.caveats[0].terms,
                delegationHash,
                delegation.delegator,
                delegation.delegate,
                executionCallData
            );

            console2.log("Subscription nullified:", nullified);
        }
    }
}
