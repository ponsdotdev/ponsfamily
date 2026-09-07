// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    bool public failTransfers;

    constructor() ERC20("Mock Token", "MOCK") {}

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }

    function setFailTransfers(bool failTransfers_) external {
        failTransfers = failTransfers_;
    }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        if (failTransfers) return false;
        return super.transfer(recipient, amount);
    }

    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        if (failTransfers) return false;
        return super.transferFrom(sender, recipient, amount);
    }
}
