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
    uint256 public immutable maxSupply;
    address public governance;
    mapping(address => bool) public minters;

    constructor(uint256 _maxSupply) public ERC20("ToshaDAO", "TOSHA") {
        maxSupply = _maxSupply;
        governance = msg.sender;
    }

    function mint(address account, uint256 amount) public {
        require(minters[msg.sender], "!minter");
        require(totalSupply().add(amount) <= maxSupply, "Cannot mint more than maxSupply");
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
