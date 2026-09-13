// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockPonsV2FeeEscrow {
    using SafeERC20 for IERC20;

    mapping(address recipient => uint256 amount) public balanceOf;
    mapping(address recipient => mapping(address token => uint256 amount)) public balanceOfToken;

    function credit(address recipient) external payable {
        balanceOf[recipient] += msg.value;
    }

    function creditToken(address recipient, IERC20 token, uint256 amount) external {
        token.safeTransferFrom(msg.sender, address(this), amount);
        balanceOfToken[recipient][address(token)] += amount;
    }

    function claim() external returns (uint256 amount) {
        amount = _claimNative(msg.sender, balanceOf[msg.sender]);
    }

    function claim(uint256 amount) external returns (uint256) {
        return _claimNative(msg.sender, amount);
    }

    function claimToken(address token) external returns (uint256 amount) {
        amount = _claimToken(msg.sender, IERC20(token), balanceOfToken[msg.sender][token]);
    }

    function claimToken(address token, uint256 amount) external returns (uint256) {
        return _claimToken(msg.sender, IERC20(token), amount);
    }

    function _claimNative(address recipient, uint256 amount) private returns (uint256) {
        require(balanceOf[recipient] >= amount, "insufficient native credit");
        balanceOf[recipient] -= amount;
        (bool success,) = payable(recipient).call{value: amount}("");
        require(success, "native claim failed");
        return amount;
    }

    function _claimToken(address recipient, IERC20 token, uint256 amount) private returns (uint256) {
        require(balanceOfToken[recipient][address(token)] >= amount, "insufficient token credit");
        balanceOfToken[recipient][address(token)] -= amount;
        token.safeTransfer(recipient, amount);
        return amount;
    }
}
