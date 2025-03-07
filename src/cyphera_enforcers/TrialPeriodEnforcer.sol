// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { CaveatEnforcer } from "../enforcers/CaveatEnforcer.sol";
import { ModeLib, CALLTYPE_SINGLE } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeCode, Execution } from "../utils/Types.sol";

/**
 * @title TrialPeriodEnforcer
 * @notice This enforcer manages free trial periods before paid subscriptions begin.
 * @dev It enforces:
 *  1. Customizable trial durations (days, weeks, months)
 *  2. Usage limits during trial periods
 *  3. Automatic transition from trial to paid subscription
 *  4. Trial eligibility tracking to prevent abuse
 *  5. Payment collection after trial period ends
 */
contract TrialPeriodEnforcer is CaveatEnforcer {
    ////////////////////////////// State //////////////////////////////

    // Struct to track trial state for each delegation
    struct TrialState {
        bool isActive; // Whether the trial is currently active
        bool hasStarted; // Whether the trial has ever been started
        bool hasEnded; // Whether the trial has ended
        uint256 startTime; // Timestamp when the trial started
        uint256 usageCount; // Number of times the service has been used during trial
        uint256 paymentAmount; // Amount to be paid after trial ends
        bool isPaidSubscriptionActive; // Whether the paid subscription is active after trial
    }

    // Mapping from delegation hash to trial state
    mapping(bytes32 delegationHash => TrialState state) public trialStates;

    // Mapping to track if an address has used a trial before (to prevent abuse)
    mapping(address delegator => bool hasUsedTrial) public trialEligibility;

    ////////////////////////////// Events //////////////////////////////

    /**
     * @notice Emitted when a trial period starts
     * @param delegationHash The hash of the delegation
     * @param delegator The address of the delegator
     * @param startTime The timestamp when the trial started
     * @param trialDuration The duration of the trial in seconds
     */
    event TrialStarted(bytes32 indexed delegationHash, address indexed delegator, uint256 startTime, uint256 trialDuration);

    /**
     * @notice Emitted when a trial period ends
     * @param delegationHash The hash of the delegation
     * @param delegator The address of the delegator
     * @param endTime The timestamp when the trial ended
     * @param usageCount The number of times the service was used during the trial
     */
    event TrialEnded(bytes32 indexed delegationHash, address indexed delegator, uint256 endTime, uint256 usageCount);

    /**
     * @notice Emitted when a paid subscription begins after trial
     * @param delegationHash The hash of the delegation
     * @param delegator The address of the delegator
     * @param delegate The address of the delegate
     * @param paymentAmount The amount to be paid for the subscription
     */
    event PaidSubscriptionStarted(
        bytes32 indexed delegationHash, address indexed delegator, address indexed delegate, uint256 paymentAmount
    );

    /**
     * @notice Emitted when a trial is rejected due to previous usage
     * @param delegationHash The hash of the delegation
     * @param delegator The address of the delegator
     */
    event TrialRejected(bytes32 indexed delegationHash, address indexed delegator);

    /**
     * @notice Emitted when usage limit during trial is exceeded
     * @param delegationHash The hash of the delegation
     * @param delegator The address of the delegator
     * @param usageCount The current usage count
     * @param maxUsage The maximum allowed usage
     */
    event TrialUsageLimitExceeded(bytes32 indexed delegationHash, address indexed delegator, uint256 usageCount, uint256 maxUsage);

    ////////////////////////////// External Methods //////////////////////////////

    /**
     * @notice Starts a trial period for a subscription
     * @dev This function will revert if:
     *  1. The delegator has already used a trial
     *  2. The trial has already started for this delegation
     * @param _terms The terms to enforce set by the delegator
     * @param _delegationHash The hash of the delegation
     * @param _delegator The address of the delegator
     * @param _checkEligibility Whether to check if the delegator has used a trial before
     * @return success Whether the trial was successfully started
     */
    function startTrial(
        bytes calldata _terms,
        bytes32 _delegationHash,
        address _delegator,
        bool _checkEligibility
    )
        external
        returns (bool success)
    {
        // Get the trial state for this delegation
        TrialState storage state = trialStates[_delegationHash];

        // Check if the trial has already started
        require(!state.hasStarted, "TrialPeriodEnforcer:trial-already-started");

        // Check if the delegator is eligible for a trial (if required)
        if (_checkEligibility) {
            if (trialEligibility[_delegator]) {
                emit TrialRejected(_delegationHash, _delegator);
                return false;
            }
            // Mark the delegator as having used a trial
            trialEligibility[_delegator] = true;
        }

        // Decode the terms
        (uint256 trialDuration,, uint256 paymentAmount,) = getTermsInfo(_terms);

        // Update the trial state
        state.isActive = true;
        state.hasStarted = true;
        state.startTime = block.timestamp;
        state.usageCount = 0;
        state.paymentAmount = paymentAmount;
        state.isPaidSubscriptionActive = false;

        // Emit event
        emit TrialStarted(_delegationHash, _delegator, state.startTime, trialDuration);

        return true;
    }

    /**
     * @notice Ends a trial period and transitions to paid subscription
     * @dev This function will revert if the trial has not started or has already ended
     * @param _delegationHash The hash of the delegation
     * @param _delegator The address of the delegator
     * @param _delegate The address of the delegate
     * @return success Whether the trial was successfully ended
     */
    function endTrial(bytes32 _delegationHash, address _delegator, address _delegate) external returns (bool success) {
        // Get the trial state for this delegation
        TrialState storage state = trialStates[_delegationHash];

        // Check if the trial has started and is still active
        require(state.hasStarted, "TrialPeriodEnforcer:trial-not-started");
        require(state.isActive, "TrialPeriodEnforcer:trial-already-ended");

        // Update the trial state
        state.isActive = false;
        state.hasEnded = true;
        state.isPaidSubscriptionActive = true;

        // Emit events
        emit TrialEnded(_delegationHash, _delegator, block.timestamp, state.usageCount);
        emit PaidSubscriptionStarted(_delegationHash, _delegator, _delegate, state.paymentAmount);

        return true;
    }

    /**
     * @notice Checks if a trial is active for a delegation
     * @param _delegationHash The hash of the delegation
     * @return isActive Whether the trial is active
     * @return startTime The timestamp when the trial started
     * @return usageCount The number of times the service has been used during trial
     */
    function isTrialActive(bytes32 _delegationHash) external view returns (bool isActive, uint256 startTime, uint256 usageCount) {
        TrialState storage state = trialStates[_delegationHash];
        return (state.isActive, state.startTime, state.usageCount);
    }

    /**
     * @notice Checks if a paid subscription is active after trial
     * @param _delegationHash The hash of the delegation
     * @return isActive Whether the paid subscription is active
     * @return paymentAmount The amount to be paid for the subscription
     */
    function isPaidSubscriptionActive(bytes32 _delegationHash) external view returns (bool isActive, uint256 paymentAmount) {
        TrialState storage state = trialStates[_delegationHash];
        return (state.isPaidSubscriptionActive, state.paymentAmount);
    }

    /**
     * @notice Enforces conditions before the execution tied to a specific delegation in the redemption process.
     * @dev This function will:
     *  1. Check if the trial is active or if paid subscription is active
     *  2. Enforce usage limits during trial
     *  3. Auto-transition from trial to paid subscription if trial period has ended
     *  4. Verify payment amount for paid subscriptions
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
        require(ModeLib.getCallType(_mode) == CALLTYPE_SINGLE, "TrialPeriodEnforcer:invalid-call-type");

        // Get the trial state for this delegation
        TrialState storage state = trialStates[_delegationHash];

        // If trial hasn't started, start it automatically
        if (!state.hasStarted) {
            // Check if the delegator is eligible for a trial
            if (trialEligibility[_delegator]) {
                emit TrialRejected(_delegationHash, _delegator);
                revert("TrialPeriodEnforcer:delegator-not-eligible");
            }

            // Mark the delegator as having used a trial
            trialEligibility[_delegator] = true;

            // Decode the terms
            (uint256 initialTrialDuration,, uint256 initialPaymentAmount,) = getTermsInfo(_terms);

            // Update the trial state
            state.isActive = true;
            state.hasStarted = true;
            state.startTime = block.timestamp;
            state.usageCount = 0;
            state.paymentAmount = initialPaymentAmount;
            state.isPaidSubscriptionActive = false;

            // Emit event
            emit TrialStarted(_delegationHash, _delegator, state.startTime, initialTrialDuration);
        }

        // Decode the terms
        (uint256 trialDuration, uint256 maxUsage, uint256 paymentAmount,) = getTermsInfo(_terms);

        // Check if the trial period has ended but not yet marked as ended
        if (state.isActive && block.timestamp >= state.startTime + trialDuration) {
            // Auto-transition to paid subscription
            state.isActive = false;
            state.hasEnded = true;
            state.isPaidSubscriptionActive = true;

            // Emit events
            emit TrialEnded(_delegationHash, _delegator, block.timestamp, state.usageCount);
            emit PaidSubscriptionStarted(_delegationHash, _delegator, _redeemer, state.paymentAmount);
        }

        // If trial is active, check usage limits
        if (state.isActive) {
            // Check if usage limit is exceeded
            require(state.usageCount < maxUsage, "TrialPeriodEnforcer:usage-limit-exceeded");

            // Increment usage count
            state.usageCount++;
        }
        // If paid subscription is active, verify payment amount
        else if (state.isPaidSubscriptionActive) {
            // Decode the execution to verify the payment amount
            (, uint256 value,) = ExecutionLib.decodeSingle(_executionCalldata);
            require(value == paymentAmount, "TrialPeriodEnforcer:invalid-payment-amount");
        }
        // If neither trial nor paid subscription is active, revert
        else {
            revert("TrialPeriodEnforcer:no-active-subscription");
        }
    }

    /**
     * @notice Enforces conditions after the execution tied to a specific delegation in the redemption process.
     * @dev This is a no-op for the TrialPeriodEnforcer
     */
    function afterHook(
        bytes calldata, // _terms (unused)
        bytes calldata, // _args (unused)
        ModeCode, // _mode (unused)
        bytes calldata, // _executionCallData (unused)
        bytes32, // _delegationHash (unused)
        address, // _delegator (unused)
        address // _redeemer (unused)
    )
        public
        override
    {
        // No-op for this enforcer
    }

    /**
     * @notice Decodes the terms used in this enforcer
     * @dev The terms are encoded as:
     *  - bytes 0-31: Trial duration (in seconds)
     *  - bytes 32-63: Maximum usage during trial
     *  - bytes 64-95: Payment amount after trial (in wei)
     *  - bytes 96-127: Reserved for future use
     * @param _terms The encoded terms
     * @return trialDuration The duration of the trial in seconds
     * @return maxUsage The maximum number of times the service can be used during trial
     * @return paymentAmount The amount to be paid after trial (in wei)
     * @return reserved Reserved for future use
     */
    function getTermsInfo(bytes calldata _terms)
        public
        pure
        returns (uint256 trialDuration, uint256 maxUsage, uint256 paymentAmount, uint256 reserved)
    {
        require(_terms.length == 128, "TrialPeriodEnforcer:invalid-terms-length");

        // Decode the terms
        trialDuration = uint256(bytes32(_terms[0:32]));
        maxUsage = uint256(bytes32(_terms[32:64]));
        paymentAmount = uint256(bytes32(_terms[64:96]));
        reserved = uint256(bytes32(_terms[96:128]));

        // Validate the terms
        require(trialDuration > 0, "TrialPeriodEnforcer:invalid-trial-duration");
        require(maxUsage > 0, "TrialPeriodEnforcer:invalid-max-usage");
        require(paymentAmount > 0, "TrialPeriodEnforcer:invalid-payment-amount");
    }
}
