// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockFeeOnTransferERC20 is ERC20 {
    constructor() ERC20("Fee-on-transfer Token", "FEE") {}

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = amount / 10;
            if (fee != 0) super._update(from, address(0), fee);
            super._update(from, to, amount - fee);
            return;
        }

        super._update(from, to, amount);
    }
}
