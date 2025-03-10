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
import { RefundEnforcer } from "../src/cyphera_enforcers/RefundEnforcer.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";
import { IEntryPoint } from "@account-abstraction/interfaces/IEntryPoint.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { PackedUserOperation } from "@account-abstraction/interfaces/PackedUserOperation.sol";
import { IERC173 } from "../src/interfaces/IERC173.sol";

/**
 * @title RefundEIP7702Delegation
 * @notice Script to demonstrate the integration of RefundEnforcer with EIP-7702 delegation framework
 */
contract RefundEIP7702Delegation is Script {
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
    RefundEnforcer public refundEnforcer;

    // Payment and refund parameters
    address public constant PAYMENT_RECIPIENT = address(0x123);
    uint256 public constant PAYMENT_AMOUNT = 0.1 ether;

    // Refund policy constants
    uint8 public constant POLICY_FULL_REFUND = 1;
    uint8 public constant POLICY_PRORATED_TIME = 2;
    uint8 public constant POLICY_PRORATED_USAGE = 3;
    uint8 public constant POLICY_TIERED = 4;
    uint8 public constant POLICY_NO_REFUND = 5;

    // Refund policy parameters
    uint256 public constant FULL_REFUND_PERIOD = 1 days;
    uint256 public constant PARTIAL_REFUND_PERIOD = 7 days;
    uint256 public constant MAX_REFUND_PERCENT_BPS = 5000; // 50%
    uint256 public constant MAX_REFUNDS_PER_SUBSCRIPTION = 3;
    uint256 public constant MIN_TIME_BETWEEN_REFUNDS = 1 days;

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

        // Create Refund Enforcer
        refundEnforcer = new RefundEnforcer();
        vm.label(address(refundEnforcer), "RefundEnforcer");

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
        console.log("RefundEnforcer address:", address(refundEnforcer));
        console.log("Payment Recipient address:", PAYMENT_RECIPIENT);
        console.log("Initial Payment Recipient balance:", vm.toString(address(PAYMENT_RECIPIENT).balance));

        // Scenario 1: Full Refund Policy
        runFullRefundScenario();

        // Scenario 2: Prorated Time Refund Policy
        runProratedTimeRefundScenario();

        // Scenario 3: Prorated Usage Refund Policy
        runProratedUsageRefundScenario();

        // Scenario 4: Tiered Refund Policy
        runTieredRefundScenario();

        // Scenario 5: No Refund Policy
        runNoRefundScenario();

        // Final summary
        console.log("\n=== Final Summary ===");
        console.log("Demonstrated 5 different refund policy scenarios:");
        console.log("1. POLICY_FULL_REFUND: Full refund if within period, otherwise no refund");
        console.log("2. POLICY_PRORATED_TIME: Refund based on time elapsed");
        console.log("3. POLICY_PRORATED_USAGE: Refund based on service usage");
        console.log("4. POLICY_TIERED: Refund based on tiered time periods");
        console.log("5. POLICY_NO_REFUND: No refunds allowed");
    }

    /**
     * @notice Run the full refund policy scenario
     */
    function runFullRefundScenario() internal {
        console.log("\n=== SCENARIO 1: FULL REFUND POLICY ===");

        // Create delegation with full refund policy
        Delegation memory delegation = createAndSignDelegation(POLICY_FULL_REFUND);
        bytes32 delegationHash = EncoderLib._getDelegationHash(delegation);
        console.log("Delegation hash:", vm.toString(delegationHash));

        // Make a payment
        console.log("\n=== Step 1: Make a Payment ===");

        // Create a UserOperation for payment
        PackedUserOperation memory paymentUserOp = createUserOp(delegation, PAYMENT_RECIPIENT, PAYMENT_AMOUNT, "");

        // Sign and execute the payment UserOperation
        paymentUserOp = signUserOp(paymentUserOp);
        executeUserOp(paymentUserOp);

        // Record the payment in the RefundEnforcer
        recordPayment(delegationHash, PAYMENT_AMOUNT);

        // Display the refund state after payment
        displayRefundState(delegationHash);

        // Request a refund within the full refund period
        console.log("\n=== Step 2: Request a Refund (Within Full Refund Period) ===");
        bytes32 refundRequestId = requestRefund(delegationHash, delegator, PAYMENT_AMOUNT, "Changed my mind, want a full refund");

        // Approve the refund
        console.log("\n=== Step 3: Approve the Refund ===");
        approveRefund(refundRequestId);

        // Calculate refundable amount
        console.log("\n=== Step 4: Calculate Refundable Amount ===");
        uint256 refundableAmount = calculateRefundableAmount(delegation.caveats[0].terms, delegationHash, PAYMENT_AMOUNT);

        // Execute the refund
        console.log("\n=== Step 5: Execute the Refund ===");

        // Create args with the refund request ID
        bytes memory refundArgs = abi.encodePacked(refundRequestId);

        // Create a UserOperation for refund
        PackedUserOperation memory refundUserOp = createUserOp(delegation, delegator, refundableAmount, refundArgs);

        // Sign and execute the refund UserOperation
        refundUserOp = signUserOp(refundUserOp);
        executeUserOp(refundUserOp);

        // Display the final refund state
        displayRefundState(delegationHash);

        // Deactivate the subscription
        console.log("\n=== Step 6: Deactivate Subscription ===");
        deactivateSubscription(delegationHash);

        // Display the final state after deactivation
        displayRefundState(delegationHash);
    }

    /**
     * @notice Run the prorated time refund policy scenario
     */
    function runProratedTimeRefundScenario() internal {
        console.log("\n=== SCENARIO 2: PRORATED TIME REFUND POLICY ===");

        // Create delegation with prorated time refund policy
        Delegation memory delegation = createAndSignDelegation(POLICY_PRORATED_TIME);
        bytes32 delegationHash = EncoderLib._getDelegationHash(delegation);
        console.log("Delegation hash:", vm.toString(delegationHash));

        // Make a payment
        console.log("\n=== Step 1: Make a Payment ===");

        // Create a UserOperation for payment
        PackedUserOperation memory paymentUserOp = createUserOp(delegation, PAYMENT_RECIPIENT, PAYMENT_AMOUNT, "");

        // Sign and execute the payment UserOperation
        paymentUserOp = signUserOp(paymentUserOp);
        executeUserOp(paymentUserOp);

        // Record the payment in the RefundEnforcer
        recordPayment(delegationHash, PAYMENT_AMOUNT);

        // Display the refund state after payment
        displayRefundState(delegationHash);

        // Advance time to be in the partial refund period
        console.log("\n=== Step 2: Advance Time (to Partial Refund Period) ===");
        advanceTime(FULL_REFUND_PERIOD + 2 days); // Into the partial refund period

        // Request a refund in the partial refund period
        console.log("\n=== Step 3: Request a Refund (In Partial Refund Period) ===");
        bytes32 refundRequestId =
            requestRefund(delegationHash, delegator, PAYMENT_AMOUNT, "Not satisfied with service, want partial refund");

        // Approve the refund
        console.log("\n=== Step 4: Approve the Refund ===");
        approveRefund(refundRequestId);

        // Calculate refundable amount
        console.log("\n=== Step 5: Calculate Refundable Amount ===");
        uint256 refundableAmount = calculateRefundableAmount(delegation.caveats[0].terms, delegationHash, PAYMENT_AMOUNT);

        // Execute the refund
        console.log("\n=== Step 6: Execute the Refund ===");

        // Create args with the refund request ID
        bytes memory refundArgs = abi.encodePacked(refundRequestId);

        // Create a UserOperation for refund
        PackedUserOperation memory refundUserOp = createUserOp(delegation, delegator, refundableAmount, refundArgs);

        // Sign and execute the refund UserOperation
        refundUserOp = signUserOp(refundUserOp);
        executeUserOp(refundUserOp);

        // Display the final refund state
        displayRefundState(delegationHash);

        // Deactivate the subscription
        console.log("\n=== Step 7: Deactivate Subscription ===");
        deactivateSubscription(delegationHash);

        // Display the final state after deactivation
        displayRefundState(delegationHash);
    }

    /**
     * @notice Run the prorated usage refund policy scenario
     */
    function runProratedUsageRefundScenario() internal {
        console.log("\n=== SCENARIO 3: PRORATED USAGE REFUND POLICY ===");

        // Create delegation with prorated usage refund policy
        Delegation memory delegation = createAndSignDelegation(POLICY_PRORATED_USAGE);
        bytes32 delegationHash = EncoderLib._getDelegationHash(delegation);
        console.log("Delegation hash:", vm.toString(delegationHash));

        // Make a payment
        console.log("\n=== Step 1: Make a Payment ===");

        // Create a UserOperation for payment
        PackedUserOperation memory paymentUserOp = createUserOp(delegation, PAYMENT_RECIPIENT, PAYMENT_AMOUNT, "");

        // Sign and execute the payment UserOperation
        paymentUserOp = signUserOp(paymentUserOp);
        executeUserOp(paymentUserOp);

        // Record the payment in the RefundEnforcer
        recordPayment(delegationHash, PAYMENT_AMOUNT);

        // Display the refund state after payment
        displayRefundState(delegationHash);

        // Record a few usages (less than expected)
        console.log("\n=== Step 2: Record Some Usage ===");
        recordUsage(delegationHash); // Usage 1
        recordUsage(delegationHash); // Usage 2
        recordUsage(delegationHash); // Usage 3

        // Advance time past the full refund period
        console.log("\n=== Step 3: Advance Time (Past Full Refund Period) ===");
        advanceTime(FULL_REFUND_PERIOD + 1 days);

        // Request a refund based on low usage
        console.log("\n=== Step 4: Request a Refund (Based on Low Usage) ===");
        bytes32 refundRequestId = requestRefund(delegationHash, delegator, PAYMENT_AMOUNT, "Limited usage, want partial refund");

        // Approve the refund
        console.log("\n=== Step 5: Approve the Refund ===");
        approveRefund(refundRequestId);

        // Calculate refundable amount
        console.log("\n=== Step 6: Calculate Refundable Amount ===");
        uint256 refundableAmount = calculateRefundableAmount(delegation.caveats[0].terms, delegationHash, PAYMENT_AMOUNT);

        // Execute the refund
        console.log("\n=== Step 7: Execute the Refund ===");

        // Create args with the refund request ID
        bytes memory refundArgs = abi.encodePacked(refundRequestId);

        // Create a UserOperation for refund
        PackedUserOperation memory refundUserOp = createUserOp(delegation, delegator, refundableAmount, refundArgs);

        // Sign and execute the refund UserOperation
        refundUserOp = signUserOp(refundUserOp);
        executeUserOp(refundUserOp);

        // Display the final refund state
        displayRefundState(delegationHash);

        // Deactivate the subscription
        console.log("\n=== Step 8: Deactivate Subscription ===");
        deactivateSubscription(delegationHash);

        // Display the final state after deactivation
        displayRefundState(delegationHash);
    }

    /**
     * @notice Run the tiered refund policy scenario
     */
    function runTieredRefundScenario() internal {
        console.log("\n=== SCENARIO 4: TIERED REFUND POLICY ===");

        // Create delegation with tiered refund policy
        Delegation memory delegation = createAndSignDelegation(POLICY_TIERED);
        bytes32 delegationHash = EncoderLib._getDelegationHash(delegation);
        console.log("Delegation hash:", vm.toString(delegationHash));

        // Make a payment
        console.log("\n=== Step 1: Make a Payment ===");

        // Create a UserOperation for payment
        PackedUserOperation memory paymentUserOp = createUserOp(delegation, PAYMENT_RECIPIENT, PAYMENT_AMOUNT, "");

        // Sign and execute the payment UserOperation
        paymentUserOp = signUserOp(paymentUserOp);
        executeUserOp(paymentUserOp);

        // Record the payment in the RefundEnforcer
        recordPayment(delegationHash, PAYMENT_AMOUNT);

        // Display the refund state after payment
        displayRefundState(delegationHash);

        // Advance time to be in the second tier
        console.log("\n=== Step 2: Advance Time (to Second Tier) ===");
        advanceTime(2 days); // Into the second tier (1-3 days)

        // Request a refund in the second tier
        console.log("\n=== Step 3: Request a Refund (In Second Tier) ===");
        bytes32 refundRequestId = requestRefund(delegationHash, delegator, PAYMENT_AMOUNT, "Changed mind within second tier");

        // Approve the refund
        console.log("\n=== Step 4: Approve the Refund ===");
        approveRefund(refundRequestId);

        // Calculate refundable amount
        console.log("\n=== Step 5: Calculate Refundable Amount ===");
        uint256 refundableAmount = calculateRefundableAmount(delegation.caveats[0].terms, delegationHash, PAYMENT_AMOUNT);

        // Execute the refund
        console.log("\n=== Step 6: Execute the Refund ===");

        // Create args with the refund request ID
        bytes memory refundArgs = abi.encodePacked(refundRequestId);

        // Create a UserOperation for refund
        PackedUserOperation memory refundUserOp = createUserOp(delegation, delegator, refundableAmount, refundArgs);

        // Sign and execute the refund UserOperation
        refundUserOp = signUserOp(refundUserOp);
        executeUserOp(refundUserOp);

        // Display the final refund state
        displayRefundState(delegationHash);

        // Deactivate the subscription
        console.log("\n=== Step 7: Deactivate Subscription ===");
        deactivateSubscription(delegationHash);

        // Display the final state after deactivation
        displayRefundState(delegationHash);
    }

    /**
     * @notice Run the no refund policy scenario
     */
    function runNoRefundScenario() internal {
        console.log("\n=== SCENARIO 5: NO REFUND POLICY ===");

        // Create delegation with no refund policy
        Delegation memory delegation = createAndSignDelegation(POLICY_NO_REFUND);
        bytes32 delegationHash = EncoderLib._getDelegationHash(delegation);
        console.log("Delegation hash:", vm.toString(delegationHash));

        // Make a payment
        console.log("\n=== Step 1: Make a Payment ===");

        // Create a UserOperation for payment
        PackedUserOperation memory paymentUserOp = createUserOp(delegation, PAYMENT_RECIPIENT, PAYMENT_AMOUNT, "");

        // Sign and execute the payment UserOperation
        paymentUserOp = signUserOp(paymentUserOp);
        executeUserOp(paymentUserOp);

        // Record the payment in the RefundEnforcer
        recordPayment(delegationHash, PAYMENT_AMOUNT);

        // Display the refund state after payment
        displayRefundState(delegationHash);

        // Try to request a refund
        console.log("\n=== Step 2: Attempt to Request a Refund (Should Calculate to 0) ===");
        bytes32 refundRequestId =
            requestRefund(delegationHash, delegator, PAYMENT_AMOUNT, "Trying to get a refund, but policy doesn't allow it");

        // Approve the refund request (this will succeed but the amount will be 0)
        console.log("\n=== Step 3: Approve the Refund Request ===");
        approveRefund(refundRequestId);

        // Calculate refundable amount (should be 0)
        console.log("\n=== Step 4: Calculate Refundable Amount (Should be 0) ===");
        uint256 refundableAmount = calculateRefundableAmount(delegation.caveats[0].terms, delegationHash, PAYMENT_AMOUNT);

        console.log("\n=== Step 5: No Refund Execution Since Amount is 0 ===");
        console.log("Refundable amount is 0, no execution possible");

        // Display the final refund state
        displayRefundState(delegationHash);

        // Deactivate the subscription
        console.log("\n=== Step 6: Deactivate Subscription ===");
        deactivateSubscription(delegationHash);

        // Display the final state after deactivation
        displayRefundState(delegationHash);
    }

    /**
     * @notice Create and sign a delegation for refund policies
     * @param refundPolicy The refund policy to use (1-5)
     * @return delegation The created and signed delegation
     */
    function createAndSignDelegation(uint8 refundPolicy) internal returns (Delegation memory) {
        // Create a delegation from delegator to delegate
        Delegation memory delegation;
        delegation.delegator = address(delegatorWallet);
        delegation.delegate = address(delegateWallet);
        delegation.authority = ROOT_AUTHORITY;

        // For tiered refund policy, we need to encode the tiers
        uint256[] memory tieredRefundPercentages;
        uint256[] memory tieredTimePeriods;

        if (refundPolicy == POLICY_TIERED) {
            // Create tiered refund policy with 3 tiers
            tieredRefundPercentages = new uint256[](3);
            tieredRefundPercentages[0] = 10000; // 100% if refunded within tier 1
            tieredRefundPercentages[1] = 5000; // 50% if refunded within tier 2
            tieredRefundPercentages[2] = 2500; // 25% if refunded within tier 3

            tieredTimePeriods = new uint256[](3);
            tieredTimePeriods[0] = 1 days; // Tier 1: 1 day
            tieredTimePeriods[1] = 3 days; // Tier 2: 3 days
            tieredTimePeriods[2] = 7 days; // Tier 3: 7 days
        } else {
            // Initialize empty arrays for non-tiered policies
            tieredRefundPercentages = new uint256[](0);
            tieredTimePeriods = new uint256[](0);
        }

        // Encode the tiered data if using tiered policy
        bytes memory tieredData = bytes("");
        if (refundPolicy == POLICY_TIERED) {
            tieredData = abi.encode(tieredRefundPercentages, tieredTimePeriods);
        }

        // Create the terms for the RefundEnforcer
        // First 192 bytes are fixed for all policies
        bytes memory fixedTerms = abi.encodePacked(
            bytes31(0),
            uint8(refundPolicy), // Refund policy (padded to 32 bytes)
            uint256(FULL_REFUND_PERIOD), // Full refund period (1 day)
            uint256(PARTIAL_REFUND_PERIOD), // Partial refund period (7 days)
            uint256(MAX_REFUND_PERCENT_BPS), // Max refund percentage (50%)
            uint256(MAX_REFUNDS_PER_SUBSCRIPTION), // Max refunds per subscription (3)
            uint256(MIN_TIME_BETWEEN_REFUNDS) // Min time between refunds (1 day)
        );

        // Combine the fixed terms with the tiered data (if any)
        bytes memory terms = bytes.concat(fixedTerms, tieredData);

        // Create the caveat with the RefundEnforcer
        Caveat[] memory caveats = new Caveat[](1);
        caveats[0] = Caveat({ enforcer: address(refundEnforcer), terms: terms, args: "" });

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
     * @notice Create a UserOperation for executing a payment or refund
     * @param delegation The delegation to use
     * @param target The target address (payment recipient or refund recipient)
     * @param value The amount of ETH to transfer
     * @param args Additional arguments for the caveat enforcer
     * @return userOp The created UserOperation
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
        // Create an execution for an ETH transfer
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

            // Using redeemDelegationsWithArgs is not supported in the current interface
            // Let's create our own calldata using the standard redeemDelegations with an extra parameter
            redeemCallData = abi.encodeWithSignature(
                "redeemDelegationsWithArgs(bytes[],bytes4[],bytes[],bytes[])",
                permissionContexts,
                modes,
                executionCallDatas,
                argsArray
            );
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
                console.logBytes(result);
            }
        }

        return (success, result);
    }

    /**
     * @notice Record a payment for a delegation
     * @param delegationHash The hash of the delegation
     * @param amount The payment amount
     * @return success Whether the payment was successfully recorded
     */
    function recordPayment(bytes32 delegationHash, uint256 amount) internal returns (bool) {
        vm.startPrank(delegator);
        bool success = refundEnforcer.recordPayment(delegationHash, address(delegatorWallet), amount);
        vm.stopPrank();

        console.log("Payment recorded:", success ? "Yes" : "No");
        console.log("  Amount:", vm.toString(amount));

        return success;
    }

    /**
     * @notice Record usage of the service
     * @param delegationHash The hash of the delegation
     * @return usageCount The updated usage count
     */
    function recordUsage(bytes32 delegationHash) internal returns (uint256) {
        vm.startPrank(delegator);
        uint256 usageCount = refundEnforcer.recordUsage(delegationHash, address(delegatorWallet));
        vm.stopPrank();

        console.log("Usage recorded, count:", vm.toString(usageCount));

        return usageCount;
    }

    /**
     * @notice Request a refund for a delegation
     * @param delegationHash The hash of the delegation
     * @param refundRecipient The address to receive the refund
     * @param requestedAmount The amount to refund
     * @param reason The reason for the refund
     * @return refundRequestId The ID of the refund request
     */
    function requestRefund(
        bytes32 delegationHash,
        address refundRecipient,
        uint256 requestedAmount,
        string memory reason
    )
        internal
        returns (bytes32)
    {
        vm.startPrank(delegator);
        bytes32 refundRequestId =
            refundEnforcer.requestRefund(delegationHash, address(delegatorWallet), refundRecipient, requestedAmount, reason);
        vm.stopPrank();

        console.log("Refund requested, request ID:", vm.toString(refundRequestId));
        console.log("  Recipient:", refundRecipient);
        console.log("  Requested amount:", vm.toString(requestedAmount));
        console.log("  Reason:", reason);

        return refundRequestId;
    }

    /**
     * @notice Approve a refund request
     * @param refundRequestId The ID of the refund request
     * @return success Whether the refund was successfully approved
     */
    function approveRefund(bytes32 refundRequestId) internal returns (bool) {
        vm.startPrank(delegator);
        bool success = refundEnforcer.approveRefund(refundRequestId);
        vm.stopPrank();

        console.log("Refund approved:", success ? "Yes" : "No");
        console.log("  Request ID:", vm.toString(refundRequestId));

        return success;
    }

    /**
     * @notice Calculate the refundable amount for a refund request
     * @param terms The terms of the delegation
     * @param delegationHash The hash of the delegation
     * @param requestedAmount The requested refund amount
     * @return refundableAmount The calculated refundable amount
     */
    function calculateRefundableAmount(
        bytes memory terms,
        bytes32 delegationHash,
        uint256 requestedAmount
    )
        internal
        view
        returns (uint256)
    {
        uint256 refundableAmount = refundEnforcer.calculateRefundableAmount(terms, delegationHash, requestedAmount);

        console.log("Calculated refundable amount:", vm.toString(refundableAmount));
        console.log("  Requested amount:", vm.toString(requestedAmount));

        return refundableAmount;
    }

    /**
     * @notice Deactivate a subscription
     * @param delegationHash The hash of the delegation
     * @return success Whether the subscription was successfully deactivated
     */
    function deactivateSubscription(bytes32 delegationHash) internal returns (bool) {
        vm.startPrank(delegator);
        bool success = refundEnforcer.deactivateSubscription(delegationHash, address(delegatorWallet));
        vm.stopPrank();

        console.log("Subscription deactivated:", success ? "Yes" : "No");

        return success;
    }

    /**
     * @notice Display the current refund state
     * @param delegationHash The hash of the delegation
     */
    function displayRefundState(bytes32 delegationHash) internal view {
        console.log("\n=== Refund State ===");

        try refundEnforcer.refundStates(delegationHash) returns (
            uint256 lastPaymentTime,
            uint256 lastPaymentAmount,
            uint256 totalPaidAmount,
            uint256 totalRefundedAmount,
            uint256 lastRefundTime,
            uint256 refundCount,
            uint256 usageCount,
            bool isActive
        ) {
            console.log("  Last Payment Time:", vm.toString(lastPaymentTime));
            console.log("  Last Payment Amount:", vm.toString(lastPaymentAmount));
            console.log("  Total Paid Amount:", vm.toString(totalPaidAmount));
            console.log("  Total Refunded Amount:", vm.toString(totalRefundedAmount));
            console.log("  Last Refund Time:", vm.toString(lastRefundTime));
            console.log("  Refund Count:", vm.toString(refundCount));
            console.log("  Usage Count:", vm.toString(usageCount));
            console.log("  Is Active:", isActive ? "Yes" : "No");
        } catch Error(string memory reason) {
            console.log("Failed to get refund state:", reason);
        } catch {
            console.log("Failed to get refund state");
        }
    }

    /**
     * @notice Helper function to advance time
     * @param duration The amount of time to advance
     */
    function advanceTime(uint256 duration) internal {
        vm.warp(block.timestamp + duration);
        console.log("Time advanced by", vm.toString(duration), "seconds");
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
