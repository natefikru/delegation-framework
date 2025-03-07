// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { Execution, Caveat, Delegation, ModeCode } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "../enforcers/CaveatEnforcerBaseTest.t.sol";
import { RefundEnforcer } from "../../src/cyphera_enforcers/RefundEnforcer.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

/**
 * @title RefundEnforcerTest
 * @notice Test contract for RefundEnforcer
 */
contract RefundEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////// State //////////////////////////////

    RefundEnforcer public refundEnforcer;
    ModeCode public mode = ModeLib.encodeSimpleSingle();
    bytes32 public delegationHash;

    // Refund policy constants
    uint8 public constant POLICY_FULL_REFUND = 1;
    uint8 public constant POLICY_PRORATED_TIME = 2;
    uint8 public constant POLICY_PRORATED_USAGE = 3;
    uint8 public constant POLICY_TIERED = 4;
    uint8 public constant POLICY_NO_REFUND = 5;

    // Test parameters
    uint256 public paymentAmount = 0.1 ether;
    uint256 public refundAmount = 0.05 ether;
    uint256 public fullRefundPeriod = 7 days;
    uint256 public partialRefundPeriod = 14 days;
    uint256 public maxRefundPercentBps = 5000; // 50%
    uint256 public maxRefundsPerSubscription = 3;
    uint256 public minTimeBetweenRefunds = 1 days;

    // Terms for different refund policies
    bytes public fullRefundTerms;
    bytes public proratedTimeTerms;
    bytes public proratedUsageTerms;
    bytes public tieredRefundTerms;
    bytes public noRefundTerms;

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        refundEnforcer = new RefundEnforcer();
        vm.label(address(refundEnforcer), "Refund Enforcer");

        // Fund Alice's account for testing
        vm.deal(address(users.alice.deleGator), 10 ether);

        // Setup common test data
        delegationHash = keccak256("test_delegation");

        // Setup terms for full refund policy
        fullRefundTerms = abi.encode(
            POLICY_FULL_REFUND, // Policy type
            fullRefundPeriod, // Full refund period
            0, // Partial refund period (not used for full refund)
            10000, // Max refund percent (100%)
            maxRefundsPerSubscription,
            minTimeBetweenRefunds,
            new uint256[](0), // No tiered percentages
            new uint256[](0) // No tiered time periods
        );

        // Setup terms for prorated time policy
        proratedTimeTerms = abi.encode(
            POLICY_PRORATED_TIME, // Policy type
            fullRefundPeriod, // Full refund period
            partialRefundPeriod, // Partial refund period
            maxRefundPercentBps, // Max refund percent (50%)
            maxRefundsPerSubscription,
            minTimeBetweenRefunds,
            new uint256[](0), // No tiered percentages
            new uint256[](0) // No tiered time periods
        );

        // Setup terms for prorated usage policy
        proratedUsageTerms = abi.encode(
            POLICY_PRORATED_USAGE, // Policy type
            fullRefundPeriod, // Full refund period
            0, // Partial refund period (not used for usage-based)
            maxRefundPercentBps, // Max refund percent (50%)
            maxRefundsPerSubscription,
            minTimeBetweenRefunds,
            new uint256[](0), // No tiered percentages
            new uint256[](0) // No tiered time periods
        );

        // Setup terms for tiered refund policy
        uint256[] memory tieredPercentages = new uint256[](3);
        tieredPercentages[0] = 10000; // 100% refund
        tieredPercentages[1] = 5000; // 50% refund
        tieredPercentages[2] = 2500; // 25% refund

        uint256[] memory tieredPeriods = new uint256[](3);
        tieredPeriods[0] = 3 days; // 100% refund if within 3 days
        tieredPeriods[1] = 7 days; // 50% refund if within 7 days
        tieredPeriods[2] = 14 days; // 25% refund if within 14 days

        tieredRefundTerms = abi.encodePacked(
            abi.encode(
                POLICY_TIERED, // Policy type
                0, // Full refund period (not used for tiered)
                0, // Partial refund period (not used for tiered)
                10000, // Max refund percent (100%)
                maxRefundsPerSubscription,
                minTimeBetweenRefunds
            ),
            abi.encode(tieredPercentages, tieredPeriods)
        );

        // Setup terms for no refund policy
        noRefundTerms = abi.encode(
            POLICY_NO_REFUND, // Policy type
            0, // Full refund period (not used for no refund)
            0, // Partial refund period (not used for no refund)
            0, // Max refund percent (0%)
            maxRefundsPerSubscription,
            minTimeBetweenRefunds,
            new uint256[](0), // No tiered percentages
            new uint256[](0) // No tiered time periods
        );
    }

    ////////////////////// Helper Functions //////////////////////

    function recordPayment(uint256 amount) internal {
        refundEnforcer.recordPayment(delegationHash, address(users.alice.deleGator), amount);
    }

    function recordUsage() internal {
        refundEnforcer.recordUsage(delegationHash, address(users.alice.deleGator));
    }

    function createRefundRequest(uint256 amount) internal returns (bytes32) {
        return refundEnforcer.requestRefund(
            delegationHash, address(users.alice.deleGator), address(users.bob.deleGator), amount, "Test refund request"
        );
    }

    function approveRefund(bytes32 requestId) internal {
        refundEnforcer.approveRefund(requestId);
    }

    function createRefundExecution(address recipient, uint256 amount) internal pure returns (bytes memory) {
        Execution memory execution = Execution({ target: recipient, value: amount, callData: hex"" });
        return ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);
    }

    function processRefund(bytes32 requestId, bytes memory terms, uint256 amount) internal {
        bytes memory executionCallData = createRefundExecution(address(users.bob.deleGator), amount);
        bytes memory args = abi.encodePacked(requestId);

        vm.startPrank(address(delegationManager));
        refundEnforcer.beforeHook(
            terms, args, mode, executionCallData, delegationHash, address(users.alice.deleGator), address(users.bob.deleGator)
        );
        refundEnforcer.afterHook(
            terms, args, mode, executionCallData, delegationHash, address(users.alice.deleGator), address(users.bob.deleGator)
        );
        vm.stopPrank();
    }

    // Helper function to check refund state
    function checkRefundState(
        bytes32 _delegationHash,
        uint256 _expectedPaidAmount,
        uint256 _expectedRefundedAmount,
        uint256 _expectedRefundCount
    )
        internal
    {
        (,, uint256 totalPaidAmount, uint256 totalRefundedAmount,, uint256 refundCount,,) =
            refundEnforcer.refundStates(_delegationHash);

        assertEq(totalPaidAmount, _expectedPaidAmount);
        assertEq(totalRefundedAmount, _expectedRefundedAmount);
        assertEq(refundCount, _expectedRefundCount);
    }

    ////////////////////// Test Cases //////////////////////

    // Test recording a payment
    function test_recordPayment() public {
        // Record a payment
        bool success = refundEnforcer.recordPayment(delegationHash, address(users.alice.deleGator), paymentAmount);

        // Verify payment was recorded
        assertTrue(success);

        // Check the refund state
        (uint256 lastPaymentTime, uint256 lastPaymentAmount, uint256 totalPaidAmount,,,,, bool isActive) =
            refundEnforcer.refundStates(delegationHash);

        assertEq(lastPaymentAmount, paymentAmount);
        assertEq(totalPaidAmount, paymentAmount);
        assertTrue(isActive);
        assertEq(lastPaymentTime, block.timestamp);
    }

    // Test recording usage
    function test_recordUsage() public {
        // Record usage
        uint256 usageCount = refundEnforcer.recordUsage(delegationHash, address(users.alice.deleGator));

        // Verify usage was recorded
        assertEq(usageCount, 1);

        // Record more usage
        usageCount = refundEnforcer.recordUsage(delegationHash, address(users.alice.deleGator));

        // Verify usage was incremented
        assertEq(usageCount, 2);
    }

    // Test deactivating a subscription
    function test_deactivateSubscription() public {
        // Record a payment to activate the subscription
        recordPayment(paymentAmount);

        // Deactivate the subscription
        bool success = refundEnforcer.deactivateSubscription(delegationHash, address(users.alice.deleGator));

        // Verify subscription was deactivated
        assertTrue(success);

        // Check the refund state
        (,,,,,,, bool isActive) = refundEnforcer.refundStates(delegationHash);
        assertFalse(isActive);
    }

    // Test requesting a refund
    function test_requestRefund() public {
        // Record a payment
        recordPayment(paymentAmount);

        // Request a refund
        bytes32 requestId = createRefundRequest(refundAmount);

        // Verify refund request was created
        (
            bytes32 delegationHash_,
            address delegator_,
            address refundRecipient_,
            uint256 requestedAmount_,
            uint256 requestTime_,
            string memory reason_,
            bool isProcessed_
        ) = refundEnforcer.refundRequests(requestId);

        assertEq(delegationHash_, delegationHash);
        assertEq(delegator_, address(users.alice.deleGator));
        assertEq(refundRecipient_, address(users.bob.deleGator));
        assertEq(requestedAmount_, refundAmount);
        assertEq(requestTime_, block.timestamp);
        assertEq(reason_, "Test refund request");
        assertFalse(isProcessed_);
    }

    // Test requesting a refund with no payments
    function test_requestRefund_noPayments() public {
        // Attempt to request a refund without any payments
        vm.expectRevert("RefundEnforcer:no-payments-to-refund");
        createRefundRequest(refundAmount);
    }

    // Test requesting a refund with amount too high
    function test_requestRefund_amountTooHigh() public {
        // Record a payment
        recordPayment(paymentAmount);

        // Attempt to request a refund with amount higher than paid
        vm.expectRevert("RefundEnforcer:requested-amount-too-high");
        createRefundRequest(paymentAmount + 0.01 ether);
    }

    // Test approving a refund
    function test_approveRefund() public {
        // Record a payment
        recordPayment(paymentAmount);

        // Request a refund
        bytes32 requestId = createRefundRequest(refundAmount);

        // Approve the refund
        bool success = refundEnforcer.approveRefund(requestId);

        // Verify refund was approved
        assertTrue(success);
        assertTrue(refundEnforcer.approvedRefunds(requestId));
    }

    // Test approving a non-existent refund
    function test_approveRefund_nonExistent() public {
        // Attempt to approve a non-existent refund
        bytes32 fakeRequestId = keccak256("fake_request");
        vm.expectRevert("RefundEnforcer:refund-request-not-found");
        refundEnforcer.approveRefund(fakeRequestId);
    }

    // Test full refund policy
    function test_fullRefundPolicy() public {
        // Record a payment
        recordPayment(paymentAmount);

        // Request a refund
        bytes32 requestId = createRefundRequest(refundAmount);

        // Approve the refund
        approveRefund(requestId);

        // Process the refund
        processRefund(requestId, fullRefundTerms, refundAmount);

        // Verify refund was processed
        (,,,,,, bool isProcessed) = refundEnforcer.refundRequests(requestId);
        assertTrue(isProcessed);

        // Check the refund state
        (,, uint256 totalPaidAmount, uint256 totalRefundedAmount, uint256 lastRefundTime, uint256 refundCount,,) =
            refundEnforcer.refundStates(delegationHash);

        assertEq(totalPaidAmount, paymentAmount);
        assertEq(totalRefundedAmount, refundAmount);
        assertEq(refundCount, 1);
        assertEq(lastRefundTime, block.timestamp);
    }

    // Test full refund policy after period expired
    function test_fullRefundPolicy_expired() public {
        // Record a payment
        recordPayment(paymentAmount);

        // Advance time past full refund period
        vm.warp(block.timestamp + fullRefundPeriod + 1);

        // Request a refund
        bytes32 requestId = createRefundRequest(refundAmount);

        // Approve the refund
        approveRefund(requestId);

        // Attempt to process the refund (should fail due to expired period)
        bytes memory executionCallData = createRefundExecution(address(users.bob.deleGator), refundAmount);
        bytes memory args = abi.encodePacked(requestId);

        vm.startPrank(address(delegationManager));
        vm.expectRevert("RefundEnforcer:no-refundable-amount");
        refundEnforcer.beforeHook(
            fullRefundTerms,
            args,
            mode,
            executionCallData,
            delegationHash,
            address(users.alice.deleGator),
            address(users.bob.deleGator)
        );
        vm.stopPrank();
    }

    // Test prorated time refund policy
    function test_proratedTimePolicy() public {
        // Record a payment
        recordPayment(paymentAmount);

        // Advance time to middle of partial refund period
        vm.warp(block.timestamp + fullRefundPeriod + (partialRefundPeriod / 2));

        // Request a refund
        bytes32 requestId = createRefundRequest(paymentAmount);

        // Approve the refund
        approveRefund(requestId);

        // Calculate expected refund amount (should be around 50% of payment)
        uint256 timeRemaining = fullRefundPeriod + partialRefundPeriod - (fullRefundPeriod + (partialRefundPeriod / 2));
        uint256 refundPercent = (timeRemaining * 10000) / partialRefundPeriod;
        uint256 expectedRefund = (paymentAmount * refundPercent) / 10000;

        // Process the refund
        bytes memory executionCallData = createRefundExecution(address(users.bob.deleGator), expectedRefund);
        bytes memory args = abi.encodePacked(requestId);

        vm.startPrank(address(delegationManager));
        refundEnforcer.beforeHook(
            proratedTimeTerms,
            args,
            mode,
            executionCallData,
            delegationHash,
            address(users.alice.deleGator),
            address(users.bob.deleGator)
        );
        refundEnforcer.afterHook(
            proratedTimeTerms,
            args,
            mode,
            executionCallData,
            delegationHash,
            address(users.alice.deleGator),
            address(users.bob.deleGator)
        );
        vm.stopPrank();

        // Verify refund was processed
        (,,,,,, bool isProcessed) = refundEnforcer.refundRequests(requestId);
        assertTrue(isProcessed);

        // Check the refund state
        (,, uint256 totalPaidAmount, uint256 totalRefundedAmount, uint256 lastRefundTime, uint256 refundCount,,) =
            refundEnforcer.refundStates(delegationHash);

        assertEq(totalPaidAmount, paymentAmount);
        assertEq(totalRefundedAmount, expectedRefund);
        assertEq(refundCount, 1);
        assertEq(lastRefundTime, block.timestamp);
    }

    // Test prorated usage refund policy
    function test_proratedUsagePolicy() public {
        // Record a payment
        recordPayment(paymentAmount);

        // Advance time past full refund period
        vm.warp(block.timestamp + fullRefundPeriod + 1);

        // Record some usage (less than expected)
        recordUsage();
        recordUsage();
        recordUsage(); // 3 usages out of expected 10

        // Request a refund
        bytes32 requestId = createRefundRequest(paymentAmount);

        // Approve the refund
        approveRefund(requestId);

        // Calculate expected refund amount
        uint256 usagePercent = (3 * 10000) / 10; // 3 usages out of expected 10
        uint256 refundPercent = 10000 - usagePercent;
        if (refundPercent > maxRefundPercentBps) {
            refundPercent = maxRefundPercentBps;
        }
        uint256 expectedRefund = (paymentAmount * refundPercent) / 10000;

        // Process the refund
        bytes memory executionCallData = createRefundExecution(address(users.bob.deleGator), expectedRefund);
        bytes memory args = abi.encodePacked(requestId);

        vm.startPrank(address(delegationManager));
        refundEnforcer.beforeHook(
            proratedUsageTerms,
            args,
            mode,
            executionCallData,
            delegationHash,
            address(users.alice.deleGator),
            address(users.bob.deleGator)
        );
        refundEnforcer.afterHook(
            proratedUsageTerms,
            args,
            mode,
            executionCallData,
            delegationHash,
            address(users.alice.deleGator),
            address(users.bob.deleGator)
        );
        vm.stopPrank();

        // Verify refund was processed
        (,,,,,, bool isProcessed) = refundEnforcer.refundRequests(requestId);
        assertTrue(isProcessed);

        // Check the refund state
        (,, uint256 totalPaidAmount, uint256 totalRefundedAmount, uint256 lastRefundTime, uint256 refundCount,,) =
            refundEnforcer.refundStates(delegationHash);

        assertEq(totalPaidAmount, paymentAmount);
        assertEq(totalRefundedAmount, expectedRefund);
        assertEq(refundCount, 1);
        assertEq(lastRefundTime, block.timestamp);
    }

    // Test tiered refund policy
    function test_tieredRefundPolicy() public {
        // Record a payment
        recordPayment(paymentAmount);

        // Advance time to second tier (50% refund)
        vm.warp(block.timestamp + 5 days); // Between 3 and 7 days

        // Request a refund
        bytes32 requestId = createRefundRequest(paymentAmount);

        // Approve the refund
        approveRefund(requestId);

        // Expected refund is 50% of payment
        uint256 expectedRefund = (paymentAmount * 5000) / 10000;

        // Process the refund
        bytes memory executionCallData = createRefundExecution(address(users.bob.deleGator), expectedRefund);
        bytes memory args = abi.encodePacked(requestId);

        vm.startPrank(address(delegationManager));
        refundEnforcer.beforeHook(
            tieredRefundTerms,
            args,
            mode,
            executionCallData,
            delegationHash,
            address(users.alice.deleGator),
            address(users.bob.deleGator)
        );
        refundEnforcer.afterHook(
            tieredRefundTerms,
            args,
            mode,
            executionCallData,
            delegationHash,
            address(users.alice.deleGator),
            address(users.bob.deleGator)
        );
        vm.stopPrank();

        // Verify refund was processed
        (,,,,,, bool isProcessed) = refundEnforcer.refundRequests(requestId);
        assertTrue(isProcessed);

        // Check the refund state
        (,, uint256 totalPaidAmount, uint256 totalRefundedAmount, uint256 lastRefundTime, uint256 refundCount,,) =
            refundEnforcer.refundStates(delegationHash);

        assertEq(totalPaidAmount, paymentAmount);
        assertEq(totalRefundedAmount, expectedRefund);
        assertEq(refundCount, 1);
        assertEq(lastRefundTime, block.timestamp);
    }

    // Test no refund policy
    function test_noRefundPolicy() public {
        // Record a payment
        recordPayment(paymentAmount);

        // Request a refund
        bytes32 requestId = createRefundRequest(refundAmount);

        // Approve the refund
        approveRefund(requestId);

        // Attempt to process the refund (should fail due to no refund policy)
        bytes memory executionCallData = createRefundExecution(address(users.bob.deleGator), refundAmount);
        bytes memory args = abi.encodePacked(requestId);

        vm.startPrank(address(delegationManager));
        vm.expectRevert("RefundEnforcer:no-refundable-amount");
        refundEnforcer.beforeHook(
            noRefundTerms,
            args,
            mode,
            executionCallData,
            delegationHash,
            address(users.alice.deleGator),
            address(users.bob.deleGator)
        );
        vm.stopPrank();
    }

    // Test maximum refunds per subscription
    function test_maxRefundsPerSubscription() public {
        // Record a payment with large amount
        recordPayment(paymentAmount * 10);

        // Process maximum number of refunds
        for (uint256 i = 0; i < maxRefundsPerSubscription; i++) {
            // Request a refund
            bytes32 requestId = createRefundRequest(refundAmount);

            // Approve the refund
            approveRefund(requestId);

            // Process the refund
            processRefund(requestId, fullRefundTerms, refundAmount);

            // Advance time past minimum time between refunds
            vm.warp(block.timestamp + minTimeBetweenRefunds + 1);
        }

        // Request one more refund
        bytes32 requestId = createRefundRequest(refundAmount);

        // Approve the refund
        approveRefund(requestId);

        // Attempt to process the refund (should fail due to max refunds reached)
        bytes memory executionCallData = createRefundExecution(address(users.bob.deleGator), refundAmount);
        bytes memory args = abi.encodePacked(requestId);

        vm.startPrank(address(delegationManager));
        vm.expectRevert("RefundEnforcer:no-refundable-amount");
        refundEnforcer.beforeHook(
            fullRefundTerms,
            args,
            mode,
            executionCallData,
            delegationHash,
            address(users.alice.deleGator),
            address(users.bob.deleGator)
        );
        vm.stopPrank();

        // Check the refund state
        (,, uint256 totalPaidAmount, uint256 totalRefundedAmount,, uint256 refundCount,,) =
            refundEnforcer.refundStates(delegationHash);

        assertEq(totalPaidAmount, paymentAmount * 10);
        assertEq(totalRefundedAmount, refundAmount * maxRefundsPerSubscription);
        assertEq(refundCount, maxRefundsPerSubscription);
    }

    // Test minimum time between refunds
    function test_minTimeBetweenRefunds() public {
        // Record a payment with large amount
        recordPayment(paymentAmount * 10);

        // Process first refund
        bytes32 requestId1 = createRefundRequest(refundAmount);
        approveRefund(requestId1);
        processRefund(requestId1, fullRefundTerms, refundAmount);

        // Request second refund immediately
        bytes32 requestId2 = createRefundRequest(refundAmount);
        approveRefund(requestId2);

        // Attempt to process the refund (should fail due to minimum time between refunds)
        bytes memory executionCallData = createRefundExecution(address(users.bob.deleGator), refundAmount);
        bytes memory args = abi.encodePacked(requestId2);

        vm.startPrank(address(delegationManager));
        vm.expectRevert("RefundEnforcer:no-refundable-amount");
        refundEnforcer.beforeHook(
            fullRefundTerms,
            args,
            mode,
            executionCallData,
            delegationHash,
            address(users.alice.deleGator),
            address(users.bob.deleGator)
        );
        vm.stopPrank();

        // Advance time past minimum time between refunds
        vm.warp(block.timestamp + minTimeBetweenRefunds + 1);

        // Now the refund should succeed
        processRefund(requestId2, fullRefundTerms, refundAmount);

        // Check the refund state
        (,, uint256 totalPaidAmount, uint256 totalRefundedAmount,, uint256 refundCount,,) =
            refundEnforcer.refundStates(delegationHash);

        assertEq(totalPaidAmount, paymentAmount * 10);
        assertEq(totalRefundedAmount, refundAmount * 2);
        assertEq(refundCount, 2);
    }

    // Test full integration with delegation
    function test_fullIntegration() public {
        // Record a payment
        recordPayment(paymentAmount);

        // Request a refund
        bytes32 requestId = createRefundRequest(refundAmount);

        // Approve the refund
        approveRefund(requestId);

        // Process the refund using direct hook calls
        bytes memory executionCallData = createRefundExecution(address(users.bob.deleGator), refundAmount);
        bytes memory args = abi.encodePacked(requestId);

        vm.startPrank(address(delegationManager));
        refundEnforcer.beforeHook(
            fullRefundTerms,
            args,
            mode,
            executionCallData,
            delegationHash,
            address(users.alice.deleGator),
            address(users.bob.deleGator)
        );
        refundEnforcer.afterHook(
            fullRefundTerms,
            args,
            mode,
            executionCallData,
            delegationHash,
            address(users.alice.deleGator),
            address(users.bob.deleGator)
        );
        vm.stopPrank();

        // Check the refund state
        checkRefundState(delegationHash, paymentAmount, refundAmount, 1);
    }

    ////////////////////// Required override //////////////////////

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(refundEnforcer));
    }
}
