// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { CaveatEnforcer } from "../enforcers/CaveatEnforcer.sol";
import { ModeLib, CALLTYPE_SINGLE } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeCode, Execution } from "../utils/Types.sol";

/**
 * @title RecurringPaymentEnforcer
 * @notice This enforcer manages recurring payments with dunning functionality.
 * @dev It enforces:
 *  1. A minimum time interval between payment attempts
 *  2. A maximum number of payments allowed
 *  3. Dunning (retry) logic for failed payments
 *  4. Subscription nullification after exceeding maximum dunning attempts
 */
contract RecurringPaymentEnforcer is CaveatEnforcer {
    ////////////////////////////// State //////////////////////////////

    // Struct to track payment state for each delegation
    struct PaymentState {
        uint256 lastAttemptTime; // Timestamp of the last payment attempt
        uint256 successfulPayments; // Number of successful payments
        uint256 currentDunningAttempts; // Current number of dunning attempts for the latest payment
        bool isNullified; // Whether the subscription is nullified
    }

    // Mapping from delegation hash to payment state
    mapping(bytes32 delegationHash => PaymentState state) public paymentStates;

    ////////////////////////////// Events //////////////////////////////

    /**
     * @notice Emitted when a payment is successfully executed
     * @param delegationHash The hash of the delegation
     * @param delegator The address of the delegator
     * @param delegate The address of the delegate
     * @param amount The amount transferred
     * @param paymentNumber The sequential number of this payment
     */
    event PaymentSuccessful(
        bytes32 indexed delegationHash, address indexed delegator, address indexed delegate, uint256 amount, uint256 paymentNumber
    );

    /**
     * @notice Emitted when a payment fails
     * @param delegationHash The hash of the delegation
     * @param delegator The address of the delegator
     * @param delegate The address of the delegate
     * @param amount The amount attempted
     * @param dunningAttempt The current dunning attempt number
     */
    event PaymentFailed(
        bytes32 indexed delegationHash, address indexed delegator, address indexed delegate, uint256 amount, uint256 dunningAttempt
    );

    /**
     * @notice Emitted when a dunning attempt is initiated
     * @param delegationHash The hash of the delegation
     * @param delegator The address of the delegator
     * @param delegate The address of the delegate
     * @param dunningAttempt The current dunning attempt number
     */
    event DunningAttemptInitiated(
        bytes32 indexed delegationHash, address indexed delegator, address indexed delegate, uint256 dunningAttempt
    );

    /**
     * @notice Emitted when a subscription is nullified due to exceeding max dunning attempts
     * @param delegationHash The hash of the delegation
     * @param delegator The address of the delegator
     * @param delegate The address of the delegate
     */
    event SubscriptionNullified(bytes32 indexed delegationHash, address indexed delegator, address indexed delegate);

    ////////////////////////////// External Methods //////////////////////////////

    /**
     * @notice Enforces conditions before the execution tied to a specific delegation in the redemption process.
     * @dev This function will revert if:
     *  1. The subscription is nullified
     *  2. The minimum interval between payments has not passed
     *  3. The maximum number of payments has been reached
     * @param _terms The terms to enforce set by the delegator
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
        require(ModeLib.getCallType(_mode) == CALLTYPE_SINGLE, "RecurringPaymentEnforcer:invalid-call-type");

        // Get the payment state for this delegation
        PaymentState storage state = paymentStates[_delegationHash];

        // Check if the subscription is nullified
        require(!state.isNullified, "RecurringPaymentEnforcer:subscription-nullified");

        // Decode the terms
        (uint256 interval, uint256 maxPayments, uint256 paymentAmount,) = getTermsInfo(_terms);

        // Check if the maximum number of payments has been reached
        require(state.successfulPayments < maxPayments, "RecurringPaymentEnforcer:max-payments-reached");

        // Check if the minimum interval has passed since the last attempt
        // Skip this check for dunning attempts
        if (state.currentDunningAttempts == 0) {
            require(
                state.lastAttemptTime == 0 || block.timestamp >= state.lastAttemptTime + interval,
                "RecurringPaymentEnforcer:interval-not-passed"
            );
        } else {
            // This is a dunning attempt
            emit DunningAttemptInitiated(_delegationHash, _delegator, _redeemer, state.currentDunningAttempts);
        }

        // Decode the execution to verify the payment amount
        (, uint256 value,) = ExecutionLib.decodeSingle(_executionCalldata);
        require(value == paymentAmount, "RecurringPaymentEnforcer:invalid-payment-amount");

        // Update the last attempt time
        state.lastAttemptTime = block.timestamp;
    }

    /**
     * @notice Enforces conditions after the execution tied to a specific delegation in the redemption process.
     * @dev This function records successful payments and resets dunning attempts
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
        // Get the payment state for this delegation
        PaymentState storage state = paymentStates[_delegationHash];

        // Decode the execution to get the payment amount
        (, uint256 value,) = ExecutionLib.decodeSingle(_executionCalldata);

        // Record successful payment
        state.successfulPayments++;

        // Reset dunning attempts after successful payment
        state.currentDunningAttempts = 0;

        // Emit event for successful payment
        emit PaymentSuccessful(_delegationHash, _delegator, _redeemer, value, state.successfulPayments);
    }

    /**
     * @notice Records a payment failure and manages dunning attempts
     * @dev This function should be called when a payment fails
     * @param _terms The terms to enforce set by the delegator
     * @param _delegationHash The hash of the delegation
     * @param _delegator The address of the delegator
     * @param _redeemer The address that is redeeming the delegation
     * @param _executionCalldata The data representing the execution
     * @return Whether the subscription has been nullified
     */
    function recordPaymentFailure(
        bytes calldata _terms,
        bytes32 _delegationHash,
        address _delegator,
        address _redeemer,
        bytes calldata _executionCalldata
    )
        external
        returns (bool)
    {
        // Get the payment state for this delegation
        PaymentState storage state = paymentStates[_delegationHash];

        // Decode the terms
        (,,, uint256 maxDunningAttempts) = getTermsInfo(_terms);

        // Decode the execution to get the payment amount
        (, uint256 value,) = ExecutionLib.decodeSingle(_executionCalldata);

        // Increment dunning attempts
        state.currentDunningAttempts++;

        // Emit payment failed event
        emit PaymentFailed(_delegationHash, _delegator, _redeemer, value, state.currentDunningAttempts);

        // Check if max dunning attempts have been reached
        if (state.currentDunningAttempts > maxDunningAttempts) {
            // Nullify the subscription
            state.isNullified = true;

            // Emit subscription nullified event
            emit SubscriptionNullified(_delegationHash, _delegator, _redeemer);

            return true;
        }

        return false;
    }

    /**
     * @notice Decodes the terms used in this enforcer
     * @dev The terms are encoded as:
     *  - bytes 0-31: Interval between payments (in seconds)
     *  - bytes 32-63: Maximum number of payments allowed
     *  - bytes 64-95: Payment amount (in wei)
     *  - bytes 96-127: Maximum dunning attempts before nullification
     * @param _terms The encoded terms
     * @return interval The interval between payments (in seconds)
     * @return maxPayments The maximum number of payments allowed
     * @return paymentAmount The payment amount (in wei)
     * @return maxDunningAttempts The maximum dunning attempts before nullification
     */
    function getTermsInfo(bytes calldata _terms)
        public
        pure
        returns (uint256 interval, uint256 maxPayments, uint256 paymentAmount, uint256 maxDunningAttempts)
    {
        require(_terms.length == 128, "RecurringPaymentEnforcer:invalid-terms-length");

        // Decode the terms
        interval = uint256(bytes32(_terms[0:32]));
        maxPayments = uint256(bytes32(_terms[32:64]));
        paymentAmount = uint256(bytes32(_terms[64:96]));
        maxDunningAttempts = uint256(bytes32(_terms[96:128]));

        // Validate the terms
        require(interval > 0, "RecurringPaymentEnforcer:invalid-interval");
        require(maxPayments > 0, "RecurringPaymentEnforcer:invalid-max-payments");
        require(paymentAmount > 0, "RecurringPaymentEnforcer:invalid-payment-amount");
        require(maxDunningAttempts > 0, "RecurringPaymentEnforcer:invalid-max-dunning-attempts");
    }
}
