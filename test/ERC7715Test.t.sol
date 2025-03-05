// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { IEntryPoint, EntryPoint } from "@account-abstraction/core/EntryPoint.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {
    ModeLib,
    ModeCode,
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
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { DelegationManager } from "../src/DelegationManager.sol";
import { ERC7715DeleGator } from "../src/ERC7715/ERC7715DeleGator.sol";
import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";
import { Execution, Delegation, Caveat } from "../src/utils/Types.sol";
import { Counter } from "./utils/Counter.t.sol";

/**
 * @title ERC7715Test
 * @notice Test contract for the ERC-7715 implementation
 */
contract ERC7715Test is Test {
    using MessageHashUtils for bytes32;
    using ModeLib for ModeCode;

    // Test accounts
    address private owner;
    uint256 private ownerPrivateKey;
    address private delegate;
    uint256 private delegatePrivateKey;

    // Contracts
    EntryPoint private entryPoint;
    DelegationManager private delegationManager;
    ERC7715DeleGator private deleGator;
    Counter private counter;

    // Test data
    bytes32 private constant DOMAIN_SEPARATOR_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant EXECUTE_TYPEHASH = keccak256("Execute(bytes mode,bytes executionCalldata,uint256 nonce)");
    bytes32 private constant ROOT_AUTHORITY = bytes32(0);

    // Events
    event CounterIncremented(address indexed caller, uint256 newCount);

    function setUp() public {
        // Set up test accounts
        ownerPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        owner = vm.addr(ownerPrivateKey);

        delegatePrivateKey = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
        delegate = vm.addr(delegatePrivateKey);

        vm.label(owner, "Owner");
        vm.label(delegate, "Delegate");

        // Deploy contracts
        entryPoint = new EntryPoint();
        vm.label(address(entryPoint), "EntryPoint");

        delegationManager = new DelegationManager(owner);
        vm.label(address(delegationManager), "DelegationManager");

        deleGator = new ERC7715DeleGator(address(delegationManager), address(entryPoint));
        vm.label(address(deleGator), "ERC7715DeleGator");

        // Deploy a counter contract owned by the DeleGator
        counter = new Counter(address(deleGator));
        vm.label(address(counter), "Counter");

        // Fund the DeleGator with some ETH
        vm.deal(address(deleGator), 1 ether);
    }

    function test_BasicFunctionality() public {
        // Check contract name and version
        assertEq(deleGator.NAME(), "ERC7715DeleGator");
        assertEq(deleGator.VERSION(), "1.0.0");

        // Get initial counter value
        uint256 initialCount = counter.count();

        // Create execution data to increment the counter
        Execution memory execution =
            Execution({ target: address(counter), value: 0, callData: abi.encodeWithSelector(Counter.increment.selector) });

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
                DOMAIN_SEPARATOR_TYPEHASH,
                keccak256(bytes(deleGator.NAME())),
                keccak256(bytes(deleGator.VERSION())),
                block.chainid,
                address(deleGator)
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        // Sign the message
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Execute the transaction and expect the counter to be incremented
        vm.expectEmit(true, true, true, true);
        emit CounterIncremented(address(deleGator), initialCount + 1);

        deleGator.executeFromOwner(mode, executionCalldata, signature);

        // Verify the counter was incremented
        assertEq(counter.count(), initialCount + 1);
    }

    function test_BatchExecution() public {
        // Get initial counter value
        uint256 initialCount = counter.count();

        // Create batch execution data to increment the counter multiple times
        Execution[] memory executions = new Execution[](3);

        for (uint256 i = 0; i < 3; i++) {
            executions[i] =
                Execution({ target: address(counter), value: 0, callData: abi.encodeWithSelector(Counter.increment.selector) });
        }

        // Encode the batch execution
        bytes memory executionCalldata = ExecutionLib.encodeBatch(executions);

        // Create mode (batch execution)
        ModeCode mode = ModeLib.encodeSimpleBatch();

        // Get the current nonce
        uint256 nonce = deleGator.getNonce();

        // Create the hash to sign
        bytes32 structHash =
            keccak256(abi.encode(EXECUTE_TYPEHASH, keccak256(abi.encode(mode)), keccak256(executionCalldata), nonce));

        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_SEPARATOR_TYPEHASH,
                keccak256(bytes(deleGator.NAME())),
                keccak256(bytes(deleGator.VERSION())),
                block.chainid,
                address(deleGator)
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        // Sign the message
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Execute the batch transaction
        deleGator.executeFromOwner(mode, executionCalldata, signature);

        // Verify the counter was incremented 3 times
        assertEq(counter.count(), initialCount + 3);
    }

    function test_TryExecute() public {
        // Create a function call that will fail
        Execution memory execution =
            Execution({ target: address(counter), value: 0, callData: abi.encodeWithSelector(Counter.willRevert.selector) });

        // Encode the execution
        bytes memory executionCalldata = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

        // Create mode for try execution (using CALLTYPE_SINGLE and EXECTYPE_TRY)
        ModeCode mode = ModeLib.encode(CALLTYPE_SINGLE, EXECTYPE_TRY, MODE_DEFAULT, ModePayload.wrap(bytes22(0)));

        // Get the current nonce
        uint256 nonce = deleGator.getNonce();

        // Create the hash to sign
        bytes32 structHash =
            keccak256(abi.encode(EXECUTE_TYPEHASH, keccak256(abi.encode(mode)), keccak256(executionCalldata), nonce));

        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_SEPARATOR_TYPEHASH,
                keccak256(bytes(deleGator.NAME())),
                keccak256(bytes(deleGator.VERSION())),
                block.chainid,
                address(deleGator)
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        // Sign the message
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Execute the transaction with try execution
        // This should not revert even though the function call will fail
        (bool success, bytes memory result) = deleGator.executeFromOwner(mode, executionCalldata, signature);

        // Verify the execution was successful but the inner call failed
        assertTrue(success);
        assertTrue(result.length > 0);
    }
}
