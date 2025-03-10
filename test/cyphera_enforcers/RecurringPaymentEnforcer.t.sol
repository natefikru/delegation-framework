// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { Execution, Caveat, Delegation, ModeCode } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "../enforcers/CaveatEnforcerBaseTest.t.sol";
import { RecurringPaymentEnforcer } from "../../src/cyphera_enforcers/RecurringPaymentEnforcer.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

/**
 * @title RecurringPaymentEnforcerTest
 * @notice Test contract for RecurringPaymentEnforcer
 */
contract RecurringPaymentEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////// State //////////////////////

    RecurringPaymentEnforcer public recurringPaymentEnforcer;
    ModeCode public mode = ModeLib.encodeSimpleSingle();
    uint256 public paymentAmount = 0.01 ether;
    uint256 public interval = 30 days;
    uint256 public maxPayments = 12;
    uint256 public maxDunningAttempts = 3;
    bytes32 public delegationHash;
    bytes public terms;
    bytes public executionCallData;

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        recurringPaymentEnforcer = new RecurringPaymentEnforcer();
        vm.label(address(recurringPaymentEnforcer), "Recurring Payment Enforcer");

        // Fund Alice's account for testing
        vm.deal(address(users.alice.deleGator), 10 ether);

        // Setup common test data
        terms = abi.encode(interval, maxPayments, paymentAmount, maxDunningAttempts);
        delegationHash = keccak256("test_delegation");

        // Create the execution that would be executed
        Execution memory execution = Execution({ target: address(users.bob.deleGator), value: paymentAmount, callData: hex"" });
        executionCallData = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);
    }

    ////////////////////// Valid cases //////////////////////

    // Test a single payment execution
    function test_singlePayment() public {
        // Check initial state
        (uint256 lastAttemptTime, uint256 successfulPayments, uint256 dunningAttempts, bool isNullified) =
            recurringPaymentEnforcer.paymentStates(delegationHash);
        assertEq(successfulPayments, 0);

        // Execute payment
        vm.startPrank(address(delegationManager));
        recurringPaymentEnforcer.beforeHook(
            terms, hex"", mode, executionCallData, delegationHash, address(users.alice.deleGator), address(users.bob.deleGator)
        );
        recurringPaymentEnforcer.afterHook(
            terms, hex"", mode, executionCallData, delegationHash, address(users.alice.deleGator), address(users.bob.deleGator)
        );
        vm.stopPrank();

        // Verify payment was recorded
        (lastAttemptTime, successfulPayments, dunningAttempts, isNullified) = recurringPaymentEnforcer.paymentStates(delegationHash);
        assertEq(successfulPayments, 1);
        assertEq(dunningAttempts, 0);
        assertEq(isNullified, false);
    }

    // Test multiple payments with interval enforcement
    function test_multiplePaymentsWithInterval() public {
        vm.startPrank(address(delegationManager));

        // First payment
        recurringPaymentEnforcer.beforeHook(
            terms, hex"", mode, executionCallData, delegationHash, address(users.alice.deleGator), address(users.bob.deleGator)
        );
        recurringPaymentEnforcer.afterHook(
            terms, hex"", mode, executionCallData, delegationHash, address(users.alice.deleGator), address(users.bob.deleGator)
        );

        // Immediate second payment should fail due to interval
        vm.expectRevert("RecurringPaymentEnforcer:interval-not-passed");
        recurringPaymentEnforcer.beforeHook(
            terms, hex"", mode, executionCallData, delegationHash, address(users.alice.deleGator), address(users.bob.deleGator)
        );

        // Advance time past interval
        vm.warp(block.timestamp + interval + 1);

        // Second payment should now succeed
        recurringPaymentEnforcer.beforeHook(
            terms, hex"", mode, executionCallData, delegationHash, address(users.alice.deleGator), address(users.bob.deleGator)
        );
        recurringPaymentEnforcer.afterHook(
            terms, hex"", mode, executionCallData, delegationHash, address(users.alice.deleGator), address(users.bob.deleGator)
        );

        vm.stopPrank();

        // Verify two payments were recorded
        (, uint256 successfulPayments,,) = recurringPaymentEnforcer.paymentStates(delegationHash);
        assertEq(successfulPayments, 2);
    }

    // Test max payments enforcement
    function test_maxPaymentsEnforcement() public {
        // Use a smaller maxPayments for faster testing
        uint256 testMaxPayments = 3;
        bytes memory testTerms = abi.encode(interval, testMaxPayments, paymentAmount, maxDunningAttempts);

        vm.startPrank(address(delegationManager));

        // Make maxPayments successful payments
        for (uint256 i = 0; i < testMaxPayments; i++) {
            if (i > 0) vm.warp(block.timestamp + interval + 1);

            recurringPaymentEnforcer.beforeHook(
                testTerms,
                hex"",
                mode,
                executionCallData,
                delegationHash,
                address(users.alice.deleGator),
                address(users.bob.deleGator)
            );
            recurringPaymentEnforcer.afterHook(
                testTerms,
                hex"",
                mode,
                executionCallData,
                delegationHash,
                address(users.alice.deleGator),
                address(users.bob.deleGator)
            );
        }

        // Try one more payment (should fail due to max payments)
        vm.warp(block.timestamp + interval + 1);
        vm.expectRevert("RecurringPaymentEnforcer:max-payments-reached");
        recurringPaymentEnforcer.beforeHook(
            testTerms, hex"", mode, executionCallData, delegationHash, address(users.alice.deleGator), address(users.bob.deleGator)
        );

        vm.stopPrank();

        // Verify max payments were recorded
        (, uint256 successfulPayments,,) = recurringPaymentEnforcer.paymentStates(delegationHash);
        assertEq(successfulPayments, testMaxPayments);
    }

    // Test dunning functionality
    function test_dunningFunctionality() public {
        vm.startPrank(address(delegationManager));

        // First payment attempt
        recurringPaymentEnforcer.beforeHook(
            terms, hex"", mode, executionCallData, delegationHash, address(users.alice.deleGator), address(users.bob.deleGator)
        );

        // Record payment failures up to max dunning attempts
        for (uint256 i = 0; i < maxDunningAttempts; i++) {
            bool nullified = recurringPaymentEnforcer.recordPaymentFailure(
                terms, delegationHash, address(users.alice.deleGator), address(users.bob.deleGator), executionCallData
            );
            assertEq(nullified, false);
            vm.warp(block.timestamp + 1 days);
        }

        // One more failure should nullify the subscription
        bool nullified = recurringPaymentEnforcer.recordPaymentFailure(
            terms, delegationHash, address(users.alice.deleGator), address(users.bob.deleGator), executionCallData
        );
        assertEq(nullified, true);

        // Try another payment (should fail due to nullification)
        vm.warp(block.timestamp + interval + 1);
        vm.expectRevert("RecurringPaymentEnforcer:subscription-nullified");
        recurringPaymentEnforcer.beforeHook(
            terms, hex"", mode, executionCallData, delegationHash, address(users.alice.deleGator), address(users.bob.deleGator)
        );

        vm.stopPrank();

        // Verify subscription is nullified
        (,,, bool isNullified) = recurringPaymentEnforcer.paymentStates(delegationHash);
        assertEq(isNullified, true);
    }

    // Test successful payment after dunning
    function test_successfulPaymentAfterDunning() public {
        vm.startPrank(address(delegationManager));

        // First payment attempt
        recurringPaymentEnforcer.beforeHook(
            terms, hex"", mode, executionCallData, delegationHash, address(users.alice.deleGator), address(users.bob.deleGator)
        );

        // Record two payment failures
        recurringPaymentEnforcer.recordPaymentFailure(
            terms, delegationHash, address(users.alice.deleGator), address(users.bob.deleGator), executionCallData
        );
        vm.warp(block.timestamp + 1 days);

        recurringPaymentEnforcer.recordPaymentFailure(
            terms, delegationHash, address(users.alice.deleGator), address(users.bob.deleGator), executionCallData
        );
        vm.warp(block.timestamp + 1 days);

        // This time payment succeeds
        recurringPaymentEnforcer.beforeHook(
            terms, hex"", mode, executionCallData, delegationHash, address(users.alice.deleGator), address(users.bob.deleGator)
        );
        recurringPaymentEnforcer.afterHook(
            terms, hex"", mode, executionCallData, delegationHash, address(users.alice.deleGator), address(users.bob.deleGator)
        );

        vm.stopPrank();

        // Verify payment succeeded and dunning attempts were reset
        (, uint256 successfulPayments, uint256 dunningAttempts,) = recurringPaymentEnforcer.paymentStates(delegationHash);
        assertEq(successfulPayments, 1);
        assertEq(dunningAttempts, 0);
    }

    ////////////////////// Integration //////////////////////

    // Test full integration with delegation
    function test_fullIntegration() public {
        // Create the execution for payment
        Execution memory execution = Execution({ target: address(users.bob.deleGator), value: paymentAmount, callData: hex"" });

        // Create delegation with RecurringPaymentEnforcer caveat
        Caveat[] memory caveats = new Caveat[](1);
        caveats[0] = Caveat({ enforcer: address(recurringPaymentEnforcer), terms: terms, args: hex"" });

        Delegation memory delegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats,
            salt: 0,
            signature: hex""
        });

        delegation = signDelegation(users.alice, delegation);
        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = delegation;

        // Record initial balances
        uint256 aliceBalanceBefore = address(users.alice.deleGator).balance;
        uint256 bobBalanceBefore = address(users.bob.deleGator).balance;

        // First payment should succeed
        invokeDelegation_UserOp(users.bob, delegations, execution);

        // Verify payment was made
        uint256 aliceBalanceAfter = address(users.alice.deleGator).balance;
        uint256 bobBalanceAfter = address(users.bob.deleGator).balance;
        assertEq(aliceBalanceBefore - aliceBalanceAfter, paymentAmount);
        assertGt(bobBalanceAfter - bobBalanceBefore, paymentAmount - 1e10);

        // Immediate second payment should fail due to interval
        invokeDelegation_UserOp(users.bob, delegations, execution);

        // Verify balances didn't change significantly
        assertApproxEqAbs(address(users.alice.deleGator).balance, aliceBalanceAfter, 0.001 ether);
        assertApproxEqAbs(address(users.bob.deleGator).balance, bobBalanceAfter, 0.001 ether);

        // Advance time past interval
        vm.warp(block.timestamp + interval + 1);

        // Second payment should now succeed
        invokeDelegation_UserOp(users.bob, delegations, execution);

        // Verify second payment was made
        assertEq(aliceBalanceAfter - address(users.alice.deleGator).balance, paymentAmount);
        assertGt(address(users.bob.deleGator).balance - bobBalanceAfter, paymentAmount - 1e10);
    }

    ////////////////////// Required override //////////////////////

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(recurringPaymentEnforcer));
    }
}
