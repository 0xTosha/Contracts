// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "../libs/IERC20.sol";
import "../libs/SafeERC20.sol";
import "../libs/SafeMath.sol";

contract LPTokenWrapper {
   using SafeMath for uint256;
   using SafeERC20 for IERC20;

   IERC20 public stakedToken;

   uint256 private _totalSupply;
   mapping(address => uint256) private _balances;

   constructor(address _stakedToken) public {
       stakedToken = IERC20(_stakedToken);
   }

   function totalSupply() public view returns (uint256) {
       return _totalSupply;
   }

   function balanceOf(address account) public view returns (uint256) {
       return _balances[account];
   }

   function stakeToken(uint256 amount) public {
       _totalSupply = _totalSupply.add(amount);
       _balances[msg.sender] = _balances[msg.sender].add(amount);
       stakedToken.safeTransferFrom(msg.sender, address(this), amount);
   }

   function withdrawToken(uint256 amount) public {
       _totalSupply = _totalSupply.sub(amount);
       _balances[msg.sender] = _balances[msg.sender].sub(amount);
       stakedToken.safeTransfer(msg.sender, amount);
   }
}