// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract MockPonsV2CreatorControls {
    address public lastCaller;
    address public lastToken;
    address public lastRecipient;
    bool public lastBuybackEnabled;

    function transferCreatorFeeRecipient(address token, address newRecipient) external {
        lastCaller = msg.sender;
        lastToken = token;
        lastRecipient = newRecipient;
    }

    function setBuybackEnabled(address token, bool enabled) external {
        lastCaller = msg.sender;
        lastToken = token;
        lastBuybackEnabled = enabled;
    }
}
