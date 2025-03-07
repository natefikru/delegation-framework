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
import { PauseResumeEnforcer } from "../src/cyphera_enforcers/PauseResumeEnforcer.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";
import { IEntryPoint } from "@account-abstraction/interfaces/IEntryPoint.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { PackedUserOperation } from "@account-abstraction/interfaces/PackedUserOperation.sol";
import { IERC173 } from "../src/interfaces/IERC173.sol";

/**
 * @title PauseResumeEIP7702Delegation
 * @notice Script to demonstrate the integration of PauseResumeEnforcer with EIP-7702 delegation framework
 */
contract PauseResumeEIP7702Delegation is Script {
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
    PauseResumeEnforcer public pauseResumeEnforcer;

    // Subscription parameters
    uint256 public constant MAX_PAUSE_DURATION = 30 days;
    uint256 public constant MAX_PAUSES = 3;
    uint256 public constant MIN_TIME_BETWEEN_PAUSES = 7 days;
    uint256 public constant RESERVED = 0;
    bytes32 private constant ROOT_AUTHORITY = bytes32(0);

    // Feature IDs for testing partial pauses
    uint256 public constant FEATURE_PREMIUM = 1;
    uint256 public constant FEATURE_BASIC = 2;
    uint256 public constant FEATURE_ADMIN = 3;

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

        // Send ETH to addresses
        vm.deal(delegator, 100 ether);
        vm.deal(delegate, 100 ether);

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

        // Create PauseResume Enforcer
        pauseResumeEnforcer = new PauseResumeEnforcer();
        vm.label(address(pauseResumeEnforcer), "PauseResumeEnforcer");

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
        console.log("PauseResumeEnforcer address:", address(pauseResumeEnforcer));

        // Create a delegation
        console.log("\n=== Creating Delegation ===");
        Delegation memory delegation = createAndSignDelegation();
        bytes32 delegationHash = EncoderLib._getDelegationHash(delegation);
        console.log("Delegation hash:", vm.toString(delegationHash));

        // Display initial pause state
        console.log("\n=== Initial Pause State ===");
        displayPauseState(delegationHash);

        // Step 1: Execute an action before pausing (should succeed)
        console.log("\n=== Step 1: Execute Action Before Pausing ===");
        // Create simple calldata for demonstration (a no-op call)
        bytes memory actionCallData = hex"";
        executeAction(delegation, address(delegatorWallet), actionCallData);

        // Step 2: Pause the subscription (all features)
        console.log("\n=== Step 2: Pause Subscription (All Features) ===");
        uint256[] memory pausedFeatures = new uint256[](0); // Empty array = all features
        bool pauseSuccess = pauseSubscription(delegationHash, pausedFeatures);
        console.log("Pause success:", pauseSuccess ? "Yes" : "No");

        // Display pause state after pausing
        console.log("\n=== Pause State After Pausing (All Features) ===");
        displayPauseState(delegationHash);

        // Step 3: Try to execute an action while paused (should fail)
        console.log("\n=== Step 3: Try to Execute Action While Paused ===");
        executeAction(delegation, address(delegatorWallet), actionCallData);

        // Step 4: Resume the subscription
        console.log("\n=== Step 4: Resume Subscription ===");
        uint256 pauseDuration = resumeSubscription(delegationHash);
        console.log("Pause duration:", vm.toString(pauseDuration), "seconds");

        // Display pause state after resuming
        console.log("\n=== Pause State After Resuming ===");
        displayPauseState(delegationHash);

        // Step 5: Execute an action after resuming (should succeed)
        console.log("\n=== Step 5: Execute Action After Resuming ===");
        executeAction(delegation, address(delegatorWallet), actionCallData);

        // Step 6: Pause specific features
        console.log("\n=== Step 6: Pause Specific Features ===");
        uint256[] memory specificFeatures = new uint256[](2);
        specificFeatures[0] = FEATURE_PREMIUM;
        specificFeatures[1] = FEATURE_ADMIN;
        pauseSuccess = pauseSubscription(delegationHash, specificFeatures);
        console.log("Partial pause success:", pauseSuccess ? "Yes" : "No");

        // Display pause state after partial pausing
        console.log("\n=== Pause State After Partial Pausing ===");
        displayPauseState(delegationHash);

        // Step 7: Try to execute actions for different features
        console.log("\n=== Step 7: Test Feature-Specific Pause ===");

        // Try FEATURE_PREMIUM (should fail)
        bytes memory premiumFeatureArgs = abi.encodePacked(bytes32(FEATURE_PREMIUM));
        console.log("\nTrying to execute PREMIUM feature (ID: 1) - should fail");
        executeAction(delegation, address(delegatorWallet), premiumFeatureArgs);

        // Try FEATURE_BASIC (should succeed)
        bytes memory basicFeatureArgs = abi.encodePacked(bytes32(FEATURE_BASIC));
        console.log("\nTrying to execute BASIC feature (ID: 2) - should succeed");
        executeAction(delegation, address(delegatorWallet), basicFeatureArgs);

        // Step 8: Resume again
        console.log("\n=== Step 8: Resume Subscription Again ===");
        pauseDuration = resumeSubscription(delegationHash);
        console.log("Pause duration:", vm.toString(pauseDuration), "seconds");

        // Display final pause state
        console.log("\n=== Final Pause State ===");
        displayPauseState(delegationHash);
    }

    /**
     * @notice Create and sign a delegation for pausing and resuming subscriptions
     * @return delegation The created and signed delegation
     */
    function createAndSignDelegation() internal returns (Delegation memory) {
        // Create a delegation from delegator to delegate
        Delegation memory delegation;
        delegation.delegator = address(delegatorWallet);
        delegation.delegate = address(delegateWallet);
        delegation.authority = ROOT_AUTHORITY;

        // Create the terms for the PauseResumeEnforcer
        // The terms should be 128 bytes (4 uint256 values)
        bytes memory terms = abi.encodePacked(
            uint256(MAX_PAUSE_DURATION), // Maximum pause duration (30 days)
            uint256(MAX_PAUSES), // Maximum number of pauses allowed (3)
            uint256(MIN_TIME_BETWEEN_PAUSES), // Minimum time between pauses (7 days)
            uint256(RESERVED) // Reserved for future use
        );

        // Create the caveat with the PauseResumeEnforcer
        Caveat[] memory caveats = new Caveat[](1);
        caveats[0] = Caveat({ enforcer: address(pauseResumeEnforcer), terms: terms, args: "" });

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
     * @notice Create a UserOperation for executing an action
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
     * @notice Display the current pause state
     * @param delegationHash The hash of the delegation
     */
    function displayPauseState(bytes32 delegationHash) internal view {
        (bool isPaused, uint256[] memory pausedFeatures) = pauseResumeEnforcer.isSubscriptionPaused(delegationHash);

        console.log("Pause State:");
        console.log("  Is Paused:", isPaused ? "Yes" : "No");

        console.log("  Paused Features:");
        if (pausedFeatures.length == 0) {
            console.log("    All features are paused");
        } else {
            for (uint256 i = 0; i < pausedFeatures.length; i++) {
                console.log("    Feature ID:", vm.toString(pausedFeatures[i]));
            }
        }

        uint256 totalPauseDuration = pauseResumeEnforcer.getTotalPauseDuration(delegationHash);
        console.log("  Total Pause Duration:", vm.toString(totalPauseDuration), "seconds");
    }

    /**
     * @notice Pause the subscription
     * @param delegationHash The hash of the delegation
     * @param pausedFeatures Array of feature IDs to pause (empty to pause all features)
     * @return success Whether the pause was successful
     */
    function pauseSubscription(bytes32 delegationHash, uint256[] memory pausedFeatures) internal returns (bool) {
        vm.startPrank(delegator);
        bool success = pauseResumeEnforcer.pauseSubscription(
            createAndSignDelegation().caveats[0].terms, delegationHash, address(delegatorWallet), pausedFeatures
        );
        vm.stopPrank();

        return success;
    }

    /**
     * @notice Resume the subscription
     * @param delegationHash The hash of the delegation
     * @return pauseDuration The duration of the pause
     */
    function resumeSubscription(bytes32 delegationHash) internal returns (uint256) {
        vm.startPrank(delegator);
        uint256 pauseDuration = pauseResumeEnforcer.resumeSubscription(delegationHash, address(delegatorWallet));
        vm.stopPrank();

        return pauseDuration;
    }

    /**
     * @notice Execute a simple action using the delegation
     * @param delegation The delegation to use
     * @param actionTarget The target address for the action
     * @param actionCallData The calldata for the action
     */
    function executeAction(Delegation memory delegation, address actionTarget, bytes memory actionCallData) internal {
        console.log("\n=== Executing Action ===");

        // Create an execution
        Execution memory execution = Execution({ target: actionTarget, value: 0, callData: actionCallData });

        // Create a UserOperation
        PackedUserOperation memory userOp = createUserOp(delegation, execution);

        // Sign the UserOperation
        console.log("Signing UserOperation...");
        userOp = signUserOp(userOp);

        // Execute the UserOperation
        console.log("Executing UserOperation...");
        vm.startBroadcast();

        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = userOp;

        try entryPoint.handleOps(userOps, payable(delegate)) {
            console.log("UserOperation executed successfully");
        } catch Error(string memory reason) {
            console.log("UserOperation execution failed:", reason);
        } catch (bytes memory lowLevelData) {
            console.log("UserOperation execution failed with low level error");
            console.logBytes(lowLevelData);
        }

        vm.stopBroadcast();
    }
}
