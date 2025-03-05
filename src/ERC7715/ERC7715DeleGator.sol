// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ModeLib, CallType, ExecType, ModeSelector, ModePayload } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";

import { ERC1271Lib } from "../libraries/ERC1271Lib.sol";
import { EIP7702DeleGatorCore } from "../EIP7702/EIP7702DeleGatorCore.sol";
import { IDelegationManager } from "../interfaces/IDelegationManager.sol";
import { IEntryPoint } from "@account-abstraction/interfaces/IEntryPoint.sol";
import { Execution, ModeCode } from "../utils/Types.sol";
import { CALLTYPE_SINGLE, CALLTYPE_BATCH, EXECTYPE_DEFAULT, EXECTYPE_TRY } from "../utils/Constants.sol";

/**
 * @title ERC7715 DeleGator Contract
 * @dev This contract extends the EIP7702DeleGatorCore contract. It provides functionality for ERC7715 based access control
 * and delegation.
 * @dev The signer that controls the DeleGator MUST be the ERC7715 EOA
 */
contract ERC7715DeleGator is EIP7702DeleGatorCore {
    ////////////////////////////// State //////////////////////////////

    /// @dev The name of the contract
    string public constant NAME = "ERC7715DeleGator";

    /// @dev The domain version
    string public constant DOMAIN_VERSION = "1";

    /// @dev The version of the contract
    string public constant VERSION = "1.0.0";

    /// @dev The length of a signature
    uint256 public constant SIGNATURE_LENGTH = 65;

    /// @dev The typehash for the execute function
    bytes32 public constant EXECUTE_TYPEHASH = keccak256("Execute(bytes mode,bytes executionCalldata,uint256 nonce)");

    ////////////////////////////// Events //////////////////////////////

    /// @dev Emitted when a delegation is executed
    event DelegationExecuted(address indexed delegator, address indexed delegate, bytes executionCallData);

    /// @dev Emitted when a try execute fails
    event DeleGatorExecutionFailed(address indexed target, bytes callData, bytes returnData);

    ////////////////////////////// Constructor //////////////////////////////

    /**
     * @notice Constructor
     * @param _delegationManager The address of the delegation manager
     * @param _entryPoint The address of the entry point
     */
    constructor(
        address _delegationManager,
        address _entryPoint
    )
        EIP7702DeleGatorCore(IDelegationManager(_delegationManager), IEntryPoint(_entryPoint), NAME, DOMAIN_VERSION)
    { }

    ////////////////////////////// External Methods //////////////////////////////

    /**
     * @notice Execute a transaction from the owner
     * @param _mode The mode of execution
     * @param _executionCallData The execution call data
     * @param _signature The signature of the owner
     * @return success Whether the execution was successful
     * @return result The result of the execution
     */
    function executeFromOwner(
        ModeCode _mode,
        bytes calldata _executionCallData,
        bytes calldata _signature
    )
        external
        payable
        returns (bool success, bytes memory result)
    {
        // Validate the signature
        _validateOwnerSignature(_mode, _executionCallData, _signature);

        // Decode the mode
        (CallType callType, ExecType execType,,) = ModeLib.decode(_mode);

        // Check if the call type is supported
        if (CallType.unwrap(callType) == CallType.unwrap(CALLTYPE_SINGLE)) {
            // Decode the execution call data
            (address target, uint256 value, bytes calldata callData) = ExecutionLib.decodeSingle(_executionCallData);

            // Check if the execution type is supported
            if (ExecType.unwrap(execType) == ExecType.unwrap(EXECTYPE_DEFAULT)) {
                // Execute the transaction
                result = _execute(target, value, callData);
                return (true, result);
            } else if (ExecType.unwrap(execType) == ExecType.unwrap(EXECTYPE_TRY)) {
                // Try to execute the transaction
                return _tryExecute(target, value, callData);
            } else {
                // Revert if the execution type is not supported
                revert UnsupportedExecType(execType);
            }
        } else if (CallType.unwrap(callType) == CallType.unwrap(CALLTYPE_BATCH)) {
            // Decode the execution call data
            Execution[] calldata executions = ExecutionLib.decodeBatch(_executionCallData);

            // Check if the execution type is supported
            if (ExecType.unwrap(execType) == ExecType.unwrap(EXECTYPE_DEFAULT)) {
                // Execute the batch transaction
                bytes[] memory results = _execute(executions);
                return (true, abi.encode(results));
            } else if (ExecType.unwrap(execType) == ExecType.unwrap(EXECTYPE_TRY)) {
                // Try to execute the batch transaction
                bytes[] memory results = _tryExecute(executions);
                return (true, abi.encode(results));
            } else {
                // Revert if the execution type is not supported
                revert UnsupportedExecType(execType);
            }
        } else {
            // Revert if the call type is not supported
            revert UnsupportedCallType(callType);
        }
    }

    /**
     * @inheritdoc IERC1271
     * @notice Verifies the signatures of the signers.
     * @dev Related: ERC4337, Delegation
     * @param _hash The hash of the data signed.
     * @param _signature The signatures of the signers.
     * @return magicValue_ A bytes4 magic value which is EIP1271_MAGIC_VALUE(0x1626ba7e) if the signature is valid, returns
     * SIG_VALIDATION_FAILED(0xffffffff) if there is a signature mismatch and reverts (for all other errors).
     */
    function isValidSignature(bytes32 _hash, bytes calldata _signature) external view override returns (bytes4 magicValue_) {
        return _isValidSignature(_hash, _signature);
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    /**
     * @notice Validate the owner's signature
     * @param _mode The mode of execution
     * @param _executionCallData The execution call data
     * @param _signature The signature of the owner
     */
    function _validateOwnerSignature(ModeCode _mode, bytes calldata _executionCallData, bytes calldata _signature) internal view {
        // Get the current nonce
        uint256 nonce = this.getNonce();

        // Create the hash to sign
        bytes32 structHash =
            keccak256(abi.encode(EXECUTE_TYPEHASH, keccak256(abi.encode(_mode)), keccak256(_executionCallData), nonce));

        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(NAME)),
                keccak256(bytes(VERSION)),
                block.chainid,
                address(this)
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        // Validate the signature
        address signer = ECDSA.recover(digest, _signature);

        // Check if the signer is the delegator address from the script
        require(signer == 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266, "Invalid signature");
    }

    /**
     * @notice Check if a signature is valid
     * @param _hash The hash to check
     * @param _signature The signature to check
     * @return magicValue The magic value if the signature is valid
     */
    function _isValidSignature(bytes32 _hash, bytes calldata _signature) internal view override returns (bytes4 magicValue) {
        if (_signature.length != SIGNATURE_LENGTH) {
            return ERC1271Lib.SIG_VALIDATION_FAILED;
        }

        address signer = ECDSA.recover(_hash, _signature);

        // Check if the signer is the delegator address (0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266)
        // or this contract address (for EIP7702)
        if (signer == 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 || signer == address(this)) {
            return ERC1271Lib.EIP1271_MAGIC_VALUE;
        }

        return ERC1271Lib.SIG_VALIDATION_FAILED;
    }
}
