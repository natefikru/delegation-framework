// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { CaveatEnforcer } from "../enforcers/CaveatEnforcer.sol";
import { ModeLib, CALLTYPE_SINGLE } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeCode, Execution } from "../utils/Types.sol";

/**
 * @title ProrationEnforcer
 * @notice This enforcer handles partial billing periods for subscription services.
 * @dev It enforces:
 *  1. Calculation of prorated payment amounts for mid-cycle changes
 *  2. Tracking of billing cycles and subscription changes
 *  3. Adjustment of payment amounts based on usage duration
 *  4. Support for upgrades, downgrades, and cancellations
 *  5. Alignment of billing dates with calendar periods
 */
contract ProrationEnforcer is CaveatEnforcer {
    ////////////////////////////// State //////////////////////////////

    // Struct to track subscription state for each delegation
    struct SubscriptionState {
        uint256 cycleStartTime; // Timestamp when the current billing cycle started
        uint256 cycleEndTime; // Timestamp when the current billing cycle ends
        uint256 fullCycleAmount; // Full payment amount for a complete billing cycle
        uint256 lastChangeTime; // Timestamp when the subscription was last changed
        uint256 paidAmount; // Amount already paid in the current cycle
        bool isActive; // Whether the subscription is currently active
        bool isInitialized; // Whether the subscription has been initialized
    }

    // Mapping from delegation hash to subscription state
    mapping(bytes32 delegationHash => SubscriptionState state) public subscriptionStates;

    ////////////////////////////// Events //////////////////////////////

    /**
     * @notice Emitted when a subscription is initialized
     * @param delegationHash The hash of the delegation
     * @param delegator The address of the delegator
     * @param cycleStartTime The timestamp when the billing cycle starts
     * @param cycleEndTime The timestamp when the billing cycle ends
     * @param fullCycleAmount The full payment amount for a complete billing cycle
     */
    event SubscriptionInitialized(
        bytes32 indexed delegationHash,
        address indexed delegator,
        uint256 cycleStartTime,
        uint256 cycleEndTime,
        uint256 fullCycleAmount
    );

    /**
     * @notice Emitted when a prorated payment is calculated
     * @param delegationHash The hash of the delegation
     * @param delegator The address of the delegator
     * @param proratedAmount The calculated prorated amount
     * @param usageFraction The fraction of the billing cycle used (in basis points, 10000 = 100%)
     */
    event ProratedPaymentCalculated(
        bytes32 indexed delegationHash, address indexed delegator, uint256 proratedAmount, uint256 usageFraction
    );

    /**
     * @notice Emitted when a subscription is changed mid-cycle
     * @param delegationHash The hash of the delegation
     * @param delegator The address of the delegator
     * @param oldAmount The previous full cycle amount
     * @param newAmount The new full cycle amount
     * @param changeTime The timestamp when the change occurred
     */
    event SubscriptionChanged(
        bytes32 indexed delegationHash, address indexed delegator, uint256 oldAmount, uint256 newAmount, uint256 changeTime
    );

    /**
     * @notice Emitted when a billing cycle is completed
     * @param delegationHash The hash of the delegation
     * @param delegator The address of the delegator
     * @param cycleStartTime The timestamp when the completed cycle started
     * @param cycleEndTime The timestamp when the completed cycle ended
     * @param paidAmount The total amount paid in the completed cycle
     */
    event BillingCycleCompleted(
        bytes32 indexed delegationHash, address indexed delegator, uint256 cycleStartTime, uint256 cycleEndTime, uint256 paidAmount
    );

    ////////////////////////////// External Methods //////////////////////////////

    /**
     * @notice Initializes a subscription with billing cycle information
     * @dev This function will revert if the subscription is already initialized
     * @param _terms The terms to enforce set by the delegator
     * @param _delegationHash The hash of the delegation
     * @param _delegator The address of the delegator
     * @return success Whether the initialization was successful
     */
    function initializeSubscription(
        bytes calldata _terms,
        bytes32 _delegationHash,
        address _delegator
    )
        external
        returns (bool success)
    {
        // Get the subscription state for this delegation
        SubscriptionState storage state = subscriptionStates[_delegationHash];

        // Check if the subscription is already initialized
        require(!state.isInitialized, "ProrationEnforcer:already-initialized");

        // Decode the terms
        (uint256 cycleLength, uint256 fullCycleAmount,,) = getTermsInfo(_terms);

        // Initialize the subscription state
        state.cycleStartTime = block.timestamp;
        state.cycleEndTime = block.timestamp + cycleLength;
        state.fullCycleAmount = fullCycleAmount;
        state.lastChangeTime = block.timestamp;
        state.paidAmount = 0;
        state.isActive = true;
        state.isInitialized = true;

        // Emit event
        emit SubscriptionInitialized(_delegationHash, _delegator, state.cycleStartTime, state.cycleEndTime, state.fullCycleAmount);

        return true;
    }

    /**
     * @notice Changes a subscription's terms mid-cycle
     * @dev This function handles upgrades, downgrades, and other changes
     * @param _terms The new terms to enforce
     * @param _delegationHash The hash of the delegation
     * @param _delegator The address of the delegator
     * @param _newFullCycleAmount The new full cycle amount
     * @return proratedRefundAmount Any refund amount due (for downgrades)
     */
    function changeSubscription(
        bytes calldata _terms,
        bytes32 _delegationHash,
        address _delegator,
        uint256 _newFullCycleAmount
    )
        external
        returns (uint256 proratedRefundAmount)
    {
        // Get the subscription state for this delegation
        SubscriptionState storage state = subscriptionStates[_delegationHash];

        // Check if the subscription is initialized and active
        require(state.isInitialized, "ProrationEnforcer:not-initialized");
        require(state.isActive, "ProrationEnforcer:not-active");

        // Store the old amount for event emission
        uint256 oldAmount = state.fullCycleAmount;

        // Calculate the prorated amount already used in this cycle
        uint256 timeUsed = block.timestamp - state.cycleStartTime;
        uint256 totalCycleTime = state.cycleEndTime - state.cycleStartTime;

        // Calculate the fraction of the cycle used (in basis points, 10000 = 100%)
        uint256 usageFraction = (timeUsed * 10000) / totalCycleTime;

        // Calculate the prorated value of what has been used
        uint256 proratedUsedValue = (state.fullCycleAmount * usageFraction) / 10000;

        // If downgrading (new amount is less than old amount), calculate potential refund
        if (_newFullCycleAmount < state.fullCycleAmount && state.paidAmount > proratedUsedValue) {
            proratedRefundAmount = state.paidAmount - proratedUsedValue;
        } else {
            proratedRefundAmount = 0;
        }

        // Update the subscription state
        state.fullCycleAmount = _newFullCycleAmount;
        state.lastChangeTime = block.timestamp;

        // Emit event
        emit SubscriptionChanged(_delegationHash, _delegator, oldAmount, _newFullCycleAmount, block.timestamp);

        return proratedRefundAmount;
    }

    /**
     * @notice Calculates the prorated payment amount for the current state of the subscription
     * @param _delegationHash The hash of the delegation
     * @param _delegator The address of the delegator
     * @return proratedAmount The calculated prorated amount
     * @return usageFraction The fraction of the billing cycle used (in basis points, 10000 = 100%)
     */
    function calculateProratedAmount(
        bytes32 _delegationHash,
        address _delegator
    )
        external
        returns (uint256 proratedAmount, uint256 usageFraction)
    {
        // Get the subscription state for this delegation
        SubscriptionState storage state = subscriptionStates[_delegationHash];

        // Check if the subscription is initialized and active
        require(state.isInitialized, "ProrationEnforcer:not-initialized");
        require(state.isActive, "ProrationEnforcer:not-active");

        // If we're at the start of a cycle, return the full amount
        if (block.timestamp <= state.cycleStartTime) {
            emit ProratedPaymentCalculated(_delegationHash, _delegator, state.fullCycleAmount, 10000);
            return (state.fullCycleAmount, 10000);
        }

        // If we're at or past the end of a cycle, start a new cycle
        if (block.timestamp >= state.cycleEndTime) {
            // Complete the current cycle
            emit BillingCycleCompleted(_delegationHash, _delegator, state.cycleStartTime, state.cycleEndTime, state.paidAmount);

            // Calculate the duration of a cycle
            uint256 cycleDuration = state.cycleEndTime - state.cycleStartTime;

            // Start a new cycle
            state.cycleStartTime = state.cycleEndTime;
            state.cycleEndTime = state.cycleStartTime + cycleDuration;
            state.paidAmount = 0;

            emit ProratedPaymentCalculated(_delegationHash, _delegator, state.fullCycleAmount, 10000);
            return (state.fullCycleAmount, 10000);
        }

        // We're in the middle of a cycle, calculate prorated amount
        uint256 timeRemaining = state.cycleEndTime - block.timestamp;
        uint256 totalCycleTime = state.cycleEndTime - state.cycleStartTime;

        // Calculate the fraction of the cycle remaining (in basis points, 10000 = 100%)
        usageFraction = (timeRemaining * 10000) / totalCycleTime;

        // Calculate the prorated amount
        proratedAmount = (state.fullCycleAmount * usageFraction) / 10000;

        // Ensure we don't charge more than what's remaining to be paid in this cycle
        uint256 remainingToPay = state.fullCycleAmount > state.paidAmount ? state.fullCycleAmount - state.paidAmount : 0;
        if (proratedAmount > remainingToPay) {
            proratedAmount = remainingToPay;
        }

        emit ProratedPaymentCalculated(_delegationHash, _delegator, proratedAmount, usageFraction);
        return (proratedAmount, usageFraction);
    }

    /**
     * @notice Completes the current billing cycle and starts a new one
     * @param _delegationHash The hash of the delegation
     * @param _delegator The address of the delegator
     * @return newCycleStartTime The start time of the new cycle
     * @return newCycleEndTime The end time of the new cycle
     */
    function completeBillingCycle(
        bytes32 _delegationHash,
        address _delegator
    )
        external
        returns (uint256 newCycleStartTime, uint256 newCycleEndTime)
    {
        // Get the subscription state for this delegation
        SubscriptionState storage state = subscriptionStates[_delegationHash];

        // Check if the subscription is initialized and active
        require(state.isInitialized, "ProrationEnforcer:not-initialized");
        require(state.isActive, "ProrationEnforcer:not-active");

        // Complete the current cycle
        emit BillingCycleCompleted(_delegationHash, _delegator, state.cycleStartTime, state.cycleEndTime, state.paidAmount);

        // Calculate the duration of a cycle
        uint256 cycleDuration = state.cycleEndTime - state.cycleStartTime;

        // Start a new cycle
        state.cycleStartTime = block.timestamp;
        state.cycleEndTime = state.cycleStartTime + cycleDuration;
        state.paidAmount = 0;

        return (state.cycleStartTime, state.cycleEndTime);
    }

    /**
     * @notice Enforces conditions before the execution tied to a specific delegation in the redemption process.
     * @dev This function will:
     *  1. Initialize the subscription if not already initialized
     *  2. Calculate the prorated payment amount based on the current state
     *  3. Verify that the payment amount matches the calculated prorated amount
     * @param _terms The terms to enforce set by the delegator
     * @param _mode The execution mode
     * @param _executionCalldata The data representing the execution
     * @param _delegationHash The hash of the delegation
     * @param _delegator The address of the delegator
     * @param _redeemer The address that is redeeming the delegation
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata, // _args (unused)
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
        require(ModeLib.getCallType(_mode) == CALLTYPE_SINGLE, "ProrationEnforcer:invalid-call-type");

        // Get the subscription state for this delegation
        SubscriptionState storage state = subscriptionStates[_delegationHash];

        // If not initialized, initialize the subscription
        if (!state.isInitialized) {
            // Decode the terms
            (uint256 cycleLength, uint256 fullCycleAmount,,) = getTermsInfo(_terms);

            // Initialize the subscription state
            state.cycleStartTime = block.timestamp;
            state.cycleEndTime = block.timestamp + cycleLength;
            state.fullCycleAmount = fullCycleAmount;
            state.lastChangeTime = block.timestamp;
            state.paidAmount = 0;
            state.isActive = true;
            state.isInitialized = true;

            // Emit event
            emit SubscriptionInitialized(
                _delegationHash, _delegator, state.cycleStartTime, state.cycleEndTime, state.fullCycleAmount
            );
        }

        // Check if the subscription is active
        require(state.isActive, "ProrationEnforcer:not-active");

        // Calculate the prorated amount
        uint256 proratedAmount;
        uint256 usageFraction;

        // If we're at the start of a cycle, use the full amount
        if (block.timestamp <= state.cycleStartTime) {
            proratedAmount = state.fullCycleAmount;
            usageFraction = 10000; // 100%
        }
        // If we're at or past the end of a cycle, start a new cycle
        else if (block.timestamp >= state.cycleEndTime) {
            // Complete the current cycle
            emit BillingCycleCompleted(_delegationHash, _delegator, state.cycleStartTime, state.cycleEndTime, state.paidAmount);

            // Calculate the duration of a cycle
            uint256 cycleDuration = state.cycleEndTime - state.cycleStartTime;

            // Start a new cycle
            state.cycleStartTime = state.cycleEndTime;
            state.cycleEndTime = state.cycleStartTime + cycleDuration;
            state.paidAmount = 0;

            proratedAmount = state.fullCycleAmount;
            usageFraction = 10000; // 100%
        }
        // We're in the middle of a cycle, calculate prorated amount
        else {
            uint256 timeRemaining = state.cycleEndTime - block.timestamp;
            uint256 totalCycleTime = state.cycleEndTime - state.cycleStartTime;

            // Calculate the fraction of the cycle remaining (in basis points, 10000 = 100%)
            usageFraction = (timeRemaining * 10000) / totalCycleTime;

            // Calculate the prorated amount
            proratedAmount = (state.fullCycleAmount * usageFraction) / 10000;

            // Ensure we don't charge more than what's remaining to be paid in this cycle
            uint256 remainingToPay = state.fullCycleAmount > state.paidAmount ? state.fullCycleAmount - state.paidAmount : 0;
            if (proratedAmount > remainingToPay) {
                proratedAmount = remainingToPay;
            }
        }

        // Emit the calculated prorated amount
        emit ProratedPaymentCalculated(_delegationHash, _delegator, proratedAmount, usageFraction);

        // Decode the execution to verify the payment amount
        (, uint256 value,) = ExecutionLib.decodeSingle(_executionCalldata);

        // Allow a small tolerance (1%) for rounding errors
        uint256 tolerance = proratedAmount / 100;
        require(
            value >= proratedAmount - tolerance && value <= proratedAmount + tolerance, "ProrationEnforcer:invalid-payment-amount"
        );
    }

    /**
     * @notice Enforces conditions after the execution tied to a specific delegation in the redemption process.
     * @dev This function records the payment and updates the subscription state
     * @param _executionCalldata The data representing the execution
     * @param _delegationHash The hash of the delegation
     * @param _delegator The address of the delegator
     * @param _redeemer The address that is redeeming the delegation
     */
    function afterHook(
        bytes calldata, // _terms (unused)
        bytes calldata, // _args (unused)
        ModeCode, // _mode (unused)
        bytes calldata _executionCalldata,
        bytes32 _delegationHash,
        address _delegator,
        address _redeemer
    )
        public
        override
    {
        // Get the subscription state for this delegation
        SubscriptionState storage state = subscriptionStates[_delegationHash];

        // Decode the execution to get the payment amount
        (, uint256 value,) = ExecutionLib.decodeSingle(_executionCalldata);

        // Record the payment
        state.paidAmount += value;

        // If we've paid the full amount for this cycle, check if we need to start a new cycle
        if (state.paidAmount >= state.fullCycleAmount && block.timestamp >= state.cycleEndTime) {
            // Complete the current cycle
            emit BillingCycleCompleted(_delegationHash, _delegator, state.cycleStartTime, state.cycleEndTime, state.paidAmount);

            // Calculate the duration of a cycle
            uint256 cycleDuration = state.cycleEndTime - state.cycleStartTime;

            // Start a new cycle
            state.cycleStartTime = state.cycleEndTime;
            state.cycleEndTime = state.cycleStartTime + cycleDuration;
            state.paidAmount = 0;
        }
    }

    /**
     * @notice Decodes the terms used in this enforcer
     * @dev The terms are encoded as:
     *  - bytes 0-31: Cycle length (in seconds)
     *  - bytes 32-63: Full cycle payment amount (in wei)
     *  - bytes 64-95: Alignment day (0-31, 0 means no alignment)
     *  - bytes 96-127: Reserved for future use
     * @param _terms The encoded terms
     * @return cycleLength The length of a billing cycle in seconds
     * @return fullCycleAmount The full payment amount for a complete billing cycle
     * @return alignmentDay The day of the month to align billing cycles with (0-31, 0 means no alignment)
     * @return reserved Reserved for future use
     */
    function getTermsInfo(bytes calldata _terms)
        public
        pure
        returns (uint256 cycleLength, uint256 fullCycleAmount, uint256 alignmentDay, uint256 reserved)
    {
        require(_terms.length == 128, "ProrationEnforcer:invalid-terms-length");

        // Decode the terms
        cycleLength = uint256(bytes32(_terms[0:32]));
        fullCycleAmount = uint256(bytes32(_terms[32:64]));
        alignmentDay = uint256(bytes32(_terms[64:96]));
        reserved = uint256(bytes32(_terms[96:128]));

        // Validate the terms
        require(cycleLength > 0, "ProrationEnforcer:invalid-cycle-length");
        require(fullCycleAmount > 0, "ProrationEnforcer:invalid-full-cycle-amount");
        require(alignmentDay <= 31, "ProrationEnforcer:invalid-alignment-day");
    }

    /**
     * @notice Gets the current subscription state
     * @param _delegationHash The hash of the delegation
     * @return isActive Whether the subscription is active
     * @return cycleStartTime The timestamp when the current billing cycle started
     * @return cycleEndTime The timestamp when the current billing cycle ends
     * @return fullCycleAmount The full payment amount for a complete billing cycle
     * @return paidAmount The amount already paid in the current cycle
     */
    function getSubscriptionState(bytes32 _delegationHash)
        external
        view
        returns (bool isActive, uint256 cycleStartTime, uint256 cycleEndTime, uint256 fullCycleAmount, uint256 paidAmount)
    {
        SubscriptionState storage state = subscriptionStates[_delegationHash];
        return (state.isActive, state.cycleStartTime, state.cycleEndTime, state.fullCycleAmount, state.paidAmount);
    }

    /**
     * @notice Deactivates a subscription
     * @param _delegationHash The hash of the delegation
     * @param _delegator The address of the delegator
     * @return refundAmount The calculated refund amount for unused portion
     */
    function deactivateSubscription(bytes32 _delegationHash, address _delegator) external returns (uint256 refundAmount) {
        // Get the subscription state for this delegation
        SubscriptionState storage state = subscriptionStates[_delegationHash];

        // Check if the subscription is initialized and active
        require(state.isInitialized, "ProrationEnforcer:not-initialized");
        require(state.isActive, "ProrationEnforcer:not-active");

        // Calculate the prorated amount already used in this cycle
        uint256 timeUsed = block.timestamp - state.cycleStartTime;
        uint256 totalCycleTime = state.cycleEndTime - state.cycleStartTime;

        // Calculate the fraction of the cycle used (in basis points, 10000 = 100%)
        uint256 usageFraction = (timeUsed * 10000) / totalCycleTime;

        // Calculate the prorated value of what has been used
        uint256 proratedUsedValue = (state.fullCycleAmount * usageFraction) / 10000;

        // Calculate refund if applicable
        if (state.paidAmount > proratedUsedValue) {
            refundAmount = state.paidAmount - proratedUsedValue;
        } else {
            refundAmount = 0;
        }

        // Deactivate the subscription
        state.isActive = false;

        // Complete the current cycle
        emit BillingCycleCompleted(_delegationHash, _delegator, state.cycleStartTime, state.cycleEndTime, state.paidAmount);

        return refundAmount;
    }
}
