// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title HelloWorld
 * @notice A simple contract that demonstrates delegation capabilities
 * @dev This contract is owned by a DeleGator wallet and can be interacted with through delegation
 */
contract HelloWorld is Ownable {
    ////////////////////////////// State //////////////////////////////

    string public message = "Hello World";
    uint256 public counter = 0;

    ////////////////////////////// Events //////////////////////////////

    event MessageUpdated(address indexed caller, string newMessage);
    event CounterIncremented(address indexed caller, uint256 newCount);

    ////////////////////////////// Constructor //////////////////////////////

    constructor(address _initialOwner) Ownable(_initialOwner) { }

    ////////////////////////////// External Methods //////////////////////////////

    /**
     * @notice Updates the stored message
     * @param _newMessage The new message to store
     * @dev Only the owner can call this function
     */
    function updateMessage(string memory _newMessage) public onlyOwner {
        message = _newMessage;
        emit MessageUpdated(msg.sender, _newMessage);
    }

    /**
     * @notice Increments the counter
     * @dev Only the owner can call this function
     */
    function incrementCounter() public onlyOwner {
        counter++;
        emit CounterIncremented(msg.sender, counter);
    }

    /**
     * @notice Gets the current message and counter
     * @return The current message and counter value
     */
    function getStatus() public view returns (string memory, uint256) {
        return (message, counter);
    }

    /**
     * @notice A function that will always revert
     * @dev Used for testing error handling in delegations
     */
    function willRevert() public pure {
        revert("This function always reverts");
    }
}
