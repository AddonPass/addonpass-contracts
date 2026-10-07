// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract MockUSDC is ERC20, ERC20Permit {
    bool public transferFromShouldFail;

    constructor() ERC20("USD Coin", "USDC") ERC20Permit("USD Coin") { }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }

    function setTransferFromShouldFail(bool shouldFail) external {
        transferFromShouldFail = shouldFail;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (transferFromShouldFail) return false;
        return super.transferFrom(from, to, value);
    }
}
