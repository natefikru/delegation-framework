// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { IEntryPoint, EntryPoint } from "@account-abstraction/core/EntryPoint.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { DelegationManager } from "../src/DelegationManager.sol";
import { ERC7715DeleGator } from "../src/ERC7715/ERC7715DeleGator.sol";
import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";
import { Execution, ModeCode, Delegation, Caveat } from "../src/utils/Types.sol";

/**
 * @title TestERC7715Implementation
 * @notice A simple script to test the ERC-7715 implementation locally
 * @dev Run with: forge script script/TestERC7715Implementation.s.sol -vvv
 */
contract TestERC7715Implementation is Script {
    using MessageHashUtils for bytes32;
    using ModeLib for ModeCode;

    // Test accounts
    uint256 private ownerPrivateKey;
    address private owner;

    // Contracts
    EntryPoint private entryPoint;
    DelegationManager private delegationManager;
    ERC7715DeleGator private deleGator;

    // Test data
    bytes32 private constant DOMAIN_SEPARATOR_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant EXECUTE_TYPEHASH = keccak256("Execute(bytes mode,bytes executionCalldata,uint256 nonce)");

    function setUp() public {
        // Use deterministic private keys for testing
        ownerPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        owner = vm.addr(ownerPrivateKey);

        console2.log("Owner address:", owner);
    }

    function run() public {
        vm.startBroadcast(ownerPrivateKey);

        // 1. Deploy the EntryPoint
        entryPoint = new EntryPoint();
        console2.log("EntryPoint deployed at:", address(entryPoint));

        // 2. Deploy the DelegationManager
        delegationManager = new DelegationManager(owner);
        console2.log("DelegationManager deployed at:", address(delegationManager));

        // 3. Deploy the ERC7715DeleGator
        deleGator = new ERC7715DeleGator(address(delegationManager), address(entryPoint));
        console2.log("ERC7715DeleGator deployed at:", address(deleGator));

        // 4. Test basic functionality
        testBasicFunctionality();

        vm.stopBroadcast();
    }

    function testBasicFunctionality() internal {
        // Check contract name and version
        string memory name = deleGator.NAME();
        string memory version = deleGator.VERSION();

        console2.log("Contract name:", name);
        console2.log("Contract version:", version);

        // Create a simple execution to transfer ETH
        address recipient = address(0x1);
        uint256 amount = 0.001 ether;

        // Skip sending ETH to the DeleGator for now
        console2.log("Skipping ETH transfer to DeleGator");

        // Create execution data
        Execution memory execution = Execution({ target: recipient, value: 0, callData: "" });

        // Encode the execution
        bytes memory executionCalldata = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

        // Create mode (simple single execution)
        ModeCode mode = ModeLib.encodeSimpleSingle();

        // Get the current nonce
        uint256 nonce = deleGator.getNonce();

        // Create the hash to sign
        bytes32 structHash =
            keccak256(abi.encode(EXECUTE_TYPEHASH, keccak256(abi.encode(mode)), keccak256(executionCalldata), nonce));

        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_SEPARATOR_TYPEHASH, keccak256(bytes(name)), keccak256(bytes(version)), block.chainid, address(deleGator)
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        // Sign the message
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Execute the transaction
        try deleGator.executeFromOwner(mode, executionCalldata, signature) {
            console2.log("Execution successful!");
        } catch Error(string memory reason) {
            console2.log("Execution failed:", reason);
        } catch (bytes memory) {
            console2.log("Execution failed with no reason");
        }

        // Check recipient balance
        console2.log("Recipient balance:", address(recipient).balance);
    }
}
