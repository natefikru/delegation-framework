// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { CaveatEnforcer } from "../enforcers/CaveatEnforcer.sol";
import { ModeLib, CALLTYPE_SINGLE } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeCode, Execution } from "../utils/Types.sol";

/**
 * @title RefundEnforcer
 * @notice This enforcer manages subscription refunds with various policies.
 * @dev It supports:
 *  1. Different refund policies based on time since payment
 *  2. Partial refunds based on usage or time elapsed
 *  3. Maximum refund limits (amount and frequency)
 *  4. Refund approval conditions
 *  5. Payment history tracking for refund calculations
 */
contract RefundEnforcer is CaveatEnforcer {
    ////////////////////////////// State //////////////////////////////

    // Refund policy types
    uint8 public constant POLICY_FULL_REFUND = 1;
    uint8 public constant POLICY_PRORATED_TIME = 2;
    uint8 public constant POLICY_PRORATED_USAGE = 3;
    uint8 public constant POLICY_TIERED = 4;
    uint8 public constant POLICY_NO_REFUND = 5;

    // Struct to track refund state for each delegation
    struct RefundState {
        uint256 lastPaymentTime; // When the last payment was made
        uint256 lastPaymentAmount; // Amount of the last payment
        uint256 totalPaidAmount; // Total amount paid so far
        uint256 totalRefundedAmount; // Total amount refunded so far
        uint256 lastRefundTime; // When the last refund was processed
        uint256 refundCount; // Number of refunds processed
        uint256 usageCount; // Number of times the service has been used
        bool isActive; // Whether the subscription is active
    }

    // Mapping from delegation hash to refund state
    mapping(bytes32 delegationHash => RefundState state) public refundStates;

    // Mapping to track approved refund requests
    mapping(bytes32 refundRequestId => bool isApproved) public approvedRefunds;

    // Mapping to track refund request details
    struct RefundRequest {
        bytes32 delegationHash;
        address delegator;
        address refundRecipient;
        uint256 requestedAmount;
        uint256 requestTime;
        string reason;
        bool isProcessed;
    }

    mapping(bytes32 refundRequestId => RefundRequest request) public refundRequests;

    ////////////////////////////// Events //////////////////////////////

    /**
     * @notice Emitted when a payment is recorded
     * @param delegationHash The hash of the delegation
     * @param delegator The address of the delegator
     * @param amount The payment amount
     * @param paymentTime The timestamp of the payment
     */
    event PaymentRecorded(bytes32 indexed delegationHash, address indexed delegator, uint256 amount, uint256 paymentTime);

    /**
     * @notice Emitted when a refund request is created
     * @param refundRequestId The unique ID of the refund request
     * @param delegationHash The hash of the delegation
     * @param delegator The address of the delegator
     * @param requestedAmount The requested refund amount
     * @param reason The reason for the refund request
     */
    event RefundRequested(
        bytes32 indexed refundRequestId,
        bytes32 indexed delegationHash,
        address indexed delegator,
        uint256 requestedAmount,
        string reason
    );

    /**
     * @notice Emitted when a refund request is approved
     * @param refundRequestId The unique ID of the refund request
     * @param approver The address that approved the refund
     */
    event RefundApproved(bytes32 indexed refundRequestId, address indexed approver);

    /**
     * @notice Emitted when a refund is processed
     * @param refundRequestId The unique ID of the refund request
     * @param delegationHash The hash of the delegation
     * @param delegator The address of the delegator
     * @param recipient The address receiving the refund
     * @param amount The refund amount
     * @param refundTime The timestamp of the refund
     */
    event RefundProcessed(
        bytes32 indexed refundRequestId,
        bytes32 indexed delegationHash,
        address indexed delegator,
        address recipient,
        uint256 amount,
        uint256 refundTime
    );

    /**
     * @notice Emitted when usage is recorded
     * @param delegationHash The hash of the delegation
     * @param delegator The address of the delegator
     * @param usageCount The updated usage count
     */
    event UsageRecorded(bytes32 indexed delegationHash, address indexed delegator, uint256 usageCount);

    /**
     * @notice Emitted when a subscription is deactivated
     * @param delegationHash The hash of the delegation
     * @param delegator The address of the delegator
     * @param deactivationTime The timestamp of deactivation
     */
    event SubscriptionDeactivated(bytes32 indexed delegationHash, address indexed delegator, uint256 deactivationTime);

    ////////////////////////////// External Methods //////////////////////////////

    /**
     * @notice Records a payment for a subscription
     * @param _delegationHash The hash of the delegation
     * @param _delegator The address of the delegator
     * @param _amount The payment amount
     * @return success Whether the payment was successfully recorded
     */
    function recordPayment(bytes32 _delegationHash, address _delegator, uint256 _amount) external returns (bool success) {
        // Get the refund state
        RefundState storage state = refundStates[_delegationHash];

        // Update the state
        state.lastPaymentTime = block.timestamp;
        state.lastPaymentAmount = _amount;
        state.totalPaidAmount += _amount;
        state.isActive = true;

        // Emit event
        emit PaymentRecorded(_delegationHash, _delegator, _amount, block.timestamp);

        return true;
    }

    /**
     * @notice Records usage of the service
     * @param _delegationHash The hash of the delegation
     * @param _delegator The address of the delegator
     * @return usageCount The updated usage count
     */
    function recordUsage(bytes32 _delegationHash, address _delegator) external returns (uint256 usageCount) {
        // Get the refund state
        RefundState storage state = refundStates[_delegationHash];

        // Increment usage count
        state.usageCount++;

        // Emit event
        emit UsageRecorded(_delegationHash, _delegator, state.usageCount);

        return state.usageCount;
    }

    /**
     * @notice Deactivates a subscription
     * @param _delegationHash The hash of the delegation
     * @param _delegator The address of the delegator
     * @return success Whether the subscription was successfully deactivated
     */
    function deactivateSubscription(bytes32 _delegationHash, address _delegator) external returns (bool success) {
        // Get the refund state
        RefundState storage state = refundStates[_delegationHash];

        // Update the state
        state.isActive = false;

        // Emit event
        emit SubscriptionDeactivated(_delegationHash, _delegator, block.timestamp);

        return true;
    }

    /**
     * @notice Creates a refund request
     * @param _delegationHash The hash of the delegation
     * @param _delegator The address of the delegator
     * @param _refundRecipient The address to receive the refund
     * @param _requestedAmount The requested refund amount
     * @param _reason The reason for the refund request
     * @return refundRequestId The unique ID of the refund request
     */
    function requestRefund(
        bytes32 _delegationHash,
        address _delegator,
        address _refundRecipient,
        uint256 _requestedAmount,
        string calldata _reason
    )
        external
        returns (bytes32 refundRequestId)
    {
        // Get the refund state
        RefundState storage state = refundStates[_delegationHash];

        // Ensure the subscription has payments
        require(state.totalPaidAmount > 0, "RefundEnforcer:no-payments-to-refund");

        // Ensure the requested amount is not greater than the total paid amount minus already refunded amount
        require(_requestedAmount <= state.totalPaidAmount - state.totalRefundedAmount, "RefundEnforcer:requested-amount-too-high");

        // Generate a unique refund request ID
        refundRequestId =
            keccak256(abi.encodePacked(_delegationHash, _delegator, _refundRecipient, _requestedAmount, block.timestamp));

        // Store the refund request
        refundRequests[refundRequestId] = RefundRequest({
            delegationHash: _delegationHash,
            delegator: _delegator,
            refundRecipient: _refundRecipient,
            requestedAmount: _requestedAmount,
            requestTime: block.timestamp,
            reason: _reason,
            isProcessed: false
        });

        // Emit event
        emit RefundRequested(refundRequestId, _delegationHash, _delegator, _requestedAmount, _reason);

        return refundRequestId;
    }

    /**
     * @notice Approves a refund request
     * @param _refundRequestId The unique ID of the refund request
     * @return success Whether the refund was successfully approved
     */
    function approveRefund(bytes32 _refundRequestId) external returns (bool success) {
        // Ensure the refund request exists
        require(refundRequests[_refundRequestId].requestTime > 0, "RefundEnforcer:refund-request-not-found");

        // Ensure the refund request has not been processed
        require(!refundRequests[_refundRequestId].isProcessed, "RefundEnforcer:refund-already-processed");

        // Approve the refund
        approvedRefunds[_refundRequestId] = true;

        // Emit event
        emit RefundApproved(_refundRequestId, msg.sender);

        return true;
    }

    /**
     * @notice Calculates the refundable amount based on the refund policy and subscription state
     * @param _terms The terms to enforce set by the delegator
     * @param _delegationHash The hash of the delegation
     * @param _requestedAmount The requested refund amount
     * @return refundableAmount The calculated refundable amount
     */
    function calculateRefundableAmount(
        bytes calldata _terms,
        bytes32 _delegationHash,
        uint256 _requestedAmount
    )
        public
        view
        returns (uint256 refundableAmount)
    {
        // Get the refund state
        RefundState storage state = refundStates[_delegationHash];

        // Decode the terms
        (
            uint8 refundPolicy,
            uint256 fullRefundPeriod,
            uint256 partialRefundPeriod,
            uint256 maxRefundPercentBps,
            uint256 maxRefundsPerSubscription,
            uint256 minTimeBetweenRefunds,
            uint256[] memory tieredRefundPercentages,
            uint256[] memory tieredTimePeriods
        ) = getTermsInfo(_terms);

        // Check refund frequency limits
        if (state.refundCount >= maxRefundsPerSubscription) {
            return 0; // Maximum number of refunds reached
        }

        if (state.lastRefundTime > 0 && block.timestamp < state.lastRefundTime + minTimeBetweenRefunds) {
            return 0; // Minimum time between refunds not passed
        }

        // Calculate time since last payment
        uint256 timeSincePayment = block.timestamp - state.lastPaymentTime;

        // Apply refund policy based on type
        if (refundPolicy == POLICY_FULL_REFUND) {
            return calculateFullRefund(_requestedAmount, timeSincePayment, fullRefundPeriod);
        } else if (refundPolicy == POLICY_PRORATED_TIME) {
            return calculateProratedTimeRefund(
                _requestedAmount, timeSincePayment, fullRefundPeriod, partialRefundPeriod, maxRefundPercentBps
            );
        } else if (refundPolicy == POLICY_PRORATED_USAGE) {
            return calculateProratedUsageRefund(_requestedAmount, timeSincePayment, fullRefundPeriod, maxRefundPercentBps, state);
        } else if (refundPolicy == POLICY_TIERED) {
            return calculateTieredRefund(_requestedAmount, timeSincePayment, tieredRefundPercentages, tieredTimePeriods);
        } else if (refundPolicy == POLICY_NO_REFUND) {
            return 0;
        } else {
            revert("RefundEnforcer:invalid-refund-policy");
        }
    }

    /**
     * @notice Calculates refund amount for POLICY_FULL_REFUND
     * @param _requestedAmount The requested refund amount
     * @param _timeSincePayment Time since the last payment
     * @param _fullRefundPeriod The period during which full refunds are allowed
     * @return refundAmount The calculated refund amount
     */
    function calculateFullRefund(
        uint256 _requestedAmount,
        uint256 _timeSincePayment,
        uint256 _fullRefundPeriod
    )
        internal
        pure
        returns (uint256)
    {
        // Full refund if within full refund period, otherwise no refund
        if (_timeSincePayment <= _fullRefundPeriod) {
            return _requestedAmount;
        } else {
            return 0;
        }
    }

    /**
     * @notice Calculates refund amount for POLICY_PRORATED_TIME
     * @param _requestedAmount The requested refund amount
     * @param _timeSincePayment Time since the last payment
     * @param _fullRefundPeriod The period during which full refunds are allowed
     * @param _partialRefundPeriod The period during which partial refunds are allowed
     * @param _maxRefundPercentBps The maximum refund percentage in basis points
     * @return refundAmount The calculated refund amount
     */
    function calculateProratedTimeRefund(
        uint256 _requestedAmount,
        uint256 _timeSincePayment,
        uint256 _fullRefundPeriod,
        uint256 _partialRefundPeriod,
        uint256 _maxRefundPercentBps
    )
        internal
        pure
        returns (uint256)
    {
        // Full refund if within full refund period
        if (_timeSincePayment <= _fullRefundPeriod) {
            return _requestedAmount;
        }
        // Partial refund if within partial refund period
        else if (_timeSincePayment <= _fullRefundPeriod + _partialRefundPeriod) {
            // Calculate prorated refund based on time elapsed
            uint256 timeRemaining = _fullRefundPeriod + _partialRefundPeriod - _timeSincePayment;
            uint256 refundPercent = (timeRemaining * 10000) / _partialRefundPeriod;

            // Cap at maximum refund percentage
            if (refundPercent > _maxRefundPercentBps) {
                refundPercent = _maxRefundPercentBps;
            }

            return (_requestedAmount * refundPercent) / 10000;
        } else {
            return 0;
        }
    }

    /**
     * @notice Calculates refund amount for POLICY_PRORATED_USAGE
     * @param _requestedAmount The requested refund amount
     * @param _timeSincePayment Time since the last payment
     * @param _fullRefundPeriod The period during which full refunds are allowed
     * @param _maxRefundPercentBps The maximum refund percentage in basis points
     * @param _state The refund state for the delegation
     * @return refundAmount The calculated refund amount
     */
    function calculateProratedUsageRefund(
        uint256 _requestedAmount,
        uint256 _timeSincePayment,
        uint256 _fullRefundPeriod,
        uint256 _maxRefundPercentBps,
        RefundState storage _state
    )
        internal
        view
        returns (uint256)
    {
        // Calculate refund based on usage
        if (_timeSincePayment <= _fullRefundPeriod) {
            return _requestedAmount;
        } else {
            // Assume a baseline usage that would be expected for the subscription period
            uint256 expectedUsage = 10; // This could be parameterized in the terms

            // If usage is less than expected, provide a partial refund
            if (_state.usageCount < expectedUsage) {
                uint256 usagePercent = (_state.usageCount * 10000) / expectedUsage;
                uint256 refundPercent = 10000 - usagePercent;

                // Cap at maximum refund percentage
                if (refundPercent > _maxRefundPercentBps) {
                    refundPercent = _maxRefundPercentBps;
                }

                return (_requestedAmount * refundPercent) / 10000;
            } else {
                return 0;
            }
        }
    }

    /**
     * @notice Calculates refund amount for POLICY_TIERED
     * @param _requestedAmount The requested refund amount
     * @param _timeSincePayment Time since the last payment
     * @param _tieredRefundPercentages Array of refund percentages for each tier
     * @param _tieredTimePeriods Array of time periods for each tier
     * @return refundAmount The calculated refund amount
     */
    function calculateTieredRefund(
        uint256 _requestedAmount,
        uint256 _timeSincePayment,
        uint256[] memory _tieredRefundPercentages,
        uint256[] memory _tieredTimePeriods
    )
        internal
        pure
        returns (uint256)
    {
        // Tiered refund based on time periods
        require(_tieredRefundPercentages.length == _tieredTimePeriods.length, "RefundEnforcer:tiered-arrays-length-mismatch");

        // Find the applicable tier
        for (uint256 i = 0; i < _tieredTimePeriods.length; i++) {
            if (_timeSincePayment <= _tieredTimePeriods[i]) {
                return (_requestedAmount * _tieredRefundPercentages[i]) / 10000;
            }
        }

        return 0;
    }

    /**
     * @notice Enforces conditions before the execution tied to a specific delegation in the redemption process.
     * @dev This function will:
     *  1. Verify that the refund request is approved
     *  2. Calculate the refundable amount
     *  3. Verify that the execution value matches the refundable amount
     * @param _terms The terms to enforce set by the delegator
     * @param _args The refund request ID
     * @param _mode The execution mode
     * @param _executionCalldata The data representing the execution
     * @param _delegationHash The hash of the delegation
     * @param _delegator The address of the delegator
     * @param _redeemer The address that is redeeming the delegation
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata _args,
        ModeCode _mode,
        bytes calldata _executionCalldata,
        bytes32 _delegationHash,
        address _delegator,
        address _redeemer
    )
        public
        override
    {
        // Ensure the call type is a simple single call
        require(ModeLib.getCallType(_mode) == CALLTYPE_SINGLE, "RefundEnforcer:invalid-call-type");

        // Decode the refund request ID from args
        require(_args.length == 32, "RefundEnforcer:invalid-args-length");
        bytes32 refundRequestId = bytes32(_args[0:32]);

        // Get the refund request
        RefundRequest storage request = refundRequests[refundRequestId];

        // Ensure the refund request exists
        require(request.requestTime > 0, "RefundEnforcer:refund-request-not-found");

        // Ensure the refund request has not been processed
        require(!request.isProcessed, "RefundEnforcer:refund-already-processed");

        // Ensure the refund request is for the correct delegation
        require(request.delegationHash == _delegationHash, "RefundEnforcer:delegation-hash-mismatch");

        // Ensure the refund request is for the correct delegator
        require(request.delegator == _delegator, "RefundEnforcer:delegator-mismatch");

        // Ensure the refund request is approved
        require(approvedRefunds[refundRequestId], "RefundEnforcer:refund-not-approved");

        // Calculate the refundable amount
        uint256 refundableAmount = calculateRefundableAmount(_terms, _delegationHash, request.requestedAmount);

        // Ensure the refundable amount is greater than 0
        require(refundableAmount > 0, "RefundEnforcer:no-refundable-amount");

        // Decode the execution to verify the refund amount and recipient
        (address target, uint256 value, bytes memory callData) = ExecutionLib.decodeSingle(_executionCalldata);

        // Verify that the execution value matches the refundable amount
        require(value == refundableAmount, "RefundEnforcer:invalid-refund-amount");

        // Verify that the execution target matches the refund recipient
        require(target == request.refundRecipient, "RefundEnforcer:invalid-refund-recipient");

        // Verify that the execution calldata is empty (simple transfer)
        require(callData.length == 0, "RefundEnforcer:invalid-calldata");
    }

    /**
     * @notice Enforces conditions after the execution tied to a specific delegation in the redemption process.
     * @dev This function will:
     *  1. Mark the refund request as processed
     *  2. Update the refund state
     * @param _args The refund request ID
     * @param _executionCalldata The data representing the execution
     * @param _delegationHash The hash of the delegation
     * @param _delegator The address of the delegator
     * @param _redeemer The address that is redeeming the delegation
     */
    function afterHook(
        bytes calldata, // _terms (unused)
        bytes calldata _args,
        ModeCode, // _mode (unused)
        bytes calldata _executionCalldata,
        bytes32 _delegationHash,
        address _delegator,
        address _redeemer
    )
        public
        override
    {
        // Decode the refund request ID from args
        bytes32 refundRequestId = bytes32(_args[0:32]);

        // Get the refund request
        RefundRequest storage request = refundRequests[refundRequestId];

        // Get the refund state
        RefundState storage state = refundStates[_delegationHash];

        // Decode the execution to get the refund amount
        (, uint256 value,) = ExecutionLib.decodeSingle(_executionCalldata);

        // Mark the refund request as processed
        request.isProcessed = true;

        // Update the refund state
        state.totalRefundedAmount += value;
        state.lastRefundTime = block.timestamp;
        state.refundCount++;

        // Emit event
        emit RefundProcessed(refundRequestId, _delegationHash, _delegator, request.refundRecipient, value, block.timestamp);
    }

    /**
     * @notice Decodes the terms used in this enforcer
     * @dev The terms are encoded as:
     *  - bytes 0-31: Refund policy (1=full, 2=prorated-time, 3=prorated-usage, 4=tiered, 5=no-refund)
     *  - bytes 32-63: Full refund period (in seconds)
     *  - bytes 64-95: Partial refund period (in seconds)
     *  - bytes 96-127: Maximum refund percentage (in basis points, e.g., 5000 = 50%)
     *  - bytes 128-159: Maximum refunds per subscription
     *  - bytes 160-191: Minimum time between refunds (in seconds)
     *  - bytes 192-end: Tiered refund data (array of percentages followed by array of time periods)
     * @param _terms The encoded terms
     * @return refundPolicy The refund policy type
     * @return fullRefundPeriod The period during which full refunds are allowed (in seconds)
     * @return partialRefundPeriod The period during which partial refunds are allowed (in seconds)
     * @return maxRefundPercentBps The maximum refund percentage in basis points
     * @return maxRefundsPerSubscription The maximum number of refunds allowed per subscription
     * @return minTimeBetweenRefunds The minimum time required between refunds (in seconds)
     * @return tieredRefundPercentages Array of refund percentages for tiered policy
     * @return tieredTimePeriods Array of time periods for tiered policy
     */
    function getTermsInfo(bytes calldata _terms)
        public
        pure
        returns (
            uint8 refundPolicy,
            uint256 fullRefundPeriod,
            uint256 partialRefundPeriod,
            uint256 maxRefundPercentBps,
            uint256 maxRefundsPerSubscription,
            uint256 minTimeBetweenRefunds,
            uint256[] memory tieredRefundPercentages,
            uint256[] memory tieredTimePeriods
        )
    {
        // Ensure minimum terms length
        require(_terms.length >= 192, "RefundEnforcer:invalid-terms-length");

        // Decode the fixed terms
        refundPolicy = uint8(bytes1(_terms[31:32])); // Last byte of the first 32 bytes
        fullRefundPeriod = uint256(bytes32(_terms[32:64]));
        partialRefundPeriod = uint256(bytes32(_terms[64:96]));
        maxRefundPercentBps = uint256(bytes32(_terms[96:128]));
        maxRefundsPerSubscription = uint256(bytes32(_terms[128:160]));
        minTimeBetweenRefunds = uint256(bytes32(_terms[160:192]));

        // Validate the terms
        require(refundPolicy >= 1 && refundPolicy <= 5, "RefundEnforcer:invalid-refund-policy");
        require(maxRefundPercentBps <= 10000, "RefundEnforcer:invalid-max-refund-percent");
        require(maxRefundsPerSubscription > 0, "RefundEnforcer:invalid-max-refunds");

        // If using tiered policy, decode the tiered data
        if (refundPolicy == POLICY_TIERED) {
            // Ensure there's additional data for tiered policy
            require(_terms.length > 192, "RefundEnforcer:missing-tiered-data");

            // The remaining data should be two arrays: percentages and time periods
            bytes calldata tieredData = _terms[192:];

            // Decode the arrays
            (tieredRefundPercentages, tieredTimePeriods) = abi.decode(tieredData, (uint256[], uint256[]));

            // Validate the arrays
            require(tieredRefundPercentages.length > 0, "RefundEnforcer:empty-tiered-percentages");
            require(tieredRefundPercentages.length == tieredTimePeriods.length, "RefundEnforcer:tiered-arrays-length-mismatch");

            // Validate the percentages
            for (uint256 i = 0; i < tieredRefundPercentages.length; i++) {
                require(tieredRefundPercentages[i] <= 10000, "RefundEnforcer:invalid-tiered-percentage");
            }

            // Validate that time periods are in ascending order
            for (uint256 i = 1; i < tieredTimePeriods.length; i++) {
                require(tieredTimePeriods[i] > tieredTimePeriods[i - 1], "RefundEnforcer:invalid-tiered-time-periods");
            }
        } else {
            // Initialize empty arrays for non-tiered policies
            tieredRefundPercentages = new uint256[](0);
            tieredTimePeriods = new uint256[](0);
        }
    }
}
