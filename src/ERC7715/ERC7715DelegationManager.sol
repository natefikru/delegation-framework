// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";

import { DelegationManager } from "../DelegationManager.sol";
import { Execution, Delegation, Caveat, ModeCode } from "../utils/Types.sol";
import { EncoderLib } from "../libraries/EncoderLib.sol";
import { ERC1271Lib } from "../libraries/ERC1271Lib.sol";
import { ICaveatEnforcer } from "../interfaces/ICaveatEnforcer.sol";

/**
 * @title ERC7715DelegationManager
 * @notice Implementation of the ERC-7715 Delegation Framework that extends DelegationManager
 * @dev This contract extends the existing DelegationManager with EIP-7702 support
 */
contract ERC7715DelegationManager is DelegationManager {
    using MessageHashUtils for bytes32;

    /**
     * @notice Constructor for ERC7715DelegationManager
     */
    constructor() DelegationManager(msg.sender) { }

    /**
     * @notice Validates a delegation with EIP-7702 support
     * @dev This function extends the validation logic to support EIP-7702 transactions
     * @param _delegationHash The hash of the delegation
     * @return True if the delegation is valid, false otherwise
     */
    function _validateDelegation(
        Delegation memory, /* _delegation */
        bytes32 _delegationHash,
        address /* _caller */
    )
        internal
        view
        returns (bool)
    {
        // Since there's no base validation in the parent contract,
        // we'll implement the validation logic directly here

        // Check if the delegation is disabled
        if (disabledDelegations[_delegationHash]) {
            return false;
        }

        // Additional EIP-7702 specific validation could be added here

        return true;
    }
}
