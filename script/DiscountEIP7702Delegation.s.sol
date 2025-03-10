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
import { DiscountEnforcer } from "../src/cyphera_enforcers/DiscountEnforcer.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";
import { IEntryPoint } from "@account-abstraction/interfaces/IEntryPoint.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { PackedUserOperation } from "@account-abstraction/interfaces/PackedUserOperation.sol";
import { IERC173 } from "../src/interfaces/IERC173.sol";

/**
 * @title DiscountEIP7702Delegation
 * @notice Script to demonstrate the integration of DiscountEnforcer with EIP-7702 delegation framework
 */
contract DiscountEIP7702Delegation is Script {
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
    DiscountEnforcer public discountEnforcer;

    // Payment target
    address public merchant;

    // Basic discount parameters
    uint256 private constant ORIGINAL_AMOUNT = 0.1 ether;
    uint256 private constant DISCOUNT_AMOUNT = 0.02 ether;
    bytes32 private constant ROOT_AUTHORITY = bytes32(0);
    address private constant MERCHANT_ADDRESS = address(0x123);

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
        merchant = address(0x123); // Simple address for the merchant

        // Label addresses for debugging
        vm.label(delegator, "Delegator");
        vm.label(delegate, "Delegate");
        vm.label(merchant, "Merchant");

        // Send ETH to addresses
        vm.deal(delegator, 100 ether);
        vm.deal(delegate, 100 ether);
        vm.deal(merchant, 1 ether);

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

        // Create Discount Enforcer
        discountEnforcer = new DiscountEnforcer();
        vm.label(address(discountEnforcer), "DiscountEnforcer");

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
        console.log("DiscountEnforcer address:", address(discountEnforcer));
        console.log("Delegator wallet balance:", vm.toString(address(delegatorWallet).balance));

        // Create a simple UserOperation to send funds from delegator to merchant
        console.log("\n=== Creating UserOperation ===");

        // Create a delegation
        Delegation memory delegation = createAndSignDelegation();
        bytes32 delegationHash = EncoderLib._getDelegationHash(delegation);

        // Initialize discount state
        console.log("\n=== Initializing Discount State ===");
        initializeDiscountState(delegationHash);

        // Calculate the discounted amount
        console.log("\n=== Calculating Discounted Amount ===");
        uint256 discountedAmount = calculateDiscountedAmount(delegationHash, ORIGINAL_AMOUNT);
        console.log("Original amount:", vm.toString(ORIGINAL_AMOUNT));
        console.log("Calculated discounted amount:", vm.toString(discountedAmount));

        // Create the execution for payment
        Execution memory execution = Execution({ target: merchant, value: discountedAmount, callData: hex"" });

        // Create a UserOperation
        PackedUserOperation memory userOp = createUserOp(delegation, execution);

        // Sign the UserOperation
        console.log("\n=== Signing UserOperation ===");
        userOp = signUserOp(userOp);

        // Execute the UserOperation
        console.log("\n=== Executing UserOperation ===");
        vm.startBroadcast();

        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = userOp;

        try entryPoint.handleOps(userOps, payable(delegate)) {
            console.log("UserOperation executed successfully");
            console.log("Original amount:", vm.toString(ORIGINAL_AMOUNT));
            console.log("Discounted amount:", vm.toString(discountedAmount));
            console.log("Merchant balance after execution:", vm.toString(address(merchant).balance));
        } catch Error(string memory reason) {
            console.log("UserOperation execution failed:", reason);
        } catch (bytes memory lowLevelData) {
            console.log("UserOperation execution failed with low level error");
            console.logBytes(lowLevelData);
        }

        vm.stopBroadcast();

        // Display final discount state
        console.log("\n=== Final Discount State ===");
        displayDiscountState(delegationHash);
    }

    /**
     * @notice Initialize the discount state for a delegation
     * @param delegationHash The hash of the delegation
     */
    function initializeDiscountState(bytes32 delegationHash) internal {
        vm.startPrank(delegator);
        bool success = discountEnforcer.initializeDiscountState(delegationHash);
        console.log("Discount state initialized:", success);
        vm.stopPrank();
    }

    /**
     * @notice Create and sign a delegation for payments
     * @return delegation The created and signed delegation
     */
    function createAndSignDelegation() internal returns (Delegation memory) {
        // Create a delegation from delegator to delegate
        Delegation memory delegation;
        delegation.delegator = address(delegatorWallet);
        delegation.delegate = address(delegateWallet);
        delegation.authority = ROOT_AUTHORITY;

        // Create the terms for the discount enforcer
        // The terms should be 288 bytes (9 uint256 values)
        bytes memory terms = abi.encodePacked(
            uint256(block.timestamp), // promoStartTime
            uint256(block.timestamp + 1 days), // promoEndTime
            uint256(1000), // promoDiscountBps (10%)
            uint256(3), // loyaltyThreshold
            uint256(500), // loyaltyDiscountBps (5%)
            uint256(5), // volumeThreshold
            uint256(700), // volumeDiscountBps (7%)
            uint256(0.1 ether), // originalAmount
            uint256(2000) // maxTotalDiscountBps (20%)
        );

        // Create the caveat with the discount enforcer
        Caveat[] memory caveats = new Caveat[](1);
        caveats[0] = Caveat({ enforcer: address(discountEnforcer), terms: terms, args: "" });

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
     * @param execution The execution details
     * @return userOp The created UserOperation
     */
    function createUserOp(
        Delegation memory delegation,
        Execution memory execution
    )
        internal
        view
        returns (PackedUserOperation memory)
    {
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

        // Create the UserOperation
        return PackedUserOperation({
            sender: address(delegateWallet),
            nonce: 0,
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

        // Sign the message with the delegate's private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(delegatePrivateKey, typedDataHash);

        // Create the signature
        userOp.signature = abi.encodePacked(r, s, v);

        // Recover the address from the signature for verification
        address recoveredAddr = ECDSA.recover(typedDataHash, v, r, s);
        console.log("Recovered Address:", recoveredAddr);
        console.log("Recovered address matches delegate?", recoveredAddr == delegate ? "Yes" : "No");

        return userOp;
    }

    /**
     * @notice Display the current discount state
     * @param delegationHash The hash of the delegation
     */
    function displayDiscountState(bytes32 delegationHash) internal view {
        try discountEnforcer.getDiscountState(delegationHash) returns (DiscountEnforcer.DiscountState memory state) {
            console.log("Discount State:");
            console.log("  Subscription start time:", vm.toString(state.subscriptionStartTime));
            console.log("  Successful payments:", vm.toString(state.successfulPayments));
            console.log("  Usage count:", vm.toString(state.usageCount));
            console.log("  Coupon applied:", state.couponApplied);
            console.log("  Last payment amount:", vm.toString(state.lastPaymentAmount));
            console.log("  Total amount paid:", vm.toString(state.totalAmountPaid));
        } catch Error(string memory stateError) {
            console.log("Failed to get discount state:", stateError);
        } catch {
            console.log("Failed to get discount state");
        }
    }

    /**
     * @notice Calculate the discounted amount for a delegation
     * @param delegationHash The hash of the delegation
     * @param originalAmount The original payment amount
     * @return The discounted amount
     */
    function calculateDiscountedAmount(bytes32 delegationHash, uint256 originalAmount) internal returns (uint256) {
        // Get the terms from the delegation
        Delegation memory delegation = createAndSignDelegation();

        // Calculate the discounted amount
        (uint256 discountedAmount,) =
            discountEnforcer.calculateDiscountedAmount(delegation.caveats[0].terms, delegationHash, originalAmount);

        return discountedAmount;
    }
}
