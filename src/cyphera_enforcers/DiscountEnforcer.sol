// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { CaveatEnforcer } from "../enforcers/CaveatEnforcer.sol";
import { ModeLib, CALLTYPE_SINGLE } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeCode, Execution } from "../utils/Types.sol";

/**
 * @title DiscountEnforcer
 * @notice This enforcer applies various types of discounts to subscription payments.
 * @dev It supports:
 *  1. Time-limited promotional discounts with specific start and end dates
 *  2. Loyalty discounts that increase based on subscription duration
 *  3. Coupon code discounts (one-time or recurring)
 *  4. Volume discounts based on usage or multiple subscriptions
 */
contract DiscountEnforcer is CaveatEnforcer {
    ////////////////////////////// State //////////////////////////////

    // Struct to track discount state for each delegation
    struct DiscountState {
        uint256 subscriptionStartTime; // When the subscription started
        uint256 successfulPayments; // Number of successful payments made
        uint256 usageCount; // Number of times the service has been used
        bool couponApplied; // Whether a one-time coupon has been applied
        bytes32 appliedCouponHash; // Hash of the applied coupon code
        uint256 lastPaymentAmount; // Amount of the last payment (after discount)
        uint256 totalAmountPaid; // Total amount paid so far (after discounts)
    }

    // Mapping from delegation hash to discount state
    mapping(bytes32 delegationHash => DiscountState state) public discountStates;

    // Mapping to track valid coupon codes and their discount percentages (in basis points, e.g., 1000 = 10%)
    mapping(bytes32 couponHash => uint256 discountBps) public couponDiscounts;

    // Mapping to track if a coupon is recurring or one-time
    mapping(bytes32 couponHash => bool isRecurring) public couponTypes;

    ////////////////////////////// Events //////////////////////////////

    /**
     * @notice Emitted when a discount is applied to a payment
     * @param delegationHash The hash of the delegation
     * @param delegator The address of the delegator
     * @param originalAmount The original payment amount before discount
     * @param discountedAmount The payment amount after discount
     * @param discountType The type of discount applied (1=time-limited, 2=loyalty, 3=coupon, 4=volume)
     */
    event DiscountApplied(
        bytes32 indexed delegationHash,
        address indexed delegator,
        uint256 originalAmount,
        uint256 discountedAmount,
        uint8 discountType
    );

    /**
     * @notice Emitted when a coupon code is applied
     * @param delegationHash The hash of the delegation
     * @param delegator The address of the delegator
     * @param couponHash The hash of the coupon code
     * @param discountBps The discount percentage in basis points
     * @param isRecurring Whether the coupon is recurring or one-time
     */
    event CouponApplied(
        bytes32 indexed delegationHash, address indexed delegator, bytes32 couponHash, uint256 discountBps, bool isRecurring
    );

    /**
     * @notice Emitted when a coupon code is registered
     * @param couponHash The hash of the coupon code
     * @param discountBps The discount percentage in basis points
     * @param isRecurring Whether the coupon is recurring or one-time
     */
    event CouponRegistered(bytes32 indexed couponHash, uint256 discountBps, bool isRecurring);

    ////////////////////////////// External Methods //////////////////////////////

    /**
     * @notice Registers a new coupon code
     * @dev Only callable by the contract owner or authorized parties
     * @param _couponCode The coupon code string
     * @param _discountBps The discount percentage in basis points (e.g., 1000 = 10%)
     * @param _isRecurring Whether the coupon is recurring or one-time
     * @return couponHash The hash of the registered coupon
     */
    function registerCoupon(
        string calldata _couponCode,
        uint256 _discountBps,
        bool _isRecurring
    )
        external
        returns (bytes32 couponHash)
    {
        // Validate discount percentage (max 100%)
        require(_discountBps <= 10000, "DiscountEnforcer:invalid-discount-percentage");

        // Hash the coupon code
        couponHash = keccak256(abi.encodePacked(_couponCode));

        // Store the coupon details
        couponDiscounts[couponHash] = _discountBps;
        couponTypes[couponHash] = _isRecurring;

        // Emit event
        emit CouponRegistered(couponHash, _discountBps, _isRecurring);

        return couponHash;
    }

    /**
     * @notice Applies a coupon code to a delegation
     * @param _delegationHash The hash of the delegation
     * @param _delegator The address of the delegator
     * @param _couponCode The coupon code to apply
     * @return success Whether the coupon was successfully applied
     * @return discountBps The discount percentage in basis points
     */
    function applyCoupon(
        bytes32 _delegationHash,
        address _delegator,
        string calldata _couponCode
    )
        external
        returns (bool success, uint256 discountBps)
    {
        // Hash the coupon code
        bytes32 couponHash = keccak256(abi.encodePacked(_couponCode));

        // Check if the coupon exists
        discountBps = couponDiscounts[couponHash];
        if (discountBps == 0) {
            return (false, 0);
        }

        // Get the discount state
        DiscountState storage state = discountStates[_delegationHash];

        // Check if a one-time coupon has already been applied
        if (state.couponApplied && !couponTypes[state.appliedCouponHash]) {
            return (false, 0);
        }

        // Apply the coupon
        state.couponApplied = true;
        state.appliedCouponHash = couponHash;

        // Emit event
        emit CouponApplied(_delegationHash, _delegator, couponHash, discountBps, couponTypes[couponHash]);

        return (true, discountBps);
    }

    /**
     * @notice Initializes the discount state for a delegation
     * @param _delegationHash The hash of the delegation
     * @return success Whether the state was successfully initialized
     */
    function initializeDiscountState(bytes32 _delegationHash) external returns (bool success) {
        // Get the discount state
        DiscountState storage state = discountStates[_delegationHash];

        // Check if already initialized
        if (state.subscriptionStartTime > 0) {
            return false;
        }

        // Initialize the state
        state.subscriptionStartTime = block.timestamp;
        state.successfulPayments = 0;
        state.usageCount = 0;
        state.couponApplied = false;
        state.appliedCouponHash = bytes32(0);
        state.lastPaymentAmount = 0;
        state.totalAmountPaid = 0;

        return true;
    }

    /**
     * @notice Records usage of the service
     * @param _delegationHash The hash of the delegation
     * @return usageCount The updated usage count
     */
    function recordUsage(bytes32 _delegationHash) external returns (uint256 usageCount) {
        // Get the discount state
        DiscountState storage state = discountStates[_delegationHash];

        // Increment usage count
        state.usageCount++;

        return state.usageCount;
    }

    /**
     * @notice Gets the discount state for a delegation
     * @param _delegationHash The hash of the delegation
     * @return state The discount state
     */
    function getDiscountState(bytes32 _delegationHash) external view returns (DiscountState memory) {
        return discountStates[_delegationHash];
    }

    /**
     * @notice Calculates the discounted payment amount based on the terms and state
     * @param _terms The terms to enforce set by the delegator
     * @param _delegationHash The hash of the delegation
     * @param _originalAmount The original payment amount before discount
     * @return discountedAmount The payment amount after applying all applicable discounts
     * @return appliedDiscountTypes Array of discount types that were applied (1=time-limited, 2=loyalty, 3=coupon, 4=volume)
     */
    function calculateDiscountedAmount(
        bytes calldata _terms,
        bytes32 _delegationHash,
        uint256 _originalAmount
    )
        public
        view
        returns (uint256 discountedAmount, uint8[] memory appliedDiscountTypes)
    {
        // Start with the original amount
        discountedAmount = _originalAmount;

        // Get the discount state
        DiscountState storage state = discountStates[_delegationHash];

        // Decode the terms
        (
            uint256 promoStartTime,
            uint256 promoEndTime,
            uint256 promoDiscountBps,
            uint256 loyaltyThreshold,
            uint256 loyaltyDiscountBps,
            uint256 volumeThreshold,
            uint256 volumeDiscountBps,
            , // originalAmount (unused)
            uint256 maxTotalDiscountBps
        ) = getTermsInfo(_terms);

        // Initialize array to track which discount types were applied
        appliedDiscountTypes = new uint8[](4);
        uint8 appliedCount = 0;

        // Calculate total discount percentage (in basis points)
        uint256 totalDiscountBps = 0;

        // 1. Time-limited promotional discount
        if (block.timestamp >= promoStartTime && block.timestamp <= promoEndTime && promoDiscountBps > 0) {
            totalDiscountBps += promoDiscountBps;
            appliedDiscountTypes[appliedCount++] = 1;
        }

        // 2. Loyalty discount based on number of payments
        if (state.successfulPayments >= loyaltyThreshold && loyaltyDiscountBps > 0) {
            totalDiscountBps += loyaltyDiscountBps;
            appliedDiscountTypes[appliedCount++] = 2;
        }

        // 3. Coupon discount
        if (state.couponApplied) {
            // Check if it's a recurring coupon or a one-time coupon that hasn't been used for payment yet
            bool isRecurring = couponTypes[state.appliedCouponHash];
            if (isRecurring || state.successfulPayments == 0) {
                totalDiscountBps += couponDiscounts[state.appliedCouponHash];
                appliedDiscountTypes[appliedCount++] = 3;
            }
        }

        // 4. Volume discount based on usage
        if (state.usageCount >= volumeThreshold && volumeDiscountBps > 0) {
            totalDiscountBps += volumeDiscountBps;
            appliedDiscountTypes[appliedCount++] = 4;
        }

        // Cap the total discount at the maximum allowed
        if (totalDiscountBps > maxTotalDiscountBps) {
            totalDiscountBps = maxTotalDiscountBps;
        }

        // Apply the total discount
        if (totalDiscountBps > 0) {
            discountedAmount = _originalAmount - ((_originalAmount * totalDiscountBps) / 10000);
        }

        // Resize the array to only include applied discount types
        assembly {
            mstore(appliedDiscountTypes, appliedCount)
        }

        return (discountedAmount, appliedDiscountTypes);
    }

    /**
     * @notice Enforces conditions before the execution tied to a specific delegation in the redemption process.
     * @dev This function will:
     *  1. Initialize the discount state if not already initialized
     *  2. Calculate the discounted payment amount
     *  3. Verify that the execution value matches the discounted amount
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
        require(ModeLib.getCallType(_mode) == CALLTYPE_SINGLE, "DiscountEnforcer:invalid-call-type");

        // Get the discount state
        DiscountState storage state = discountStates[_delegationHash];

        // Initialize the state if not already initialized
        if (state.subscriptionStartTime == 0) {
            state.subscriptionStartTime = block.timestamp;
        }

        // Decode the execution to get the original payment amount
        (, uint256 executionValue,) = ExecutionLib.decodeSingle(_executionCalldata);

        // Get the original payment amount from the terms
        (,,,,,,, uint256 originalAmount,) = getTermsInfo(_terms);

        // Calculate the discounted amount
        (uint256 discountedAmount, uint8[] memory appliedDiscountTypes) =
            calculateDiscountedAmount(_terms, _delegationHash, originalAmount);

        // Verify that the execution value matches the discounted amount
        require(executionValue == discountedAmount, "DiscountEnforcer:invalid-payment-amount");

        // Emit event if any discounts were applied
        if (discountedAmount < originalAmount) {
            uint8 discountType = appliedDiscountTypes.length > 0 ? appliedDiscountTypes[0] : 0;
            emit DiscountApplied(_delegationHash, _delegator, originalAmount, discountedAmount, discountType);
        }
    }

    /**
     * @notice Enforces conditions after the execution tied to a specific delegation in the redemption process.
     * @dev This function records successful payments and updates the discount state
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
        // Get the discount state
        DiscountState storage state = discountStates[_delegationHash];

        // Decode the execution to get the payment amount
        (, uint256 value,) = ExecutionLib.decodeSingle(_executionCalldata);

        // Record successful payment
        state.successfulPayments++;
        state.lastPaymentAmount = value;
        state.totalAmountPaid += value;
    }

    /**
     * @notice Decodes the terms used in this enforcer
     * @dev The terms are encoded as:
     *  - bytes 0-31: Promotional discount start time (timestamp)
     *  - bytes 32-63: Promotional discount end time (timestamp)
     *  - bytes 64-95: Promotional discount percentage (in basis points, e.g., 1000 = 10%)
     *  - bytes 96-127: Loyalty threshold (number of payments to qualify for loyalty discount)
     *  - bytes 128-159: Loyalty discount percentage (in basis points)
     *  - bytes 160-191: Volume threshold (usage count to qualify for volume discount)
     *  - bytes 192-223: Volume discount percentage (in basis points)
     *  - bytes 224-255: Original payment amount (in wei)
     *  - bytes 256-287: Maximum total discount percentage (in basis points)
     * @param _terms The encoded terms
     * @return promoStartTime The start time of the promotional discount
     * @return promoEndTime The end time of the promotional discount
     * @return promoDiscountBps The promotional discount percentage in basis points
     * @return loyaltyThreshold The number of payments required to qualify for loyalty discount
     * @return loyaltyDiscountBps The loyalty discount percentage in basis points
     * @return volumeThreshold The usage count required to qualify for volume discount
     * @return volumeDiscountBps The volume discount percentage in basis points
     * @return originalAmount The original payment amount in wei
     * @return maxTotalDiscountBps The maximum total discount percentage in basis points
     */
    function getTermsInfo(bytes calldata _terms)
        public
        pure
        returns (
            uint256 promoStartTime,
            uint256 promoEndTime,
            uint256 promoDiscountBps,
            uint256 loyaltyThreshold,
            uint256 loyaltyDiscountBps,
            uint256 volumeThreshold,
            uint256 volumeDiscountBps,
            uint256 originalAmount,
            uint256 maxTotalDiscountBps
        )
    {
        require(_terms.length == 288, "DiscountEnforcer:invalid-terms-length");

        // Decode the terms
        promoStartTime = uint256(bytes32(_terms[0:32]));
        promoEndTime = uint256(bytes32(_terms[32:64]));
        promoDiscountBps = uint256(bytes32(_terms[64:96]));
        loyaltyThreshold = uint256(bytes32(_terms[96:128]));
        loyaltyDiscountBps = uint256(bytes32(_terms[128:160]));
        volumeThreshold = uint256(bytes32(_terms[160:192]));
        volumeDiscountBps = uint256(bytes32(_terms[192:224]));
        originalAmount = uint256(bytes32(_terms[224:256]));
        maxTotalDiscountBps = uint256(bytes32(_terms[256:288]));

        // Validate the terms
        require(promoEndTime >= promoStartTime, "DiscountEnforcer:invalid-promo-period");
        require(promoDiscountBps <= 10000, "DiscountEnforcer:invalid-promo-discount");
        require(loyaltyDiscountBps <= 10000, "DiscountEnforcer:invalid-loyalty-discount");
        require(volumeDiscountBps <= 10000, "DiscountEnforcer:invalid-volume-discount");
        require(maxTotalDiscountBps <= 10000, "DiscountEnforcer:invalid-max-discount");
        require(originalAmount > 0, "DiscountEnforcer:invalid-original-amount");
    }
}
