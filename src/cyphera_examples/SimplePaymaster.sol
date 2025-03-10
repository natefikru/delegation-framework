// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { BasePaymaster } from "@account-abstraction/core/BasePaymaster.sol";
import { IEntryPoint } from "@account-abstraction/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "@account-abstraction/interfaces/PackedUserOperation.sol";
import { UserOperationLib } from "@account-abstraction/core/UserOperationLib.sol";

/**
 * @title SimplePaymaster
 * @notice A simple paymaster that sponsors gas fees for any transaction
 * @dev This paymaster accepts any transaction without validation
 */
contract SimplePaymaster is BasePaymaster {
    using UserOperationLib for PackedUserOperation;

    /**
     * @notice Constructor for the SimplePaymaster
     * @param _entryPoint The EntryPoint contract that will call this paymaster
     */
    constructor(IEntryPoint _entryPoint) BasePaymaster(_entryPoint) { }

    /**
     * @notice Validate a user operation and agree to pay for it
     * @dev This implementation accepts any transaction without validation
     * @param userOp The user operation to validate
     * @param userOpHash The hash of the user operation
     * @param maxCost The maximum cost of the transaction
     * @return context Empty context as we don't need to pass any data to postOp
     * @return validationData Always returns 0 (valid until indefinite, valid after 0)
     */
    function _validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    )
        internal
        override
        returns (bytes memory context, uint256 validationData)
    {
        // Accept any transaction without validation
        // In a real implementation, you would add validation logic here

        // Make sure we have enough deposit to pay for the transaction
        require(maxCost <= entryPoint.balanceOf(address(this)), "SimplePaymaster: insufficient deposit for gas fees");

        // Return empty context and validationData = 0 (valid signature, no time range)
        return ("", 0);
    }

    /**
     * @notice Post-operation handler
     * @dev This implementation does nothing in postOp
     */
    function _postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    )
        internal
        override
    {
        // This paymaster doesn't do anything in postOp
        // In a real implementation, you might want to perform accounting or other operations
    }
}
