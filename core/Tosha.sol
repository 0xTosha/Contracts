// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "../libs/IERC20.sol";
import "../libs/ERC20.sol";
import "../libs/SafeERC20.sol";
import "../libs/Address.sol";
import "../libs/SafeMath.sol";


contract TOSHA is ERC20 {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    address public governance;
    mapping(address => bool) public minters;

    constructor() public ERC20("Tosha.IO", "TOSHA") {
        governance = msg.sender;
    }

    function mint(address account, uint256 amount) public {
        require(minters[msg.sender], "!minter");
        _mint(account, amount);
    }

    function setGovernance(address _governance) public {
        require(msg.sender == governance, "!governance");
        governance = _governance;
    }

    function addMinter(address _minter) public {
        require(msg.sender == governance, "!governance");
        minters[_minter] = true;
    }

    function removeMinter(address _minter) public {
        require(msg.sender == governance, "!governance");
        minters[_minter] = false;
    }
}
