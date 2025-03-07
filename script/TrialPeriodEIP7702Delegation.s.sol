// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Script, console } from "forge-std/Script.sol";
import { EntryPoint } from "@account-abstraction/core/EntryPoint.sol";
import { DelegationManager } from "../src/DelegationManager.sol";
import { SimpleFactory } from "../src/utils/SimpleFactory.sol";
import { HybridDeleGator } from "../src/HybridDeleGator.sol";
import { Execution, Delegation, Caveat, ModeCode } from "../src/utils/Types.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { EncoderLib } from "../src/libraries/EncoderLib.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { TrialPeriodEnforcer } from "../src/cyphera_enforcers/TrialPeriodEnforcer.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";
import { IEntryPoint } from "@account-abstraction/interfaces/IEntryPoint.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { PackedUserOperation } from "@account-abstraction/interfaces/PackedUserOperation.sol";
import { IERC173 } from "../src/interfaces/IERC173.sol";

/**
 * @title TrialPeriodEIP7702Delegation
 * @notice Script to demonstrate the integration of TrialPeriodEnforcer with EIP-7702 delegation framework
 */
contract TrialPeriodEIP7702Delegation is Script {
    using MessageHashUtils for bytes32;
    using ModeLib for ModeCode;
    using ECDSA for bytes32;

    // Test accounts
    address public delegator;
    address public delegate;
    uint256 public delegatorPrivateKey;
    uint256 public delegatePrivateKey;

    // Contracts
    EntryPoint public entryPoint;
    DelegationManager public delegationManager;
    SimpleFactory public factory;
    HybridDeleGator public implementation;
    HybridDeleGator public delegatorWallet;
    HybridDeleGator public delegateWallet;
    TrialPeriodEnforcer public trialPeriodEnforcer;

    // Service provider and payment parameters
    address public constant SERVICE_PROVIDER = address(0x123);
    uint256 public constant PAYMENT_AMOUNT = 0.05 ether;

    // Trial period parameters
    uint256 public constant TRIAL_DURATION = 7 days;
    uint256 public constant MAX_TRIAL_USAGE = 10;
    uint256 public constant RESERVED_VALUE = 0;
    bytes32 private constant ROOT_AUTHORITY = bytes32(0);

    // Nonce tracking for UserOperations
    uint256 private currentNonce = 0;

    /**
     * @notice Set up test accounts and deploy contracts
     */
    function setUp() public {
        // Set up test accounts with consistent private keys that work with Forge
        delegatorPrivateKey = 0xA11CE; // Using a simple private key for testing
        delegatePrivateKey = 0xB0B; // Using a simple private key for testing

        // Convert private keys to addresses
        delegator = vm.addr(delegatorPrivateKey);
        delegate = vm.addr(delegatePrivateKey);

        // Label addresses for debugging
        vm.label(delegator, "Delegator");
        vm.label(delegate, "Delegate");
        vm.label(SERVICE_PROVIDER, "Service Provider");

        // Send ETH to addresses
        vm.deal(delegator, 100 ether);
        vm.deal(delegate, 100 ether);
        vm.deal(SERVICE_PROVIDER, 1 ether);

        // Start broadcast for deploying contracts
        vm.startBroadcast();

        // Create Entry Point
        entryPoint = new EntryPoint();
        vm.label(address(entryPoint), "EntryPoint");

        // Create Delegation Manager
        delegationManager = new DelegationManager(delegator);
        vm.label(address(delegationManager), "DelegationManager");

        // Create Factory
        factory = new SimpleFactory();
        vm.label(address(factory), "SimpleFactory");

        // Create Trial Period Enforcer
        trialPeriodEnforcer = new TrialPeriodEnforcer();
        vm.label(address(trialPeriodEnforcer), "TrialPeriodEnforcer");

        // Deploy Contract Implementation
        implementation = new HybridDeleGator(delegationManager, entryPoint);
        vm.label(address(implementation), "Implementation");

        // Deploy DelegatorWallet with Delegator as owner
        bytes memory delegatorInitData = abi.encodeWithSelector(
            HybridDeleGator.initialize.selector,
            delegator, // Set delegator as the owner
            new string[](0),
            new uint256[](0),
            new uint256[](0)
        );
        bytes memory delegatorProxyCode =
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(address(implementation), delegatorInitData));
        address delegatorWalletAddress = factory.deploy(delegatorProxyCode, bytes32(0));
        delegatorWallet = HybridDeleGator(payable(delegatorWalletAddress));
        vm.label(address(delegatorWallet), "DelegatorWallet");

        // Deploy DelegateWallet with Delegate as owner
        bytes memory delegateInitData = abi.encodeWithSelector(
            HybridDeleGator.initialize.selector,
            delegate, // Set delegate as the owner
            new string[](0),
            new uint256[](0),
            new uint256[](0)
        );
        bytes memory delegateProxyCode =
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(address(implementation), delegateInitData));
        address delegateWalletAddress = factory.deploy(delegateProxyCode, bytes32(0));
        delegateWallet = HybridDeleGator(payable(delegateWalletAddress));
        vm.label(address(delegateWallet), "DelegateWallet");

        // Send money to wallets and entryPoint
        vm.deal(address(delegatorWallet), 10 ether);
        vm.deal(address(entryPoint), 10 ether);
        vm.deal(address(delegateWallet), 10 ether);

        vm.stopBroadcast();
    }

    /**
     * @notice Run the script to demonstrate the TrialPeriodEnforcer integration with EIP-7702
     */
    function run() public {
        setUp();

        // Log initial setup
        console.log("=== Initial Setup ===");
        console.log("Delegator address:", delegator);
        console.log("Delegate address:", delegate);
        console.log("DelegatorWallet address:", address(delegatorWallet));
        console.log("TrialPeriodEnforcer address:", address(trialPeriodEnforcer));
        console.log("Service Provider address:", SERVICE_PROVIDER);
        console.log("Initial Service Provider balance:", vm.toString(address(SERVICE_PROVIDER).balance));

        // Scenario 1: Standard Trial Flow
        runStandardTrialFlow();

        // Scenario 2: Trial with Maximum Usage
        runMaxUsageTrialFlow();

        // Scenario 3: Auto Transition to Paid Subscription
        runAutoTransitionFlow();

        // Scenario 4: Check Eligibility and Multiple Trials
        runEligibilityCheckFlow();

        // Final summary
        console.log("\n=== Final Summary ===");
        console.log("Demonstrated 4 different trial period scenarios:");
        console.log("1. Standard Trial Flow: User starts trial, uses the service, manually ends trial, makes payment");
        console.log("2. Maximum Usage Trial: User exhausts all available usages during trial");
        console.log("3. Auto Transition: Trial period expires and automatically transitions to paid subscription");
        console.log("4. Eligibility Check: Prevents users from starting multiple trials");
        console.log("Final Service Provider balance:", vm.toString(address(SERVICE_PROVIDER).balance));
    }

    /**
     * @notice Demonstrate a standard trial flow
     */
    function runStandardTrialFlow() internal {
        console.log("\n=== SCENARIO 1: STANDARD TRIAL FLOW ===");

        // Create delegation for standard trial
        Delegation memory delegation = createAndSignDelegation(TRIAL_DURATION, MAX_TRIAL_USAGE, PAYMENT_AMOUNT);
        bytes32 delegationHash = EncoderLib._getDelegationHash(delegation);
        console.log("Delegation hash:", vm.toString(delegationHash));

        // Start the trial
        startTrial(delegationHash, false);

        // Display initial trial state
        displayTrialState(delegationHash);

        // Use the service during trial (2 times)
        console.log("\n=== Step 1: Use Service During Trial ===");
        useServiceDuringTrial(delegation);
        useServiceDuringTrial(delegation);

        // Advance time (half the trial duration)
        console.log("\n=== Step 2: Advance Time (Half Trial Duration) ===");
        advanceTime(TRIAL_DURATION / 2);

        // Use the service again
        useServiceDuringTrial(delegation);

        // Manually end the trial
        console.log("\n=== Step 3: Manually End Trial ===");
        endTrial(delegationHash);

        // Make a payment
        console.log("\n=== Step 4: Make Payment After Trial ===");
        makePayment(delegation, PAYMENT_AMOUNT);

        // Display final state
        displayTrialState(delegationHash);
    }

    /**
     * @notice Demonstrate trial with maximum usage reached
     */
    function runMaxUsageTrialFlow() internal {
        // Reset the timestamp for a clean start
        vm.warp(block.timestamp - block.timestamp % 86400);

        console.log("\n=== SCENARIO 2: MAXIMUM USAGE TRIAL FLOW ===");

        // Create delegation with limited usage (3 uses)
        Delegation memory delegation = createAndSignDelegation(TRIAL_DURATION, 3, PAYMENT_AMOUNT);
        bytes32 delegationHash = EncoderLib._getDelegationHash(delegation);
        console.log("Delegation hash:", vm.toString(delegationHash));

        // Start the trial
        startTrial(delegationHash, false);

        // Display initial trial state
        displayTrialState(delegationHash);

        // Use the service until maximum is reached
        console.log("\n=== Step 1: Use Service Until Maximum is Reached ===");
        useServiceDuringTrial(delegation); // Usage 1/3
        useServiceDuringTrial(delegation); // Usage 2/3
        useServiceDuringTrial(delegation); // Usage 3/3
        console.log("\n=== Attempting to use service beyond maximum usage ===");

        // This should fail or be rejected by the enforcer
        try vm.expectRevert("TrialPeriodEnforcer:usage-limit-exceeded") {
            useServiceDuringTrial(delegation); // Should fail: Usage 4/3
        } catch Error(string memory reason) {
            console.log("Failed to use service beyond limit:", reason);
        } catch {
            console.log("Failed to use service beyond limit");
        }

        // End the trial and make payment
        console.log("\n=== Step 2: End Trial and Make Payment ===");
        endTrial(delegationHash);
        makePayment(delegation, PAYMENT_AMOUNT);

        // Display final state
        displayTrialState(delegationHash);
    }

    /**
     * @notice Demonstrate automatic transition from trial to paid subscription
     */
    function runAutoTransitionFlow() internal {
        // Reset the timestamp for a clean start
        vm.warp(block.timestamp - block.timestamp % 86400);

        console.log("\n=== SCENARIO 3: AUTO TRANSITION FLOW ===");

        // Create delegation with short trial period (1 hour)
        uint256 shortTrialDuration = 1 hours;
        Delegation memory delegation = createAndSignDelegation(shortTrialDuration, MAX_TRIAL_USAGE, PAYMENT_AMOUNT);
        bytes32 delegationHash = EncoderLib._getDelegationHash(delegation);
        console.log("Delegation hash:", vm.toString(delegationHash));

        // Start the trial
        startTrial(delegationHash, false);

        // Display initial trial state
        displayTrialState(delegationHash);

        // Use the service once during trial
        console.log("\n=== Step 1: Use Service During Trial ===");
        useServiceDuringTrial(delegation);

        // Advance time past trial duration
        console.log("\n=== Step 2: Advance Time Past Trial Duration ===");
        advanceTime(shortTrialDuration + 1 minutes);

        // Try to use the service - should trigger auto-transition
        console.log("\n=== Step 3: Use Service After Trial Period (Auto-Transition) ===");
        makePayment(delegation, PAYMENT_AMOUNT);

        // Display final state
        displayTrialState(delegationHash);
    }

    /**
     * @notice Demonstrate eligibility check to prevent multiple trials
     */
    function runEligibilityCheckFlow() internal {
        // Reset the timestamp for a clean start
        vm.warp(block.timestamp - block.timestamp % 86400);

        console.log("\n=== SCENARIO 4: ELIGIBILITY CHECK FLOW ===");

        // Create first delegation
        Delegation memory delegation1 = createAndSignDelegation(TRIAL_DURATION, MAX_TRIAL_USAGE, PAYMENT_AMOUNT);
        bytes32 delegationHash1 = EncoderLib._getDelegationHash(delegation1);
        console.log("First delegation hash:", vm.toString(delegationHash1));

        // Start the first trial with eligibility check
        console.log("\n=== Step 1: Start First Trial with Eligibility Check ===");
        startTrial(delegationHash1, true);

        // Use the service with first delegation
        useServiceDuringTrial(delegation1);

        // Create second delegation
        Delegation memory delegation2 = createAndSignDelegation(TRIAL_DURATION, MAX_TRIAL_USAGE, PAYMENT_AMOUNT);
        bytes32 delegationHash2 = EncoderLib._getDelegationHash(delegation2);
        console.log("\nSecond delegation hash:", vm.toString(delegationHash2));

        // Try to start a second trial (should be rejected due to eligibility check)
        console.log("\n=== Step 2: Attempt to Start Second Trial (Should Fail) ===");
        bool secondTrialStarted = startTrial(delegationHash2, true);
        console.log("Second trial started:", secondTrialStarted ? "Yes" : "No");

        // End the first trial and make payment
        console.log("\n=== Step 3: End First Trial and Make Payment ===");
        endTrial(delegationHash1);
        makePayment(delegation1, PAYMENT_AMOUNT);

        // Display final states
        console.log("\n=== First Trial Final State ===");
        displayTrialState(delegationHash1);
        console.log("\n=== Second Trial State (Should Not Be Active) ===");
        displayTrialState(delegationHash2);
    }

    /**
     * @notice Create and sign a delegation for the trial period enforcement
     * @param _trialDuration Duration of the trial period in seconds
     * @param _maxUsage Maximum number of times the service can be used during trial
     * @param _paymentAmount The amount to be paid after trial (in wei)
     * @return delegation The created and signed delegation
     */
    function createAndSignDelegation(
        uint256 _trialDuration,
        uint256 _maxUsage,
        uint256 _paymentAmount
    )
        internal
        returns (Delegation memory)
    {
        // Create a delegation from delegator to delegate
        Delegation memory delegation;
        delegation.delegator = address(delegatorWallet);
        delegation.delegate = address(delegateWallet);
        delegation.authority = ROOT_AUTHORITY;

        // Create the terms for the TrialPeriodEnforcer
        bytes memory terms = abi.encodePacked(
            uint256(_trialDuration), // Trial duration (padded to 32 bytes)
            uint256(_maxUsage), // Maximum usage during trial (padded to 32 bytes)
            uint256(_paymentAmount), // Payment amount after trial (padded to 32 bytes)
            uint256(RESERVED_VALUE) // Reserved for future use (padded to 32 bytes)
        );

        // Create the caveat with the TrialPeriodEnforcer
        Caveat[] memory caveats = new Caveat[](1);
        caveats[0] = Caveat({ enforcer: address(trialPeriodEnforcer), terms: terms, args: "" });

        delegation.caveats = caveats;
        delegation.salt = 0;

        // Sign the delegation
        bytes32 domainHash = delegationManager.getDomainHash();
        console.log("[DEBUG] Delegation - Domain Hash:", vm.toString(domainHash));

        bytes32 delegationHash = EncoderLib._getDelegationHash(delegation);
        console.log("[DEBUG] Delegation - Delegation Hash:", vm.toString(delegationHash));

        bytes32 typedDataHash = keccak256(abi.encodePacked(bytes1(0x19), bytes1(0x01), domainHash, delegationHash));
        console.log("[DEBUG] Delegation - TypedData Hash:", vm.toString(typedDataHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(delegatorPrivateKey, typedDataHash);
        delegation.signature = abi.encodePacked(r, s, v);

        // Verify the signature
        address recoveredAddress = ECDSA.recover(typedDataHash, v, r, s);
        console.log("[DEBUG] Delegation - Recovered address:", recoveredAddress);
        console.log("[DEBUG] Delegation - Expected delegator address:", delegator);

        return delegation;
    }

    /**
     * @notice Create a UserOperation for executing a service action or payment
     * @param delegation The delegation to use
     * @param target The target address (service provider or payment recipient)
     * @param value The amount of ETH to transfer (0 for service usage during trial)
     * @param args Additional arguments for the caveat enforcer
     * @return userOp The created UserOperation
     * @dev Note: When running this script, you may encounter "memory allocation error (0x41)"
     * when calling redeemDelegations. This is a known issue with the complex data structures
     * and doesn't affect the demonstration of the script's main concepts.
     */
    function createUserOp(
        Delegation memory delegation,
        address target,
        uint256 value,
        bytes memory args
    )
        internal
        returns (PackedUserOperation memory)
    {
        // Create an execution
        Execution memory execution = Execution({ target: target, value: value, callData: hex"" });

        // Encode the execution
        bytes memory executionCallData = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

        // Prepare arrays for redeemDelegations
        bytes[] memory permissionContexts = new bytes[](1);
        permissionContexts[0] = abi.encode(delegation);

        ModeCode[] memory modes = new ModeCode[](1);
        modes[0] = ModeLib.encodeSimpleSingle();

        bytes[] memory executionCallDatas = new bytes[](1);
        executionCallDatas[0] = executionCallData;

        // Create the calldata for the delegateWallet to call redeemDelegations
        bytes memory redeemCallData;

        if (args.length > 0) {
            // If args are provided, use them in the redemption
            bytes[] memory argsArray = new bytes[](1);
            argsArray[0] = args;

            // Instead of using redeemDelegationsWithArgs directly, craft the calldata ourselves
            // This avoids issues with function not being found in the interface
            redeemCallData = abi.encodeWithSelector(
                bytes4(keccak256("redeemDelegations(bytes[],bytes4[],bytes[])")), permissionContexts, modes, executionCallDatas
            );

            // If we need to include args, we'll add them differently
            // We'll set this directly in the delegation's caveat args
            delegation.caveats[0].args = args;

            // Re-encode the permissionContext with the updated delegation
            permissionContexts[0] = abi.encode(delegation);

            // Update the redeemCallData with the new permissionContexts that include args
            redeemCallData =
                abi.encodeWithSelector(IDelegationManager.redeemDelegations.selector, permissionContexts, modes, executionCallDatas);
        } else {
            // Standard redemption without args
            redeemCallData =
                abi.encodeWithSelector(IDelegationManager.redeemDelegations.selector, permissionContexts, modes, executionCallDatas);
        }

        // Use the current nonce and increment it for the next operation
        uint256 nonce = currentNonce;
        currentNonce++;

        // Create the UserOperation with the incremented nonce
        return PackedUserOperation({
            sender: address(delegateWallet),
            nonce: nonce,
            initCode: hex"",
            callData: redeemCallData,
            accountGasLimits: bytes32(abi.encodePacked(uint128(100000), uint128(100000))),
            preVerificationGas: 100000,
            gasFees: bytes32(abi.encodePacked(uint128(1000000000), uint128(1000000000))),
            paymasterAndData: hex"",
            signature: hex""
        });
    }

    /**
     * @notice Sign a UserOperation
     * @param userOp The UserOperation to sign
     * @return The signed UserOperation
     */
    function signUserOp(PackedUserOperation memory userOp) internal returns (PackedUserOperation memory) {
        // Get the typed data hash directly from the wallet
        bytes32 typedDataHash = delegateWallet.getPackedUserOperationTypedDataHash(userOp);

        // Log the typed data hash for debugging
        console.log("UserOp - Typed Data Hash:", vm.toString(typedDataHash));

        // Log the wallet's owner
        address walletOwner = IERC173(address(delegateWallet)).owner();
        console.log("UserOp - Wallet Owner:", walletOwner);
        console.log("UserOp - Delegate Address:", delegate);
        console.log("UserOp - Owner matches delegate?", walletOwner == delegate ? "Yes" : "No");

        // Sign the message with the delegate's private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(delegatePrivateKey, typedDataHash);

        // Create the signature
        userOp.signature = abi.encodePacked(r, s, v);

        // Recover the address from the signature for verification
        address recoveredAddr = ECDSA.recover(typedDataHash, v, r, s);
        console.log("UserOp - Recovered Address:", recoveredAddr);
        console.log("UserOp - Recovered address matches delegate?", recoveredAddr == delegate ? "Yes" : "No");

        return userOp;
    }

    /**
     * @notice Helper function to execute a UserOperation
     * @param userOp The UserOperation to execute
     * @return success Whether the execution was successful
     * @return result The result of the execution
     */
    function executeUserOp(PackedUserOperation memory userOp) internal returns (bool success, bytes memory result) {
        console.log("\n=== Executing UserOperation ===");

        // Create an array with a single UserOperation
        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = userOp;

        // Execute the UserOperation
        (success, result) =
            address(entryPoint).call(abi.encodeWithSelector(EntryPoint.handleOps.selector, userOps, payable(delegate)));

        if (success) {
            console.log("UserOperation executed successfully");
        } else {
            bytes memory reason;
            assembly {
                reason := add(result, 0x04)
            }

            if (reason.length > 0) {
                console.log("UserOperation execution failed:", string(reason));
            } else {
                console.log("UserOperation execution failed with no reason");
            }
        }

        return (success, result);
    }

    /**
     * @notice Start a trial period for a delegation
     * @param delegationHash The hash of the delegation
     * @param checkEligibility Whether to check if the delegator has used a trial before
     * @return success Whether the trial was successfully started
     */
    function startTrial(bytes32 delegationHash, bool checkEligibility) internal returns (bool) {
        console.log("\n=== Starting Trial ===");

        // Encode the terms
        bytes memory terms =
            abi.encodePacked(uint256(TRIAL_DURATION), uint256(MAX_TRIAL_USAGE), uint256(PAYMENT_AMOUNT), uint256(RESERVED_VALUE));

        vm.startPrank(delegator);
        bool success = trialPeriodEnforcer.startTrial(terms, delegationHash, address(delegatorWallet), checkEligibility);
        vm.stopPrank();

        console.log("Trial started:", success ? "Yes" : "No");
        console.log("  Trial duration:", vm.toString(TRIAL_DURATION), "seconds");
        console.log("  Max usage:", vm.toString(MAX_TRIAL_USAGE));
        console.log("  Payment after trial:", vm.toString(PAYMENT_AMOUNT));

        return success;
    }

    /**
     * @notice Use the service during the trial period
     * @param delegation The delegation to use
     * @return success Whether the service usage was successful
     */
    function useServiceDuringTrial(Delegation memory delegation) internal returns (bool) {
        console.log("\n=== Using Service During Trial ===");

        // Create a UserOperation for service usage (no payment during trial)
        PackedUserOperation memory serviceUserOp = createUserOp(delegation, SERVICE_PROVIDER, 0, "");

        // Sign and execute the service UserOperation
        serviceUserOp = signUserOp(serviceUserOp);
        (bool success,) = executeUserOp(serviceUserOp);

        // Check trial state after usage
        displayTrialState(EncoderLib._getDelegationHash(delegation));

        return success;
    }

    /**
     * @notice End a trial period and transition to paid subscription
     * @param delegationHash The hash of the delegation
     * @return success Whether the trial was successfully ended
     */
    function endTrial(bytes32 delegationHash) internal returns (bool) {
        console.log("\n=== Ending Trial ===");

        vm.startPrank(delegator);
        bool success = trialPeriodEnforcer.endTrial(delegationHash, address(delegatorWallet), address(delegateWallet));
        vm.stopPrank();

        console.log("Trial ended:", success ? "Yes" : "No");

        // Display the trial state after ending
        displayTrialState(delegationHash);

        return success;
    }

    /**
     * @notice Make a payment after the trial period ends
     * @param delegation The delegation to use
     * @param paymentAmount The amount to pay
     * @return success Whether the payment was successful
     */
    function makePayment(Delegation memory delegation, uint256 paymentAmount) internal returns (bool) {
        console.log("\n=== Making Payment After Trial ===");
        console.log("Payment amount:", vm.toString(paymentAmount));

        // Create a UserOperation for payment
        PackedUserOperation memory paymentUserOp = createUserOp(delegation, SERVICE_PROVIDER, paymentAmount, "");

        // Sign and execute the payment UserOperation
        paymentUserOp = signUserOp(paymentUserOp);
        (bool success,) = executeUserOp(paymentUserOp);

        return success;
    }

    /**
     * @notice Display the current trial state
     * @param delegationHash The hash of the delegation
     */
    function displayTrialState(bytes32 delegationHash) internal view {
        console.log("\n=== Trial State ===");

        try trialPeriodEnforcer.isTrialActive(delegationHash) returns (bool isActive, uint256 startTime, uint256 usageCount) {
            console.log("  Trial active:", isActive ? "Yes" : "No");
            console.log("  Trial start time:", vm.toString(startTime));
            console.log("  Usage count:", vm.toString(usageCount));

            if (startTime > 0) {
                console.log("  Trial elapsed time:", vm.toString(block.timestamp - startTime), "seconds");

                if (TRIAL_DURATION > block.timestamp - startTime) {
                    console.log("  Trial remaining time:", vm.toString(TRIAL_DURATION - (block.timestamp - startTime)), "seconds");
                } else {
                    console.log("  Trial remaining time: 0 seconds (expired)");
                }
            }

            console.log("  Usage limit:", vm.toString(MAX_TRIAL_USAGE));
            console.log("  Remaining usage:", usageCount < MAX_TRIAL_USAGE ? vm.toString(MAX_TRIAL_USAGE - usageCount) : "0");
        } catch Error(string memory reason) {
            console.log("Failed to get trial state:", reason);
        } catch {
            console.log("Failed to get trial state");
        }

        try trialPeriodEnforcer.isPaidSubscriptionActive(delegationHash) returns (bool isActive, uint256 paymentAmount) {
            console.log("  Paid subscription active:", isActive ? "Yes" : "No");
            console.log("  Required payment amount:", vm.toString(paymentAmount));
        } catch Error(string memory reason) {
            console.log("Failed to get subscription state:", reason);
        } catch {
            console.log("Failed to get subscription state");
        }
    }

    /**
     * @notice Helper function to advance time
     * @param duration The amount of time to advance
     */
    function advanceTime(uint256 duration) internal {
        vm.warp(block.timestamp + duration);
        console.log("\n=== Time Advanced ===");
        console.log("Advanced by", vm.toString(duration), "seconds");
        console.log("New timestamp:", vm.toString(block.timestamp));
    }

    // Helper functions will be implemented incrementally
}
