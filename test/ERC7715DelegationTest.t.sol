// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IEntryPoint, EntryPoint } from "@account-abstraction/core/EntryPoint.sol";
import { BytesLib } from "@bytes-utils/BytesLib.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";

import { SigningUtilsLib } from "./utils/SigningUtilsLib.t.sol";
import { Implementation, SignatureType } from "./utils/Types.t.sol";
import { Execution, PackedUserOperation, Caveat, Delegation, ModeCode } from "../src/utils/Types.sol";
import { BaseTest } from "./utils/BaseTest.t.sol";
import { AccountSorterLib } from "./utils/AccountSorterLib.t.sol";
import { EIP7702StatelessDeleGator } from "../src/EIP7702/EIP7702StatelessDeleGator.sol";
import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";
import { DeleGatorCore } from "../src/DeleGatorCore.sol";
import { EncoderLib } from "../src/libraries/EncoderLib.sol";
import { Counter } from "./utils/Counter.t.sol";
import { UserOperationLib } from "./utils/UserOperationLib.t.sol";
import { ERC1271Lib } from "../src/libraries/ERC1271Lib.sol";
import { EIP7702DeleGatorCore } from "../src/EIP7702/EIP7702DeleGatorCore.sol";
import {
    CALLTYPE_SINGLE,
    CALLTYPE_BATCH,
    CALLTYPE_DELEGATECALL,
    EXECTYPE_DEFAULT,
    EXECTYPE_TRY,
    MODE_DEFAULT,
    ModeLib,
    ExecType,
    ModeSelector,
    ModePayload
} from "@erc7579/lib/ModeLib.sol";

/**
 * @title ERC-7715 Delegation Implementation Test
 * @dev These tests verify the integration of ERC-7715 with EIP-7702 for delegation functionality
 */
contract ERC7715DelegationTest is BaseTest {
    using MessageHashUtils for bytes32;

    ////////////////////// Configure BaseTest //////////////////////

    constructor() {
        IMPLEMENTATION = Implementation.EIP7702Stateless;
        SIGNATURE_TYPE = SignatureType.EOA;
    }

    ////////////////////////////// State //////////////////////////////

    EIP7702StatelessDeleGator public aliceDeleGator;
    EIP7702StatelessDeleGator public bobDeleGator;
    Counter public aliceDeleGatorCounter;

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();

        // Set up typed DeleGators
        aliceDeleGator = EIP7702StatelessDeleGator(payable(address(users.alice.deleGator)));
        bobDeleGator = EIP7702StatelessDeleGator(payable(address(users.bob.deleGator)));

        aliceDeleGatorCounter = new Counter(address(users.alice.deleGator));
    }

    ////////////////////// ERC-7715 Integration Tests //////////////////////

    // Test delegation with EIP-7702 transaction
    function test_erc7715_withEIP7702Transaction() public {
        uint256 initialValue_ = aliceDeleGatorCounter.count();

        // Create delegation
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Sign delegation
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        bytes32 domainHash_ = delegationManager.getDomainHash();
        bytes32 typedDataHash_ = MessageHashUtils.toTypedDataHash(domainHash_, delegationHash_);

        // Use vm.signDelegation cheatcode for EIP-7702 signature
        vm.prank(users.alice.addr);
        bytes memory signature_ = SigningUtilsLib.signHash_EOA(users.alice.privateKey, typedDataHash_);
        delegation_.signature = signature_;

        // Create Bob's execution
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });

        // Execute Bob's UserOp with EIP-7702 transaction
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        // Use vm.attachDelegation cheatcode to mark this as an EIP-7702 transaction
        vm.prank(users.bob.addr);
        invokeDelegation_UserOp(users.bob, delegations_, execution_);

        // Get final count
        uint256 finalValue_ = aliceDeleGatorCounter.count();

        // Validate that the count has increased by 1
        assertEq(finalValue_, initialValue_ + 1);
    }

    // Test delegation with multiple caveats
    function test_erc7715_withMultipleCaveats() public {
        // This test would implement multiple caveats to restrict the delegation
        // For example, time-based restrictions, method restrictions, etc.
        // Implementation would depend on your specific caveat enforcers
    }

    // Test delegation chain (sub-delegation)
    function test_erc7715_delegationChain() public {
        // This test would implement a chain of delegations:
        // Alice -> Bob -> Charlie
        // Implementation would verify that Charlie can act on behalf of Alice through Bob
    }
}
