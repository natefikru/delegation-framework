// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

/**
 * @title IERC7715
 * @notice Interface for ERC-7715 Delegation Framework
 * @dev This interface defines the minimal interface for delegation frameworks
 */
interface IERC7715 {
    /**
     * @notice Represents a delegation from a delegator to a delegate
     * @param delegator The address of the delegator
     * @param delegate The address of the delegate
     * @param authority The authority of the delegation (e.g., root authority)
     * @param caveats Array of caveats that restrict the delegation
     * @param salt A unique value to prevent replay attacks
     * @param signature The signature of the delegator
     */
    struct Delegation {
        address delegator;
        address delegate;
        bytes32 authority;
        Caveat[] caveats;
        uint256 salt;
        bytes signature;
    }

    /**
     * @notice Represents a caveat that restricts a delegation
     * @param enforcer The address of the caveat enforcer contract
     * @param terms The terms of the caveat
     * @param args Additional arguments for the caveat
     */
    struct Caveat {
        address enforcer;
        bytes terms;
        bytes args;
    }

    /**
     * @notice Validates and executes a delegation
     * @param _permissionContexts Array of permission contexts (encoded delegations)
     * @param _modes Array of execution modes
     * @param _executionCallDatas Array of execution call data
     * @return Array of execution results
     */
    function redeemDelegations(
        bytes[] calldata _permissionContexts,
        bytes[] calldata _modes,
        bytes[] calldata _executionCallDatas
    )
        external
        returns (bytes[] memory);

    /**
     * @notice Disables a delegation
     * @param _delegation The delegation to disable
     */
    function disableDelegation(Delegation calldata _delegation) external;

    /**
     * @notice Enables a previously disabled delegation
     * @param _delegation The delegation to enable
     */
    function enableDelegation(Delegation calldata _delegation) external;

    /**
     * @notice Gets the domain hash for EIP-712 signatures
     * @return The domain hash
     */
    function getDomainHash() external view returns (bytes32);

    /**
     * @notice Checks if a delegation is disabled
     * @param _delegationHash The hash of the delegation
     * @return True if the delegation is disabled, false otherwise
     */
    function isDisabled(bytes32 _delegationHash) external view returns (bool);
}
