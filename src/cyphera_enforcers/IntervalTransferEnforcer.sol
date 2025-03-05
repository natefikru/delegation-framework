// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { CaveatEnforcer } from "../enforcers/CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { CALLTYPE_SINGLE } from "../utils/Constants.sol";

/**
 * @title Interval Transfer Enforcer Contract
 * @dev This contract extends the CaveatEnforcer contract. It provides functionality to enforce:
 * 1. A minimum time interval between transfers
 * 2. A maximum number of transfers
 * 3. Transfers can only be made to the delegate
 */
contract IntervalTransferEnforcer is CaveatEnforcer {
    ////////////////////////////// State //////////////////////////////

    // Tracks the last timestamp when a transfer was made for each delegation
    mapping(address delegationManager => mapping(bytes32 delegationHash => uint256 lastTransferTime)) public lastTransferTimes;

    // Tracks the number of transfers made for each delegation
    mapping(address delegationManager => mapping(bytes32 delegationHash => uint256 count)) public transferCounts;

    ////////////////////////////// Events //////////////////////////////

    event TransferExecuted(
        address indexed sender,
        address indexed redeemer,
        bytes32 indexed delegationHash,
        uint256 amount,
        uint256 transferCount,
        uint256 timestamp
    );

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Enforces conditions for interval-based transfers:
     * 1. Ensures minimum time interval between transfers
     * 2. Ensures maximum number of transfers is not exceeded
     * 3. Ensures transfers are only made to the delegate
     * @param _terms - Encoded terms containing interval, max transfers, and transfer amount
     * @param _delegationHash - The hash of the delegation being operated on
     * @param _redeemer - The address that is redeeming the delegation (must be the recipient)
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode _mode,
        bytes calldata _executionCalldata,
        bytes32 _delegationHash,
        address _delegator,
        address _redeemer
    )
        public
        override
    {
        // Ensure we're in single execution mode
        require(ModeLib.getCallType(_mode) == CALLTYPE_SINGLE, "IntervalTransferEnforcer:invalid-call-type");

        // Decode the terms
        (uint256 interval, uint256 maxTransfers, uint256 transferAmount) = getTermsInfo(_terms);

        // Check if max transfers has been reached
        uint256 currentCount = transferCounts[msg.sender][_delegationHash];
        require(currentCount < maxTransfers, "IntervalTransferEnforcer:max-transfers-reached");

        // Check if enough time has passed since the last transfer
        uint256 lastTransferTime = lastTransferTimes[msg.sender][_delegationHash];
        if (lastTransferTime > 0) {
            require(block.timestamp >= lastTransferTime + interval, "IntervalTransferEnforcer:interval-not-reached");
        }

        // Decode the execution data
        (address target, uint256 value, bytes memory callData) = ExecutionLib.decodeSingle(_executionCalldata);

        // Ensure this is a simple ETH transfer (empty calldata) with the correct amount
        require(callData.length == 0, "IntervalTransferEnforcer:not-eth-transfer");
        require(value == transferAmount, "IntervalTransferEnforcer:incorrect-transfer-amount");

        // Ensure the target is the delegate (redeemer)
        require(target == _redeemer, "IntervalTransferEnforcer:invalid-recipient");

        // Update state
        transferCounts[msg.sender][_delegationHash] = currentCount + 1;
        lastTransferTimes[msg.sender][_delegationHash] = block.timestamp;

        emit TransferExecuted(msg.sender, _redeemer, _delegationHash, transferAmount, currentCount + 1, block.timestamp);
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms encoded data that is used during the execution hooks.
     * @return interval The minimum time interval between transfers (in seconds)
     * @return maxTransfers The maximum number of transfers allowed
     * @return transferAmount The amount to transfer each time
     */
    function getTermsInfo(bytes calldata _terms)
        public
        pure
        returns (uint256 interval, uint256 maxTransfers, uint256 transferAmount)
    {
        require(_terms.length == 96, "IntervalTransferEnforcer:invalid-terms-length");

        // First 32 bytes: interval
        interval = uint256(bytes32(_terms[:32]));

        // Next 32 bytes: maxTransfers
        maxTransfers = uint256(bytes32(_terms[32:64]));

        // Last 32 bytes: transferAmount
        transferAmount = uint256(bytes32(_terms[64:96]));
    }
}
