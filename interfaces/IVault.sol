// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "../libs/IERC20.sol";
import "./IStrategy.sol";

interface IVault {
    function want() external view returns (IERC20);
    function deposit(uint256 _amount) external;
    function withdraw(uint256 _shares) external;
    function notifyRewards(uint256 total) external;
    function userInfo(address _user) external view returns (uint256 shares);

}