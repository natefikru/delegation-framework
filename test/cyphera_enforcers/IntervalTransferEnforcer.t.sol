// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { Execution, Caveat, Delegation, ModeCode } from "../../src/utils/Types.sol";
import { Counter } from "../utils/Counter.t.sol";
import { CaveatEnforcerBaseTest } from "../enforcers/CaveatEnforcerBaseTest.t.sol";
import { IntervalTransferEnforcer } from "../../src/cyphera_enforcers/IntervalTransferEnforcer.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

contract IntervalTransferEnforcerTest is CaveatEnforcerBaseTest {
    using ModeLib for ModeCode;

    ////////////////////////////// Events //////////////////////////////

    event TransferExecuted(
        address indexed sender,
        address indexed redeemer,
        bytes32 indexed delegationHash,
        uint256 amount,
        uint256 transferCount,
        uint256 timestamp
    );

    ////////////////////// State //////////////////////

    IntervalTransferEnforcer public intervalTransferEnforcer;
    ModeCode public mode = ModeLib.encodeSimpleSingle();
    uint256 public constant TRANSFER_AMOUNT = 1 ether;
    uint256 public constant INTERVAL = 1 days;
    uint256 public constant MAX_TRANSFERS = 3;

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        intervalTransferEnforcer = new IntervalTransferEnforcer();
        vm.label(address(intervalTransferEnforcer), "Interval Transfer Enforcer");

        // Fund Alice's DeleGator with some ETH for transfers
        vm.deal(address(users.alice.deleGator), 10 ether);
    }

    ////////////////////// Valid cases //////////////////////

    // Test a single transfer
    function test_singleTransfer() public {
        // Create a simple ETH transfer execution
        Execution memory execution_ = Execution({ target: address(users.bob.deleGator), value: TRANSFER_AMOUNT, callData: hex"" });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Create terms for the enforcer
        bytes memory terms_ = abi.encodePacked(INTERVAL, MAX_TRANSFERS, TRANSFER_AMOUNT);

        // Create a delegation hash to track state
        bytes32 delegationHash_ = keccak256("test_delegation");

        // Initial state should be zero
        assertEq(intervalTransferEnforcer.transferCounts(address(delegationManager), delegationHash_), 0);
        assertEq(intervalTransferEnforcer.lastTransferTimes(address(delegationManager), delegationHash_), 0);

        // Expect the transfer event to be emitted
        vm.prank(address(delegationManager));
        vm.expectEmit(true, true, true, true, address(intervalTransferEnforcer));
        emit TransferExecuted(
            address(delegationManager), address(users.bob.deleGator), delegationHash_, TRANSFER_AMOUNT, 1, block.timestamp
        );

        // Execute the beforeHook
        intervalTransferEnforcer.beforeHook(
            terms_, hex"", mode, executionCallData_, delegationHash_, address(users.alice.deleGator), address(users.bob.deleGator)
        );

        // Check that state was updated correctly
        assertEq(intervalTransferEnforcer.transferCounts(address(delegationManager), delegationHash_), 1);
        assertEq(intervalTransferEnforcer.lastTransferTimes(address(delegationManager), delegationHash_), block.timestamp);
    }

    // Test multiple transfers with required interval between them
    function test_multipleTransfersWithInterval() public {
        // Create a simple ETH transfer execution
        Execution memory execution_ = Execution({ target: address(users.bob.deleGator), value: TRANSFER_AMOUNT, callData: hex"" });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Create terms for the enforcer
        bytes memory terms_ = abi.encodePacked(INTERVAL, MAX_TRANSFERS, TRANSFER_AMOUNT);

        // Create a delegation hash to track state
        bytes32 delegationHash_ = keccak256("test_delegation");

        // Initial state should be zero
        assertEq(intervalTransferEnforcer.transferCounts(address(delegationManager), delegationHash_), 0);

        // First transfer should succeed
        vm.prank(address(delegationManager));
        intervalTransferEnforcer.beforeHook(
            terms_, hex"", mode, executionCallData_, delegationHash_, address(users.alice.deleGator), address(users.bob.deleGator)
        );

        // Attempt second transfer immediately (should fail)
        vm.prank(address(delegationManager));
        vm.expectRevert("IntervalTransferEnforcer:interval-not-reached");
        intervalTransferEnforcer.beforeHook(
            terms_, hex"", mode, executionCallData_, delegationHash_, address(users.alice.deleGator), address(users.bob.deleGator)
        );

        // Move time forward and try again (should succeed)
        vm.warp(block.timestamp + INTERVAL);

        vm.prank(address(delegationManager));
        intervalTransferEnforcer.beforeHook(
            terms_, hex"", mode, executionCallData_, delegationHash_, address(users.alice.deleGator), address(users.bob.deleGator)
        );

        // Check state after two transfers
        assertEq(intervalTransferEnforcer.transferCounts(address(delegationManager), delegationHash_), 2);
    }

    ////////////////////// Invalid cases //////////////////////

    // Test enforcing the maximum transfers limit
    function test_maxTransfersEnforcement() public {
        // Create a simple ETH transfer execution
        Execution memory execution_ = Execution({ target: address(users.bob.deleGator), value: TRANSFER_AMOUNT, callData: hex"" });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Set a small max transfers limit for this test
        uint256 maxTransfers_ = 2;
        bytes memory terms_ = abi.encodePacked(INTERVAL, maxTransfers_, TRANSFER_AMOUNT);

        // Create a delegation hash to track state
        bytes32 delegationHash_ = keccak256("test_delegation");

        vm.startPrank(address(delegationManager));

        // First transfer
        intervalTransferEnforcer.beforeHook(
            terms_, hex"", mode, executionCallData_, delegationHash_, address(users.alice.deleGator), address(users.bob.deleGator)
        );

        // Move time forward
        vm.warp(block.timestamp + INTERVAL);

        // Second transfer
        intervalTransferEnforcer.beforeHook(
            terms_, hex"", mode, executionCallData_, delegationHash_, address(users.alice.deleGator), address(users.bob.deleGator)
        );

        // Move time forward
        vm.warp(block.timestamp + INTERVAL);

        // Third transfer should fail because max is 2
        vm.expectRevert("IntervalTransferEnforcer:max-transfers-reached");
        intervalTransferEnforcer.beforeHook(
            terms_, hex"", mode, executionCallData_, delegationHash_, address(users.alice.deleGator), address(users.bob.deleGator)
        );

        vm.stopPrank();

        // Check state after attempts
        assertEq(intervalTransferEnforcer.transferCounts(address(delegationManager), delegationHash_), maxTransfers_);
    }

    // Test that transfers must be to the redeemer (delegate)
    function test_onlyToRedeemer() public {
        // Create an execution to send to Carol instead of Bob (should fail)
        Execution memory execution_ = Execution({ target: address(users.carol.deleGator), value: TRANSFER_AMOUNT, callData: hex"" });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        bytes memory terms_ = abi.encodePacked(INTERVAL, MAX_TRANSFERS, TRANSFER_AMOUNT);
        bytes32 delegationHash_ = keccak256("test_delegation");

        // Attempt transfer to someone who isn't the redeemer
        vm.prank(address(delegationManager));
        vm.expectRevert("IntervalTransferEnforcer:invalid-recipient");
        intervalTransferEnforcer.beforeHook(
            terms_,
            hex"",
            mode,
            executionCallData_,
            delegationHash_,
            address(users.alice.deleGator),
            address(users.bob.deleGator) // Bob is the redeemer, but Carol is the target
        );
    }

    // Test that only the exact transfer amount is allowed
    function test_exactTransferAmount() public {
        // Create an execution with incorrect amount
        Execution memory execution_ = Execution({
            target: address(users.bob.deleGator),
            value: TRANSFER_AMOUNT + 1, // Incorrect amount
            callData: hex""
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        bytes memory terms_ = abi.encodePacked(INTERVAL, MAX_TRANSFERS, TRANSFER_AMOUNT);
        bytes32 delegationHash_ = keccak256("test_delegation");

        // Attempt transfer with incorrect amount
        vm.prank(address(delegationManager));
        vm.expectRevert("IntervalTransferEnforcer:incorrect-transfer-amount");
        intervalTransferEnforcer.beforeHook(
            terms_, hex"", mode, executionCallData_, delegationHash_, address(users.alice.deleGator), address(users.bob.deleGator)
        );
    }

    // Test that the terms must have the correct length
    function test_invalidTermsLength() public {
        // Create terms with incorrect length
        bytes memory invalidTerms_ = abi.encodePacked(uint256(1), uint256(2));

        Execution memory execution_ = Execution({ target: address(users.bob.deleGator), value: TRANSFER_AMOUNT, callData: hex"" });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Attempt to use invalid terms
        vm.prank(address(delegationManager));
        vm.expectRevert("IntervalTransferEnforcer:invalid-terms-length");
        intervalTransferEnforcer.beforeHook(invalidTerms_, hex"", mode, executionCallData_, bytes32(0), address(0), address(0));
    }

    ////////////////////// Integration //////////////////////

    // Test full integration with the delegation system
    function test_fullIntegrationSuccess() public {
        // Before balances
        uint256 aliceBalanceBefore = address(users.alice.deleGator).balance;
        uint256 bobBalanceBefore = address(users.bob.deleGator).balance;

        // Create the execution that would be executed (simple ETH transfer)
        Execution memory execution_ = Execution({ target: address(users.bob.deleGator), value: TRANSFER_AMOUNT, callData: hex"" });

        // Create the delegation with our enforcer caveat
        bytes memory terms_ = abi.encodePacked(INTERVAL, MAX_TRANSFERS, TRANSFER_AMOUNT);
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(intervalTransferEnforcer), terms: terms_ });

        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        // Sign the delegation
        delegation_ = signDelegation(users.alice, delegation_);

        // Execute delegation via UserOp
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        // First transfer should succeed
        invokeDelegation_UserOp(users.bob, delegations_, execution_);

        // Check balances after first transfer
        uint256 aliceBalanceAfter = address(users.alice.deleGator).balance;
        uint256 bobBalanceAfter = address(users.bob.deleGator).balance;

        // Account for some gas fees in the checks
        assertApproxEqAbs(aliceBalanceBefore - aliceBalanceAfter, TRANSFER_AMOUNT, 0.01 ether);
        assertApproxEqAbs(bobBalanceAfter - bobBalanceBefore, TRANSFER_AMOUNT, 0.01 ether);

        // Try second transfer immediately (should fail silently)
        invokeDelegation_UserOp(users.bob, delegations_, execution_);

        // Balances shouldn't have changed much
        assertApproxEqAbs(aliceBalanceAfter, address(users.alice.deleGator).balance, 0.01 ether);
        assertApproxEqAbs(bobBalanceAfter, address(users.bob.deleGator).balance, 0.01 ether);

        // Move time forward
        vm.warp(block.timestamp + INTERVAL);

        // Try transfer again (should succeed)
        invokeDelegation_UserOp(users.bob, delegations_, execution_);

        // Check final balances
        uint256 aliceBalanceFinal = address(users.alice.deleGator).balance;
        uint256 bobBalanceFinal = address(users.bob.deleGator).balance;

        // Account for some gas fees in the checks
        assertApproxEqAbs(aliceBalanceAfter - aliceBalanceFinal, TRANSFER_AMOUNT, 0.01 ether);
        assertApproxEqAbs(bobBalanceFinal - bobBalanceAfter, TRANSFER_AMOUNT, 0.01 ether);

        // Get delegation hash and check state
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        assertEq(intervalTransferEnforcer.transferCounts(address(delegationManager), delegationHash_), 2);
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(intervalTransferEnforcer));
    }
}
