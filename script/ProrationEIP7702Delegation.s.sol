// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Script, console } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { EntryPoint } from "@account-abstraction/core/EntryPoint.sol";
import { DelegationManager } from "../src/DelegationManager.sol";
import { SimpleFactory } from "../src/utils/SimpleFactory.sol";
import { HybridDeleGator } from "../src/HybridDeleGator.sol";
import { Execution, Delegation, Caveat, ModeCode } from "../src/utils/Types.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { EncoderLib } from "../src/libraries/EncoderLib.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ProrationEnforcer } from "../src/cyphera_enforcers/ProrationEnforcer.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";
import { IEntryPoint } from "@account-abstraction/interfaces/IEntryPoint.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { PackedUserOperation } from "@account-abstraction/interfaces/PackedUserOperation.sol";
import { IERC173 } from "../src/interfaces/IERC173.sol";

/**
 * @title ProrationEIP7702Delegation
 * @notice Script to demonstrate the integration of ProrationEnforcer with EIP-7702 delegation framework
 */
contract ProrationEIP7702Delegation is Script {
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
    ProrationEnforcer public prorationEnforcer;

    // Payment recipient
    address public constant PAYMENT_RECIPIENT = address(0x123);

    // Subscription parameters
    uint256 public constant CYCLE_LENGTH = 30 days;
    uint256 public constant FULL_CYCLE_AMOUNT = 0.1 ether;
    uint256 public constant ALIGNMENT_DAY = 0; // No alignment
    uint256 public constant RESERVED = 0;
    bytes32 private constant ROOT_AUTHORITY = bytes32(0);

    // Nonce tracking for UserOperations
    uint256 private currentNonce = 0;

    // Constants
    string constant EXECUTE_SIGNATURE = "execute(bytes,bytes)";

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
        vm.label(PAYMENT_RECIPIENT, "Payment Recipient");

        // Send ETH to addresses
        vm.deal(delegator, 100 ether);
        vm.deal(delegate, 100 ether);
        vm.deal(PAYMENT_RECIPIENT, 1 ether);

        // Start Broadcast
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

        // Create Proration Enforcer
        prorationEnforcer = new ProrationEnforcer();
        vm.label(address(prorationEnforcer), "ProrationEnforcer");

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
     * @notice Run the script
     */
    function run() public {
        setUp();

        // Log initial setup
        console.log("=== Initial Setup ===");
        console.log("Delegator address:", delegator);
        console.log("Delegate address:", delegate);
        console.log("DelegatorWallet address:", address(delegatorWallet));
        console.log("ProrationEnforcer address:", address(prorationEnforcer));
        console.log("Payment Recipient address:", PAYMENT_RECIPIENT);
        console.log("Initial Payment Recipient balance:", vm.toString(address(PAYMENT_RECIPIENT).balance));

        // Create a delegation
        console.log("\n=== Creating Delegation ===");
        Delegation memory delegation = createAndSignDelegation();
        bytes32 delegationHash = EncoderLib._getDelegationHash(delegation);
        console.log("Delegation hash:", vm.toString(delegationHash));

        // Step 1: Initialize subscription
        console.log("\n=== Step 1: Initialize Subscription ===");
        bool initSuccess = initializeSubscription(delegationHash);
        console.log("Subscription initialization:", initSuccess ? "Successful" : "Failed");

        // Display initial subscription state
        console.log("\n=== Initial Subscription State ===");
        displaySubscriptionState(delegationHash);

        // Step 2: Make a full payment at the start of the cycle
        console.log("\n=== Step 2: Make Full Payment (Start of Cycle) ===");
        executePayment(delegation, FULL_CYCLE_AMOUNT);

        // Display subscription state after payment
        console.log("\n=== Subscription State After Full Payment ===");
        displaySubscriptionState(delegationHash);

        // Step 3: Advance time to mid-cycle (15 days)
        console.log("\n=== Step 3: Advance Time to Mid-Cycle (15 days) ===");
        vm.warp(block.timestamp + 15 days);
        console.log("Time advanced by 15 days");

        // Display subscription state mid-cycle
        console.log("\n=== Subscription State Mid-Cycle ===");
        displaySubscriptionState(delegationHash);

        // Step 4: Change subscription amount mid-cycle (upgrade)
        console.log("\n=== Step 4: Upgrade Subscription Mid-Cycle ===");
        uint256 newFullCycleAmount = FULL_CYCLE_AMOUNT * 2; // Double the price
        uint256 refundAmount = changeSubscription(delegationHash, newFullCycleAmount);
        console.log("Upgrade refund amount:", vm.toString(refundAmount)); // Should be 0 for upgrades

        // Display subscription state after upgrade
        console.log("\n=== Subscription State After Upgrade ===");
        displaySubscriptionState(delegationHash);

        // Step 5: Calculate prorated amount for next payment
        (uint256 proratedAmount, uint256 usageFraction) = calculateProratedAmount(delegationHash);

        // Step 6: Make prorated payment
        executePayment(delegation, proratedAmount);

        // Display subscription state after prorated payment
        console.log("\n=== Subscription State After Prorated Payment ===");
        displaySubscriptionState(delegationHash);

        // Step 7: Advance time to end of cycle
        console.log("\n=== Step 7: Advance Time to End of Cycle ===");
        vm.warp(block.timestamp + 15 days);
        console.log("Time advanced to end of cycle");

        // Display subscription state at end of cycle
        console.log("\n=== Subscription State at End of Cycle ===");
        displaySubscriptionState(delegationHash);

        // Step 8: Start a new cycle
        console.log("\n=== Step 8: Start a New Cycle ===");
        (uint256 newProratedAmount,) = calculateProratedAmount(delegationHash);
        console.log("New cycle payment amount:", vm.toString(newProratedAmount));
        executePayment(delegation, newProratedAmount);

        // Display subscription state for new cycle
        console.log("\n=== Subscription State for New Cycle ===");
        displaySubscriptionState(delegationHash);

        // Step 9: Deactivate subscription
        console.log("\n=== Step 9: Deactivate Subscription ===");
        uint256 deactivationRefund = deactivateSubscription(delegationHash);
        console.log("Deactivation refund amount:", vm.toString(deactivationRefund));

        // Display final subscription state
        console.log("\n=== Final Subscription State ===");
        displaySubscriptionState(delegationHash);

        // Display final payment recipient balance
        console.log("\n=== Final Payment Summary ===");
        console.log("Final Payment Recipient balance:", vm.toString(address(PAYMENT_RECIPIENT).balance));
        console.log("Total payments made:", vm.toString(address(PAYMENT_RECIPIENT).balance - 1 ether));
    }

    /**
     * @notice Create and sign a delegation for proration billing cycles
     * @return delegation The created and signed delegation
     */
    function createAndSignDelegation() internal returns (Delegation memory) {
        // Create a delegation from delegator to delegate
        Delegation memory delegation;
        delegation.delegator = address(delegatorWallet);
        delegation.delegate = address(delegateWallet);
        delegation.authority = ROOT_AUTHORITY;

        // Create the terms for the ProrationEnforcer
        // The terms should be 128 bytes (4 uint256 values)
        bytes memory terms = abi.encodePacked(
            uint256(CYCLE_LENGTH), // Cycle length (30 days)
            uint256(FULL_CYCLE_AMOUNT), // Full cycle payment amount (0.1 ether)
            uint256(ALIGNMENT_DAY), // Alignment day (0 = no alignment)
            uint256(RESERVED) // Reserved for future use
        );

        // Create the caveat with the ProrationEnforcer
        Caveat[] memory caveats = new Caveat[](1);
        caveats[0] = Caveat({ enforcer: address(prorationEnforcer), terms: terms, args: "" });

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
     * @notice Create a UserOperation for executing a payment
     * @param delegation The delegation to use
     * @param paymentAmount The amount to pay
     * @return userOp The created UserOperation
     */
    function createUserOp(Delegation memory delegation, uint256 paymentAmount) internal returns (PackedUserOperation memory) {
        // Create an execution for a simple ETH transfer
        Execution memory execution = Execution({ target: PAYMENT_RECIPIENT, value: paymentAmount, callData: hex"" });

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
        bytes memory redeemCallData =
            abi.encodeWithSelector(IDelegationManager.redeemDelegations.selector, permissionContexts, modes, executionCallDatas);

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
        console.log("Typed Data Hash:", vm.toString(typedDataHash));

        // Log the wallet's owner
        address walletOwner = IERC173(address(delegateWallet)).owner();
        console.log("Wallet Owner:", walletOwner);
        console.log("Delegate Address:", delegate);
        console.log("Owner matches delegate?", walletOwner == delegate ? "Yes" : "No");

        console2.log("Wallet Owner:", walletOwner);
        console2.log("Delegate Address:", delegate);
        console2.log("Owner matches delegate?", walletOwner == delegate ? "Yes" : "No");

        // Sign the message with the delegate's private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(delegatePrivateKey, typedDataHash);

        // Create the signature
        userOp.signature = abi.encodePacked(r, s, v);

        // Recover the address from the signature for verification
        address recoveredAddr = ECDSA.recover(typedDataHash, v, r, s);
        console2.log("Recovered Address:", recoveredAddr);
        console2.log("Recovered address matches delegate?", recoveredAddr == delegate ? "Yes" : "No");

        return userOp;
    }

    /**
     * @notice Initialize a subscription with billing cycle information
     * @param delegationHash The hash of the delegation
     * @return success Whether the initialization was successful
     */
    function initializeSubscription(bytes32 delegationHash) internal returns (bool) {
        vm.startPrank(delegator);
        bool success = prorationEnforcer.initializeSubscription(
            createAndSignDelegation().caveats[0].terms, delegationHash, address(delegatorWallet)
        );
        vm.stopPrank();

        return success;
    }

    /**
     * @notice Change a subscription's terms mid-cycle
     * @param delegationHash The hash of the delegation
     * @param newFullCycleAmount The new full cycle amount
     * @return refundAmount Any refund amount due (for downgrades)
     */
    function changeSubscription(bytes32 delegationHash, uint256 newFullCycleAmount) internal returns (uint256) {
        vm.startPrank(delegator);
        uint256 refundAmount = prorationEnforcer.changeSubscription(
            createAndSignDelegation().caveats[0].terms, delegationHash, address(delegatorWallet), newFullCycleAmount
        );
        vm.stopPrank();

        return refundAmount;
    }

    /**
     * @notice Calculate the prorated payment amount for the current state of the subscription
     * @param delegationHash The hash of the delegation
     * @return proratedAmount The calculated prorated amount
     * @return usageFraction The fraction of the billing cycle used (in basis points, 10000 = 100%)
     */
    function calculateProratedAmount(bytes32 delegationHash) internal returns (uint256, uint256) {
        vm.startPrank(delegator);
        (uint256 proratedAmount, uint256 usageFraction) =
            prorationEnforcer.calculateProratedAmount(delegationHash, address(delegatorWallet));
        vm.stopPrank();

        return (proratedAmount, usageFraction);
    }

    /**
     * @notice Display the current subscription state
     * @param delegationHash The hash of the delegation
     */
    function displaySubscriptionState(bytes32 delegationHash) internal {
        console.log("\n=== Subscription State ===");

        try prorationEnforcer.getSubscriptionState(delegationHash) returns (
            bool isActive, uint256 cycleStartTime, uint256 cycleEndTime, uint256 fullCycleAmount, uint256 paidAmount
        ) {
            console.log("  Is Active:", isActive ? "Yes" : "No");
            console.log("  Cycle Start Time:", vm.toString(cycleStartTime));
            console.log("  Cycle End Time:", vm.toString(cycleEndTime));
            console.log("  Full Cycle Amount:", vm.toString(fullCycleAmount));
            console.log("  Paid Amount:", vm.toString(paidAmount));

            // Calculate remaining amount
            uint256 remainingAmount = 0;
            if (fullCycleAmount > paidAmount) {
                remainingAmount = fullCycleAmount - paidAmount;
            }
            console.log("  Remaining Amount:", vm.toString(remainingAmount));

            // Calculate cycle progress
            uint256 totalCycleTime = cycleEndTime - cycleStartTime;
            if (totalCycleTime > 0) {
                uint256 timeElapsed = block.timestamp > cycleStartTime
                    ? (block.timestamp < cycleEndTime ? block.timestamp - cycleStartTime : totalCycleTime)
                    : 0;
                uint256 progress = (timeElapsed * 100) / totalCycleTime;
                console.log("  Cycle Progress:", vm.toString(progress), "%");
            }
        } catch Error(string memory reason) {
            console.log("Failed to get subscription state:", reason);
        } catch {
            console.log("Failed to get subscription state");
        }
    }

    /**
     * @notice Execute a payment with a prorated amount
     * @param delegation The delegation to use
     * @param paymentAmount The payment amount to use
     */
    function executePayment(Delegation memory delegation, uint256 paymentAmount) internal {
        console2.log("Executing payment of", vm.toString(paymentAmount), "wei");

        // Create UserOperation
        PackedUserOperation memory userOp = createUserOp(delegation, paymentAmount);

        // Sign UserOperation
        userOp = signUserOp(userOp);

        // Execute UserOperation
        (bool success, bytes memory result) = address(entryPoint).call(
            abi.encodeWithSelector(EntryPoint.handleOps.selector, userOpToArray(userOp), payable(PAYMENT_RECIPIENT))
        );

        if (success) {
            console2.log("Payment executed successfully");
        } else {
            bytes memory reason;
            assembly {
                reason := add(result, 0x04)
            }
            if (reason.length > 0) {
                console2.log("Payment execution failed:", string(reason));
            } else {
                console2.log("Payment execution failed with no reason");
                console2.logBytes(result);
            }
        }
    }

    /**
     * @notice Deactivate a subscription
     * @param delegationHash The hash of the delegation
     * @return refundAmount The calculated refund amount for unused portion
     */
    function deactivateSubscription(bytes32 delegationHash) internal returns (uint256) {
        vm.startPrank(delegator);
        uint256 refundAmount = prorationEnforcer.deactivateSubscription(delegationHash, address(delegatorWallet));
        vm.stopPrank();

        return refundAmount;
    }

    /**
     * @dev Helper function to convert a single PackedUserOperation to an array
     * @param userOp The PackedUserOperation to convert
     * @return Array containing the single userOp
     */
    function userOpToArray(PackedUserOperation memory userOp) internal pure returns (PackedUserOperation[] memory) {
        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = userOp;
        return userOps;
    }
}
