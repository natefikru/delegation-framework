// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { DelegationManager } from "../src/DelegationManager.sol";
import { RecurringPaymentDunningEnforcer } from "../src/cyphera_enforcers/RecurringPaymentDunningEnforcer.sol";
import { Execution, Delegation, Caveat, ModeCode } from "../src/utils/Types.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { EncoderLib } from "../src/libraries/EncoderLib.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title RecurringPaymentDelegation
 * @notice This script demonstrates the RecurringPaymentEnforcer with dunning functionality
 */
contract RecurringPaymentDelegation is Script {
    using MessageHashUtils for bytes32;
    using ModeLib for ModeCode;

    // Constants for payment terms
    uint256 constant PAYMENT_INTERVAL = 30 days;
    uint256 constant MAX_PAYMENTS = 12;
    uint256 constant PAYMENT_AMOUNT = 0.01 ether;
    uint256 constant MAX_DUNNING_ATTEMPTS = 3;

    // For demonstration purposes, we'll use a shorter interval
    uint256 constant DEMO_INTERVAL = 30 seconds;

    // Keys and addresses
    uint256 delegatorKey;
    uint256 delegateKey;
    address delegator;
    address delegate;

    // Contracts
    DelegationManager delegationManager;
    RecurringPaymentDunningEnforcer recurringPaymentDunningEnforcer;

    // Constants for delegation
    bytes32 private constant ROOT_AUTHORITY = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

    function setUp() public {
        // Generate keys
        delegatorKey = 0x1;
        delegateKey = 0x2;
        delegator = vm.addr(delegatorKey);
        delegate = vm.addr(delegateKey);

        // Fund accounts
        vm.deal(delegator, 10 ether);
        vm.deal(delegate, 1 ether);

        // Deploy contracts
        vm.startBroadcast();
        delegationManager = new DelegationManager(address(this));
        recurringPaymentDunningEnforcer = new RecurringPaymentDunningEnforcer();
        vm.stopBroadcast();

        console2.log("Contracts deployed:");
        console2.log("DelegationManager:", address(delegationManager));
        console2.log("RecurringPaymentEnforcer:", address(recurringPaymentDunningEnforcer));
        console2.log("Accounts:");
        console2.log("Delegator:", delegator);
        console2.log("Delegate:", delegate);
    }

    function run() public {
        setUp();

        // Demonstrate the RecurringPaymentEnforcer functionality
        demonstrateRecurringPayment();
    }

    /**
     * @notice Demonstrates the RecurringPaymentEnforcer functionality
     */
    function demonstrateRecurringPayment() internal {
        console2.log("\n=== RecurringPaymentEnforcer Demonstration ===");

        // Create payment terms
        bytes memory terms = abi.encode(DEMO_INTERVAL, MAX_PAYMENTS, PAYMENT_AMOUNT, MAX_DUNNING_ATTEMPTS);

        // Create a mock execution for a payment
        Execution memory execution = Execution({ target: delegate, value: PAYMENT_AMOUNT, callData: hex"" });

        // Encode the execution
        bytes memory executionCallData = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

        // Create a mock delegation hash
        bytes32 delegationHash = keccak256(abi.encodePacked("mock-delegation", delegator, delegate));

        // Log initial state
        console2.log("Initial state:");
        console2.log("Delegator balance:", delegator.balance);
        console2.log("Delegate balance:", delegate.balance);

        // Demonstrate beforeHook
        console2.log("\n1. Testing beforeHook (validates payment conditions)");
        vm.startBroadcast();

        // Use single mode for our execution
        ModeCode mode = ModeLib.encodeSimpleSingle();

        try recurringPaymentDunningEnforcer.beforeHook(
            terms,
            hex"", // args
            mode,
            executionCallData,
            delegationHash,
            delegator,
            delegate
        ) {
            console2.log("[OK] Payment conditions validated successfully");

            // Check payment state
            RecurringPaymentDunningEnforcer.PaymentState memory state = getPaymentState(delegationHash);
            console2.log("Payment state after beforeHook:");
            console2.log("  Last attempt time:", state.lastAttemptTime);
            console2.log("  Successful payments:", state.successfulPayments);
            console2.log("  Current dunning attempts:", state.currentDunningAttempts);
            console2.log("  Is nullified:", state.isNullified ? "Yes" : "No");

            // Demonstrate afterHook (records successful payment)
            console2.log("\n2. Testing afterHook (records successful payment)");

            recurringPaymentDunningEnforcer.afterHook(
                terms,
                hex"", // args
                mode,
                executionCallData,
                delegationHash,
                delegator,
                delegate
            );

            console2.log("[OK] Payment recorded successfully");

            // Check updated payment state
            state = getPaymentState(delegationHash);
            console2.log("Payment state after afterHook:");
            console2.log("  Last attempt time:", state.lastAttemptTime);
            console2.log("  Successful payments:", state.successfulPayments);
            console2.log("  Current dunning attempts:", state.currentDunningAttempts);
            console2.log("  Is nullified:", state.isNullified ? "Yes" : "No");

            // Demonstrate dunning functionality
            console2.log("\n3. Testing dunning functionality");

            bool nullified =
                recurringPaymentDunningEnforcer.recordPaymentFailure(terms, delegationHash, delegator, delegate, executionCallData);

            console2.log("Payment failure recorded. Subscription nullified:", nullified ? "Yes" : "No");

            // Check updated payment state after dunning
            state = getPaymentState(delegationHash);
            console2.log("Payment state after dunning attempt:");
            console2.log("  Last attempt time:", state.lastAttemptTime);
            console2.log("  Successful payments:", state.successfulPayments);
            console2.log("  Current dunning attempts:", state.currentDunningAttempts);
            console2.log("  Is nullified:", state.isNullified ? "Yes" : "No");

            // Demonstrate multiple dunning attempts
            console2.log("\n4. Testing multiple dunning attempts");

            for (uint256 i = 1; i < MAX_DUNNING_ATTEMPTS; i++) {
                nullified = recurringPaymentDunningEnforcer.recordPaymentFailure(
                    terms, delegationHash, delegator, delegate, executionCallData
                );

                console2.log("Dunning attempt", i + 1, "recorded. Subscription nullified:", nullified ? "Yes" : "No");

                // Check updated payment state
                state = getPaymentState(delegationHash);
                console2.log("Payment state after dunning attempt", i + 1, ":");
                console2.log("  Current dunning attempts:", state.currentDunningAttempts);
                console2.log("  Is nullified:", state.isNullified ? "Yes" : "No");

                if (nullified) break;
            }

            // Demonstrate behavior after max dunning attempts
            if (state.isNullified) {
                console2.log("\n5. Testing behavior after subscription is nullified");

                try recurringPaymentDunningEnforcer.beforeHook(
                    terms,
                    hex"", // args
                    mode,
                    executionCallData,
                    delegationHash,
                    delegator,
                    delegate
                ) {
                    console2.log("[UNEXPECTED] Payment conditions validated despite nullified subscription");
                } catch Error(string memory reason) {
                    console2.log("[EXPECTED] Payment rejected:", reason);
                } catch (bytes memory errorData) {
                    console2.log("[EXPECTED] Payment rejected with raw error:", bytesToHex(errorData));
                }
            }
        } catch Error(string memory reason) {
            console2.log("[FAIL] Payment conditions validation failed:", reason);
        } catch (bytes memory errorData) {
            console2.log("[FAIL] Payment conditions validation failed with raw error:", bytesToHex(errorData));
        }

        vm.stopBroadcast();
    }

    /**
     * @notice Helper function to get the payment state for a delegation
     * @param delegationHash The hash of the delegation
     * @return The payment state
     */
    function getPaymentState(bytes32 delegationHash) internal view returns (RecurringPaymentDunningEnforcer.PaymentState memory) {
        (uint256 lastAttemptTime, uint256 successfulPayments, uint256 currentDunningAttempts, bool isNullified) =
            recurringPaymentDunningEnforcer.paymentStates(delegationHash);

        return RecurringPaymentDunningEnforcer.PaymentState({
            lastAttemptTime: lastAttemptTime,
            successfulPayments: successfulPayments,
            currentDunningAttempts: currentDunningAttempts,
            isNullified: isNullified
        });
    }

    /**
     * @notice Helper function to convert bytes to hex string for logging
     */
    function bytesToHex(bytes memory data) internal pure returns (string memory) {
        bytes memory hexChars = "0123456789abcdef";
        bytes memory hexString = new bytes(2 + data.length * 2);
        hexString[0] = "0";
        hexString[1] = "x";

        for (uint256 i = 0; i < data.length; i++) {
            hexString[2 + i * 2] = hexChars[uint8(data[i] >> 4)];
            hexString[2 + i * 2 + 1] = hexChars[uint8(data[i] & 0x0f)];
        }

        return string(hexString);
    }
}
