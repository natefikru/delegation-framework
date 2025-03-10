// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { Execution, Caveat, Delegation, ModeCode } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "../enforcers/CaveatEnforcerBaseTest.t.sol";
import { DiscountEnforcer } from "../../src/cyphera_enforcers/DiscountEnforcer.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

/**
 * @title DiscountEnforcerTest
 * @notice Test contract for DiscountEnforcer
 */
contract DiscountEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////// State //////////////////////////////

    DiscountEnforcer public discountEnforcer;
    ModeCode public mode = ModeLib.encodeSimpleSingle();
    uint256 public originalAmount = 0.1 ether;
    bytes32 public delegationHash;
    bytes public terms;
    bytes public executionCallData;

    // Discount parameters
    uint256 public promoStartTime;
    uint256 public promoEndTime;
    uint256 public promoDiscountBps = 1000; // 10%
    uint256 public loyaltyThreshold = 3;
    uint256 public loyaltyDiscountBps = 500; // 5%
    uint256 public volumeThreshold = 5;
    uint256 public volumeDiscountBps = 700; // 7%
    uint256 public maxTotalDiscountBps = 2000; // 20%

    ////////////////////// Set up //////////////////////////////

    function setUp() public override {
        super.setUp();
        discountEnforcer = new DiscountEnforcer();
        vm.label(address(discountEnforcer), "Discount Enforcer");

        // Fund Alice's account for testing
        vm.deal(address(users.alice.deleGator), 10 ether);

        // Set up promotional period (starts now, ends in 30 days)
        promoStartTime = block.timestamp;
        promoEndTime = block.timestamp + 30 days;

        // Setup common test data
        terms = abi.encode(
            promoStartTime,
            promoEndTime,
            promoDiscountBps,
            loyaltyThreshold,
            loyaltyDiscountBps,
            volumeThreshold,
            volumeDiscountBps,
            originalAmount,
            maxTotalDiscountBps
        );
        delegationHash = keccak256("test_delegation");

        // Create the execution that would be executed (with original amount for now)
        Execution memory execution = Execution({ target: address(users.bob.deleGator), value: originalAmount, callData: hex"" });
        executionCallData = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);
    }

    ////////////////////// Valid cases //////////////////////////////

    // Test promotional discount
    function test_promotionalDiscount() public {
        // Initialize discount state
        discountEnforcer.initializeDiscountState(delegationHash);

        // Calculate the expected discounted amount (10% off)
        uint256 expectedDiscountedAmount = originalAmount - ((originalAmount * promoDiscountBps) / 10000);

        // Create execution with discounted amount
        Execution memory execution =
            Execution({ target: address(users.bob.deleGator), value: expectedDiscountedAmount, callData: hex"" });
        bytes memory discountedExecutionCallData = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

        // Execute beforeHook
        vm.startPrank(address(delegationManager));
        discountEnforcer.beforeHook(
            terms,
            hex"",
            mode,
            discountedExecutionCallData,
            delegationHash,
            address(users.alice.deleGator),
            address(users.bob.deleGator)
        );

        // Execute afterHook
        discountEnforcer.afterHook(
            terms,
            hex"",
            mode,
            discountedExecutionCallData,
            delegationHash,
            address(users.alice.deleGator),
            address(users.bob.deleGator)
        );
        vm.stopPrank();

        // Verify discount state was updated
        DiscountEnforcer.DiscountState memory state = discountEnforcer.getDiscountState(delegationHash);
        assertEq(state.successfulPayments, 1);
        assertEq(state.lastPaymentAmount, expectedDiscountedAmount);
        assertEq(state.totalAmountPaid, expectedDiscountedAmount);
    }

    // Test loyalty discount
    function test_loyaltyDiscount() public {
        // Initialize discount state
        discountEnforcer.initializeDiscountState(delegationHash);

        // Make enough payments to qualify for loyalty discount
        vm.startPrank(address(delegationManager));

        // First make payments with just promotional discount
        uint256 promoDiscountedAmount = originalAmount - ((originalAmount * promoDiscountBps) / 10000);
        Execution memory execution =
            Execution({ target: address(users.bob.deleGator), value: promoDiscountedAmount, callData: hex"" });
        bytes memory discountedExecutionCallData = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

        // Make loyaltyThreshold payments
        for (uint256 i = 0; i < loyaltyThreshold; i++) {
            discountEnforcer.beforeHook(
                terms,
                hex"",
                mode,
                discountedExecutionCallData,
                delegationHash,
                address(users.alice.deleGator),
                address(users.bob.deleGator)
            );

            discountEnforcer.afterHook(
                terms,
                hex"",
                mode,
                discountedExecutionCallData,
                delegationHash,
                address(users.alice.deleGator),
                address(users.bob.deleGator)
            );
        }

        // Now the next payment should have both promotional and loyalty discounts
        uint256 combinedDiscountBps = promoDiscountBps + loyaltyDiscountBps;
        uint256 combinedDiscountedAmount = originalAmount - ((originalAmount * combinedDiscountBps) / 10000);

        Execution memory loyaltyExecution =
            Execution({ target: address(users.bob.deleGator), value: combinedDiscountedAmount, callData: hex"" });
        bytes memory loyaltyExecutionCallData =
            ExecutionLib.encodeSingle(loyaltyExecution.target, loyaltyExecution.value, loyaltyExecution.callData);

        // Execute with combined discount
        discountEnforcer.beforeHook(
            terms,
            hex"",
            mode,
            loyaltyExecutionCallData,
            delegationHash,
            address(users.alice.deleGator),
            address(users.bob.deleGator)
        );

        discountEnforcer.afterHook(
            terms,
            hex"",
            mode,
            loyaltyExecutionCallData,
            delegationHash,
            address(users.alice.deleGator),
            address(users.bob.deleGator)
        );
        vm.stopPrank();

        // Verify discount state was updated
        DiscountEnforcer.DiscountState memory state = discountEnforcer.getDiscountState(delegationHash);
        assertEq(state.successfulPayments, loyaltyThreshold + 1);
        assertEq(state.lastPaymentAmount, combinedDiscountedAmount);
    }

    // Test coupon discount
    function test_couponDiscount() public {
        // Initialize discount state
        discountEnforcer.initializeDiscountState(delegationHash);

        // Register a coupon code
        string memory couponCode = "WELCOME10";
        uint256 couponDiscountBps = 1000; // 10%
        bool isRecurring = true;

        bytes32 couponHash = discountEnforcer.registerCoupon(couponCode, couponDiscountBps, isRecurring);

        // Apply the coupon to the delegation
        (bool success, uint256 discountBps) =
            discountEnforcer.applyCoupon(delegationHash, address(users.alice.deleGator), couponCode);
        assertTrue(success);
        assertEq(discountBps, couponDiscountBps);

        // Calculate the expected discounted amount (promo 10% + coupon 10% = 20%)
        uint256 combinedDiscountBps = promoDiscountBps + couponDiscountBps;
        // Cap at max discount
        if (combinedDiscountBps > maxTotalDiscountBps) {
            combinedDiscountBps = maxTotalDiscountBps;
        }
        uint256 expectedDiscountedAmount = originalAmount - ((originalAmount * combinedDiscountBps) / 10000);

        // Create execution with discounted amount
        Execution memory execution =
            Execution({ target: address(users.bob.deleGator), value: expectedDiscountedAmount, callData: hex"" });
        bytes memory discountedExecutionCallData = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

        // Execute beforeHook
        vm.startPrank(address(delegationManager));
        discountEnforcer.beforeHook(
            terms,
            hex"",
            mode,
            discountedExecutionCallData,
            delegationHash,
            address(users.alice.deleGator),
            address(users.bob.deleGator)
        );

        // Execute afterHook
        discountEnforcer.afterHook(
            terms,
            hex"",
            mode,
            discountedExecutionCallData,
            delegationHash,
            address(users.alice.deleGator),
            address(users.bob.deleGator)
        );
        vm.stopPrank();

        // Verify discount state was updated
        DiscountEnforcer.DiscountState memory state = discountEnforcer.getDiscountState(delegationHash);
        assertEq(state.successfulPayments, 1);
        assertEq(state.lastPaymentAmount, expectedDiscountedAmount);
        assertEq(state.totalAmountPaid, expectedDiscountedAmount);
        assertTrue(state.couponApplied);
        assertEq(state.appliedCouponHash, couponHash);
    }

    // Test one-time coupon
    function test_oneTimeCoupon() public {
        // Initialize discount state
        discountEnforcer.initializeDiscountState(delegationHash);

        // Register a one-time coupon code
        string memory couponCode = "ONETIME20";
        uint256 couponDiscountBps = 2000; // 20%
        bool isRecurring = false;

        discountEnforcer.registerCoupon(couponCode, couponDiscountBps, isRecurring);

        // Apply the coupon to the delegation
        (bool success, uint256 discountBps) =
            discountEnforcer.applyCoupon(delegationHash, address(users.alice.deleGator), couponCode);
        assertTrue(success);
        assertEq(discountBps, couponDiscountBps);

        // Calculate the expected discounted amount (capped at max 20%)
        uint256 combinedDiscountBps = promoDiscountBps + couponDiscountBps;
        // Cap at max discount
        if (combinedDiscountBps > maxTotalDiscountBps) {
            combinedDiscountBps = maxTotalDiscountBps;
        }
        uint256 expectedDiscountedAmount = originalAmount - ((originalAmount * combinedDiscountBps) / 10000);

        // Create execution with discounted amount
        Execution memory execution =
            Execution({ target: address(users.bob.deleGator), value: expectedDiscountedAmount, callData: hex"" });
        bytes memory discountedExecutionCallData = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

        vm.startPrank(address(delegationManager));

        // First payment with coupon
        discountEnforcer.beforeHook(
            terms,
            hex"",
            mode,
            discountedExecutionCallData,
            delegationHash,
            address(users.alice.deleGator),
            address(users.bob.deleGator)
        );

        discountEnforcer.afterHook(
            terms,
            hex"",
            mode,
            discountedExecutionCallData,
            delegationHash,
            address(users.alice.deleGator),
            address(users.bob.deleGator)
        );

        // Second payment should only have promotional discount (one-time coupon used)
        uint256 promoOnlyDiscountedAmount = originalAmount - ((originalAmount * promoDiscountBps) / 10000);

        Execution memory secondExecution =
            Execution({ target: address(users.bob.deleGator), value: promoOnlyDiscountedAmount, callData: hex"" });
        bytes memory secondExecutionCallData =
            ExecutionLib.encodeSingle(secondExecution.target, secondExecution.value, secondExecution.callData);

        discountEnforcer.beforeHook(
            terms,
            hex"",
            mode,
            secondExecutionCallData,
            delegationHash,
            address(users.alice.deleGator),
            address(users.bob.deleGator)
        );

        discountEnforcer.afterHook(
            terms,
            hex"",
            mode,
            secondExecutionCallData,
            delegationHash,
            address(users.alice.deleGator),
            address(users.bob.deleGator)
        );

        vm.stopPrank();

        // Verify discount state was updated
        DiscountEnforcer.DiscountState memory state = discountEnforcer.getDiscountState(delegationHash);
        assertEq(state.successfulPayments, 2);
        assertEq(state.lastPaymentAmount, promoOnlyDiscountedAmount);
        assertEq(state.totalAmountPaid, expectedDiscountedAmount + promoOnlyDiscountedAmount);
    }

    // Test volume discount
    function test_volumeDiscount() public {
        // Initialize discount state
        discountEnforcer.initializeDiscountState(delegationHash);

        // Record enough usage to qualify for volume discount
        for (uint256 i = 0; i < volumeThreshold; i++) {
            discountEnforcer.recordUsage(delegationHash);
        }

        // Calculate the expected discounted amount (promo 10% + volume 7% = 17%)
        uint256 combinedDiscountBps = promoDiscountBps + volumeDiscountBps;
        uint256 expectedDiscountedAmount = originalAmount - ((originalAmount * combinedDiscountBps) / 10000);

        // Create execution with discounted amount
        Execution memory execution =
            Execution({ target: address(users.bob.deleGator), value: expectedDiscountedAmount, callData: hex"" });
        bytes memory discountedExecutionCallData = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

        // Execute beforeHook
        vm.startPrank(address(delegationManager));
        discountEnforcer.beforeHook(
            terms,
            hex"",
            mode,
            discountedExecutionCallData,
            delegationHash,
            address(users.alice.deleGator),
            address(users.bob.deleGator)
        );

        // Execute afterHook
        discountEnforcer.afterHook(
            terms,
            hex"",
            mode,
            discountedExecutionCallData,
            delegationHash,
            address(users.alice.deleGator),
            address(users.bob.deleGator)
        );
        vm.stopPrank();

        // Verify discount state was updated
        DiscountEnforcer.DiscountState memory state = discountEnforcer.getDiscountState(delegationHash);
        assertEq(state.successfulPayments, 1);
        assertEq(state.lastPaymentAmount, expectedDiscountedAmount);
        assertEq(state.totalAmountPaid, expectedDiscountedAmount);
        assertEq(state.usageCount, volumeThreshold);
    }

    // Test maximum discount cap
    function test_maximumDiscountCap() public {
        // Initialize discount state
        discountEnforcer.initializeDiscountState(delegationHash);

        // Register a coupon code with high discount
        string memory couponCode = "MEGA30";
        uint256 couponDiscountBps = 3000; // 30%
        bool isRecurring = true;

        discountEnforcer.registerCoupon(couponCode, couponDiscountBps, isRecurring);
        discountEnforcer.applyCoupon(delegationHash, address(users.alice.deleGator), couponCode);

        // Record enough usage to qualify for volume discount
        for (uint256 i = 0; i < volumeThreshold; i++) {
            discountEnforcer.recordUsage(delegationHash);
        }

        // Make enough payments to qualify for loyalty discount
        vm.startPrank(address(delegationManager));

        // Calculate the expected discounted amount (capped at max 20%)
        // Total would be promo 10% + coupon 30% + volume 7% + loyalty 5% = 52%, but capped at 20%
        uint256 expectedDiscountedAmount = originalAmount - ((originalAmount * maxTotalDiscountBps) / 10000);

        // First make payments to qualify for loyalty
        for (uint256 i = 0; i < loyaltyThreshold; i++) {
            Execution memory execution =
                Execution({ target: address(users.bob.deleGator), value: expectedDiscountedAmount, callData: hex"" });
            bytes memory discountedExecutionCallData =
                ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

            discountEnforcer.beforeHook(
                terms,
                hex"",
                mode,
                discountedExecutionCallData,
                delegationHash,
                address(users.alice.deleGator),
                address(users.bob.deleGator)
            );

            discountEnforcer.afterHook(
                terms,
                hex"",
                mode,
                discountedExecutionCallData,
                delegationHash,
                address(users.alice.deleGator),
                address(users.bob.deleGator)
            );
        }

        // One more payment with all discounts (still capped at max)
        Execution memory finalExecution =
            Execution({ target: address(users.bob.deleGator), value: expectedDiscountedAmount, callData: hex"" });
        bytes memory finalExecutionCallData =
            ExecutionLib.encodeSingle(finalExecution.target, finalExecution.value, finalExecution.callData);

        discountEnforcer.beforeHook(
            terms, hex"", mode, finalExecutionCallData, delegationHash, address(users.alice.deleGator), address(users.bob.deleGator)
        );

        vm.stopPrank();

        // Calculate the total discount that would be applied without cap
        uint256 totalDiscountBps = promoDiscountBps + loyaltyDiscountBps + couponDiscountBps + volumeDiscountBps;
        assertTrue(totalDiscountBps > maxTotalDiscountBps, "Total discount should exceed max cap");

        // Verify the discount is capped
        (uint256 calculatedAmount, uint8[] memory appliedTypes) =
            discountEnforcer.calculateDiscountedAmount(terms, delegationHash, originalAmount);

        assertEq(calculatedAmount, expectedDiscountedAmount);
        assertEq(appliedTypes.length, 4); // All 4 discount types should be applied
    }

    ////////////////////// Invalid cases //////////////////////////////

    // Test invalid payment amount
    function test_invalidPaymentAmount() public {
        // Initialize discount state
        discountEnforcer.initializeDiscountState(delegationHash);

        // Calculate the expected discounted amount (10% off)
        uint256 expectedDiscountedAmount = originalAmount - ((originalAmount * promoDiscountBps) / 10000);

        // Create execution with WRONG amount (not discounted)
        Execution memory execution = Execution({
            target: address(users.bob.deleGator),
            value: originalAmount, // Using original amount instead of discounted
            callData: hex""
        });
        bytes memory wrongExecutionCallData = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

        // Execute beforeHook - should revert
        vm.startPrank(address(delegationManager));
        vm.expectRevert("DiscountEnforcer:invalid-payment-amount");
        discountEnforcer.beforeHook(
            terms, hex"", mode, wrongExecutionCallData, delegationHash, address(users.alice.deleGator), address(users.bob.deleGator)
        );
        vm.stopPrank();
    }

    // Test invalid coupon code
    function test_invalidCouponCode() public {
        // Initialize discount state
        discountEnforcer.initializeDiscountState(delegationHash);

        // Try to apply a non-existent coupon
        string memory invalidCouponCode = "INVALID";
        (bool success, uint256 discountBps) =
            discountEnforcer.applyCoupon(delegationHash, address(users.alice.deleGator), invalidCouponCode);

        assertFalse(success);
        assertEq(discountBps, 0);
    }

    // Test invalid terms
    function test_invalidTerms() public {
        // Create terms with invalid length
        bytes memory invalidTerms = abi.encode(uint256(1), uint256(2));

        vm.expectRevert("DiscountEnforcer:invalid-terms-length");
        discountEnforcer.getTermsInfo(invalidTerms);
    }

    ////////////////////// Integration //////////////////////////////

    // Test full integration with delegation
    function test_fullIntegration() public {
        // Register a coupon code
        string memory couponCode = "WELCOME15";
        uint256 couponDiscountBps = 1500; // 15%
        bool isRecurring = true;

        discountEnforcer.registerCoupon(couponCode, couponDiscountBps, isRecurring);

        // Calculate the expected discounted amount (promo 10% + coupon 15% = 25%, capped at 20%)
        uint256 expectedDiscountedAmount = originalAmount - ((originalAmount * maxTotalDiscountBps) / 10000);

        // Create the execution for payment with discounted amount
        Execution memory execution =
            Execution({ target: address(users.bob.deleGator), value: expectedDiscountedAmount, callData: hex"" });

        // Create delegation with DiscountEnforcer caveat
        Caveat[] memory caveats = new Caveat[](1);
        caveats[0] = Caveat({ enforcer: address(discountEnforcer), terms: terms, args: hex"" });

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

        // Get the delegation hash that will be used by the enforcer
        bytes32 integrationDelegationHash = delegationManager.getDelegationHash(delegation);

        // Initialize the discount state for this delegation
        discountEnforcer.initializeDiscountState(integrationDelegationHash);

        // Apply the coupon to the delegation
        discountEnforcer.applyCoupon(integrationDelegationHash, address(users.alice.deleGator), couponCode);

        // Record initial balances
        uint256 aliceBalanceBefore = address(users.alice.deleGator).balance;
        uint256 bobBalanceBefore = address(users.bob.deleGator).balance;

        // Execute the delegation
        invokeDelegation_UserOp(users.bob, delegations, execution);

        // Verify payment was made with discount
        uint256 aliceBalanceAfter = address(users.alice.deleGator).balance;
        uint256 bobBalanceAfter = address(users.bob.deleGator).balance;

        assertEq(aliceBalanceBefore - aliceBalanceAfter, expectedDiscountedAmount);
        assertGt(bobBalanceAfter - bobBalanceBefore, expectedDiscountedAmount - 1e10);

        // Verify discount state was updated
        DiscountEnforcer.DiscountState memory state = discountEnforcer.getDiscountState(integrationDelegationHash);
        assertEq(state.successfulPayments, 1);
        assertEq(state.lastPaymentAmount, expectedDiscountedAmount);
        assertEq(state.totalAmountPaid, expectedDiscountedAmount);
        assertTrue(state.couponApplied);
    }

    ////////////////////// Required override //////////////////////////////

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(discountEnforcer));
    }
}
