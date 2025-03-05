// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { BasePaymaster } from "@account-abstraction/core/BasePaymaster.sol";
import { IEntryPoint } from "@account-abstraction/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "@account-abstraction/interfaces/PackedUserOperation.sol";
import { UserOperationLib } from "@account-abstraction/core/UserOperationLib.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title VerifyingPaymaster
 * @notice A paymaster that uses an external signer to validate user operations
 * @dev This paymaster validates signatures from a trusted signer to authorize gas sponsorship
 */
contract VerifyingPaymaster is BasePaymaster {
    using UserOperationLib for PackedUserOperation;
    using ECDSA for bytes32;

    /// @notice The address of the signer that validates operations
    address public immutable verifyingSigner;

    /// @notice The hash used for signing paymaster data
    bytes32 private constant PAYMASTER_VALIDATION_GAS_HASH =
        keccak256("PaymasterValidation(address paymaster,address sender,uint256 validUntil,uint256 validAfter)");

    /// @notice Error thrown when the signature is invalid
    error InvalidPaymasterSignature();

    /// @notice Error thrown when the operation is outside the valid time range
    error OperationOutsideTimeRange();

    /// @notice Error thrown when the paymaster data is invalid
    error InvalidPaymasterData();

    /**
     * @notice Constructor for the VerifyingPaymaster
     * @param _entryPoint The EntryPoint contract that will call this paymaster
     * @param _verifyingSigner The address of the signer that validates operations
     */
    constructor(IEntryPoint _entryPoint, address _verifyingSigner) BasePaymaster(_entryPoint) {
        require(_verifyingSigner != address(0), "VerifyingPaymaster: signer cannot be zero address");
        verifyingSigner = _verifyingSigner;
    }

    /**
     * @notice Returns the hash to be signed by the verifying signer
     * @param _userOp The user operation to validate
     * @param _validUntil The timestamp until which the signature is valid
     * @param _validAfter The timestamp after which the signature is valid
     * @return The hash to be signed
     */
    function getHash(
        PackedUserOperation calldata _userOp,
        uint256 _validUntil,
        uint256 _validAfter
    )
        public
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(PAYMASTER_VALIDATION_GAS_HASH, address(this), _userOp.sender, _validUntil, _validAfter));
    }

    /**
     * @notice Validate a user operation and agree to pay for it
     * @dev Verifies the signature from the verifying signer and checks time bounds
     * @param _userOp The user operation to validate
     * @param _userOpHash The hash of the user operation
     * @param _maxCost The maximum cost of the transaction
     * @return context Context containing the time bounds for postOp validation
     * @return validationData Packed validation data with time bounds
     */
    function _validatePaymasterUserOp(
        PackedUserOperation calldata _userOp,
        bytes32 _userOpHash,
        uint256 _maxCost
    )
        internal
        override
        returns (bytes memory context, uint256 validationData)
    {
        // Make sure we have enough deposit to pay for the transaction
        require(_maxCost <= entryPoint.balanceOf(address(this)), "VerifyingPaymaster: insufficient deposit for gas fees");

        // Parse the paymaster data to extract time bounds and signature
        (uint256 validUntil, uint256 validAfter, bytes memory signature) = parsePaymasterAndData(_userOp.paymasterAndData);

        // Verify the signature
        bytes32 hash = getHash(_userOp, validUntil, validAfter);
        if (ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(hash), signature) != verifyingSigner) {
            revert InvalidPaymasterSignature();
        }

        // Check if the current time is within the valid range
        if (block.timestamp > validUntil) {
            revert OperationOutsideTimeRange();
        }
        if (block.timestamp < validAfter) {
            revert OperationOutsideTimeRange();
        }

        // Return the time bounds as context for postOp
        context = abi.encode(validUntil, validAfter);

        // Pack the validation data with time bounds
        // validationData format:
        // - First bit (MSB) = 0 (valid signature)
        // - Next 160 bits = validUntil timestamp
        // - Last 95 bits = validAfter timestamp
        validationData = (validUntil << 160) | validAfter;

        return (context, validationData);
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

    /**
     * @notice Parse the paymaster and data field to extract time bounds and signature
     * @param _paymasterAndData The paymaster and data field from the user operation
     * @return validUntil The timestamp until which the signature is valid
     * @return validAfter The timestamp after which the signature is valid
     * @return signature The signature from the verifying signer
     */
    function parsePaymasterAndData(bytes calldata _paymasterAndData)
        public
        pure
        returns (uint256 validUntil, uint256 validAfter, bytes memory signature)
    {
        // Paymaster data format: paymaster address (20 bytes) + validUntil (32 bytes) + validAfter (32 bytes) + signature (65+
        // bytes)
        if (_paymasterAndData.length < 20 + 32 + 32 + 65) {
            revert InvalidPaymasterData();
        }

        // Extract the time bounds and signature
        validUntil = uint256(bytes32(_paymasterAndData[20:52]));
        validAfter = uint256(bytes32(_paymasterAndData[52:84]));
        signature = _paymasterAndData[84:];

        return (validUntil, validAfter, signature);
    }
}
