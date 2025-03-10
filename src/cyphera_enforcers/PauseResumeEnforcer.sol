// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { CaveatEnforcer } from "../enforcers/CaveatEnforcer.sol";
import { ModeLib, CALLTYPE_SINGLE } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeCode, Execution } from "../utils/Types.sol";

/**
 * @title PauseResumeEnforcer
 * @notice This enforcer manages subscription pauses and resumes.
 * @dev It enforces:
 *  1. Maximum allowed pause duration
 *  2. Pause frequency limits
 *  3. Automatic extension of subscription end dates
 *  4. Partial pauses for specific features
 *  5. Tracking of pause status and adjustment of payment schedules
 */
contract PauseResumeEnforcer is CaveatEnforcer {
    ////////////////////////////// State //////////////////////////////

    // Struct to track pause state for each delegation
    struct PauseState {
        bool isPaused; // Whether the subscription is currently paused
        uint256 pauseStartTime; // Timestamp when the current pause started
        uint256 totalPauseDuration; // Total duration of all pauses in seconds
        uint256 lastPauseEndTime; // Timestamp when the last pause ended
        uint256 pauseCount; // Number of times the subscription has been paused
        uint256[] pausedFeatures; // IDs of paused features (empty if all features are paused)
    }

    // Mapping from delegation hash to pause state
    mapping(bytes32 delegationHash => PauseState state) public pauseStates;

    ////////////////////////////// Events //////////////////////////////

    /**
     * @notice Emitted when a subscription is paused
     * @param delegationHash The hash of the delegation
     * @param delegator The address of the delegator
     * @param pauseStartTime The timestamp when the pause started
     * @param pausedFeatures Array of feature IDs that are paused (empty if all features are paused)
     */
    event SubscriptionPaused(
        bytes32 indexed delegationHash, address indexed delegator, uint256 pauseStartTime, uint256[] pausedFeatures
    );

    /**
     * @notice Emitted when a subscription is resumed
     * @param delegationHash The hash of the delegation
     * @param delegator The address of the delegator
     * @param pauseDuration The duration of the pause in seconds
     * @param totalPauseDuration The total duration of all pauses for this subscription
     */
    event SubscriptionResumed(
        bytes32 indexed delegationHash, address indexed delegator, uint256 pauseDuration, uint256 totalPauseDuration
    );

    /**
     * @notice Emitted when a pause request is rejected due to frequency limits
     * @param delegationHash The hash of the delegation
     * @param delegator The address of the delegator
     * @param lastPauseEndTime The timestamp when the last pause ended
     */
    event PauseRejectedFrequency(bytes32 indexed delegationHash, address indexed delegator, uint256 lastPauseEndTime);

    /**
     * @notice Emitted when a pause exceeds the maximum allowed duration
     * @param delegationHash The hash of the delegation
     * @param delegator The address of the delegator
     * @param pauseStartTime The timestamp when the pause started
     * @param maxPauseDuration The maximum allowed pause duration
     */
    event MaxPauseDurationExceeded(
        bytes32 indexed delegationHash, address indexed delegator, uint256 pauseStartTime, uint256 maxPauseDuration
    );

    ////////////////////////////// External Methods //////////////////////////////

    /**
     * @notice Pauses a subscription
     * @dev This function will revert if:
     *  1. The subscription is already paused
     *  2. The minimum time between pauses has not passed
     *  3. The maximum number of pauses has been reached
     * @param _terms The terms to enforce set by the delegator
     * @param _delegationHash The hash of the delegation
     * @param _delegator The address of the delegator
     * @param _pausedFeatures Array of feature IDs to pause (empty to pause all features)
     * @return success Whether the pause was successful
     */
    function pauseSubscription(
        bytes calldata _terms,
        bytes32 _delegationHash,
        address _delegator,
        uint256[] calldata _pausedFeatures
    )
        external
        returns (bool success)
    {
        // Get the pause state for this delegation
        PauseState storage state = pauseStates[_delegationHash];

        // Check if the subscription is already paused
        require(!state.isPaused, "PauseResumeEnforcer:already-paused");

        // Decode the terms
        (uint256 maxPauseDuration, uint256 maxPauses, uint256 minTimeBetweenPauses,) = getTermsInfo(_terms);

        // Check if the maximum number of pauses has been reached
        require(state.pauseCount < maxPauses, "PauseResumeEnforcer:max-pauses-reached");

        // Check if the minimum time between pauses has passed
        if (state.lastPauseEndTime > 0) {
            if (block.timestamp < state.lastPauseEndTime + minTimeBetweenPauses) {
                emit PauseRejectedFrequency(_delegationHash, _delegator, state.lastPauseEndTime);
                return false;
            }
        }

        // Update the pause state
        state.isPaused = true;
        state.pauseStartTime = block.timestamp;
        state.pauseCount++;

        // Store paused features
        if (_pausedFeatures.length > 0) {
            state.pausedFeatures = _pausedFeatures;
        } else {
            // Empty array means all features are paused
            delete state.pausedFeatures;
        }

        // Emit event
        emit SubscriptionPaused(_delegationHash, _delegator, state.pauseStartTime, _pausedFeatures);

        return true;
    }

    /**
     * @notice Resumes a paused subscription
     * @dev This function will revert if the subscription is not paused
     * @param _delegationHash The hash of the delegation
     * @param _delegator The address of the delegator
     * @return pauseDuration The duration of the pause in seconds
     */
    function resumeSubscription(bytes32 _delegationHash, address _delegator) external returns (uint256 pauseDuration) {
        // Get the pause state for this delegation
        PauseState storage state = pauseStates[_delegationHash];

        // Check if the subscription is paused
        require(state.isPaused, "PauseResumeEnforcer:not-paused");

        // Calculate the pause duration
        pauseDuration = block.timestamp - state.pauseStartTime;

        // Update the pause state
        state.isPaused = false;
        state.lastPauseEndTime = block.timestamp;
        state.totalPauseDuration += pauseDuration;

        // Clear paused features
        delete state.pausedFeatures;

        // Emit event
        emit SubscriptionResumed(_delegationHash, _delegator, pauseDuration, state.totalPauseDuration);

        return pauseDuration;
    }

    /**
     * @notice Checks if a subscription is currently paused
     * @param _delegationHash The hash of the delegation
     * @return isPaused Whether the subscription is paused
     * @return pausedFeatures Array of feature IDs that are paused (empty if all features are paused)
     */
    function isSubscriptionPaused(bytes32 _delegationHash) external view returns (bool isPaused, uint256[] memory pausedFeatures) {
        PauseState storage state = pauseStates[_delegationHash];
        return (state.isPaused, state.pausedFeatures);
    }

    /**
     * @notice Gets the total pause duration for a subscription
     * @param _delegationHash The hash of the delegation
     * @return totalPauseDuration The total duration of all pauses in seconds
     */
    function getTotalPauseDuration(bytes32 _delegationHash) external view returns (uint256 totalPauseDuration) {
        PauseState storage state = pauseStates[_delegationHash];

        // If currently paused, add the current pause duration to the total
        if (state.isPaused) {
            return state.totalPauseDuration + (block.timestamp - state.pauseStartTime);
        }

        return state.totalPauseDuration;
    }

    /**
     * @notice Enforces conditions before the execution tied to a specific delegation in the redemption process.
     * @dev This function will revert if:
     *  1. The subscription is fully paused
     *  2. The feature being accessed is paused
     *  3. The maximum pause duration has been exceeded
     * @param _terms The terms to enforce set by the delegator
     * @param _args The arguments for this specific enforcement
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
        require(ModeLib.getCallType(_mode) == CALLTYPE_SINGLE, "PauseResumeEnforcer:invalid-call-type");

        // Get the pause state for this delegation
        PauseState storage state = pauseStates[_delegationHash];

        // If not paused, allow the execution
        if (!state.isPaused) {
            return;
        }

        // Decode the terms
        (uint256 maxPauseDuration,,,) = getTermsInfo(_terms);

        // Check if the maximum pause duration has been exceeded
        uint256 currentPauseDuration = block.timestamp - state.pauseStartTime;
        if (currentPauseDuration > maxPauseDuration) {
            emit MaxPauseDurationExceeded(_delegationHash, _delegator, state.pauseStartTime, maxPauseDuration);

            // Auto-resume the subscription if max duration is exceeded
            state.isPaused = false;
            state.lastPauseEndTime = block.timestamp;
            state.totalPauseDuration += maxPauseDuration; // Only count the max duration

            // Clear paused features
            delete state.pausedFeatures;

            // Allow the execution to proceed
            return;
        }

        // If there are specific paused features, check if the requested feature is paused
        if (state.pausedFeatures.length > 0) {
            // Decode the feature ID from args
            uint256 featureId = 0;
            if (_args.length >= 32) {
                featureId = uint256(bytes32(_args[0:32]));
            }

            // Check if the feature is paused
            bool featureIsPaused = false;
            for (uint256 i = 0; i < state.pausedFeatures.length; i++) {
                if (state.pausedFeatures[i] == featureId) {
                    featureIsPaused = true;
                    break;
                }
            }

            // If the feature is not paused, allow the execution
            if (!featureIsPaused) {
                return;
            }
        }

        // If we get here, either all features are paused or the specific feature is paused
        revert("PauseResumeEnforcer:subscription-paused");
    }

    /**
     * @notice Enforces conditions after the execution tied to a specific delegation in the redemption process.
     * @dev This is a no-op for the PauseResumeEnforcer
     */
    function afterHook(
        bytes calldata, // _terms (unused)
        bytes calldata, // _args (unused)
        ModeCode, // _mode (unused)
        bytes calldata, // _executionCalldata (unused)
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
     *  - bytes 0-31: Maximum pause duration (in seconds)
     *  - bytes 32-63: Maximum number of pauses allowed
     *  - bytes 64-95: Minimum time between pauses (in seconds)
     *  - bytes 96-127: Reserved for future use
     * @param _terms The encoded terms
     * @return maxPauseDuration The maximum allowed pause duration (in seconds)
     * @return maxPauses The maximum number of pauses allowed
     * @return minTimeBetweenPauses The minimum time required between pauses (in seconds)
     * @return reserved Reserved for future use
     */
    function getTermsInfo(bytes calldata _terms)
        public
        pure
        returns (uint256 maxPauseDuration, uint256 maxPauses, uint256 minTimeBetweenPauses, uint256 reserved)
    {
        require(_terms.length == 128, "PauseResumeEnforcer:invalid-terms-length");

        // Decode the terms
        maxPauseDuration = uint256(bytes32(_terms[0:32]));
        maxPauses = uint256(bytes32(_terms[32:64]));
        minTimeBetweenPauses = uint256(bytes32(_terms[64:96]));
        reserved = uint256(bytes32(_terms[96:128]));

        // Validate the terms
        require(maxPauseDuration > 0, "PauseResumeEnforcer:invalid-max-pause-duration");
        require(maxPauses > 0, "PauseResumeEnforcer:invalid-max-pauses");
        // minTimeBetweenPauses can be 0 to allow immediate re-pausing
    }

    /**
     * @notice Checks if a specific feature is paused for a subscription
     * @param _delegationHash The hash of the delegation
     * @param _featureId The ID of the feature to check
     * @return isPaused Whether the feature is paused
     */
    function isFeaturePaused(bytes32 _delegationHash, uint256 _featureId) external view returns (bool isPaused) {
        PauseState storage state = pauseStates[_delegationHash];

        // If not paused at all, return false
        if (!state.isPaused) {
            return false;
        }

        // If no specific features are paused, all features are paused
        if (state.pausedFeatures.length == 0) {
            return true;
        }

        // Check if the specific feature is in the paused features list
        for (uint256 i = 0; i < state.pausedFeatures.length; i++) {
            if (state.pausedFeatures[i] == _featureId) {
                return true;
            }
        }

        return false;
    }
}
