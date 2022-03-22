// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "../libs/IERC20.sol";
import "../libs/Ownable.sol";
import "../libs/SafeERC20.sol";
import "../libs/EnumerableSet.sol";
import "./TOSHA.sol";


contract MasterChef is Ownable {
    using SafeERC20 for IERC20;

   //Our token
    TOSHA public token;

    // Reserve Funds address
    address public reserveFundsAddress;

    // Farming rewarder address
    address public farmingRewarderAddress;

    // Reward Pool address
    address public rewardPoolAddress;

    uint256 public rewardsPerBlock;

    // Tokens created per block
    uint256 public tokensPerBlock;

    // distribution percentages: a value of 1000 = 100%
    // 10% percentage of rewards that goes to the reserve funds.
    uint256 public constant RESERVE_FUND_PERCENTAGE = 100;

    // 90% percentage of rewards that goes to farming rewards.
    uint256 public constant FARMING_REWARDER_PERCENTAGE = 900;

    // The block number when token mining starts
    uint256 public lastRewardBlock;

    event Harvest(address indexed user, uint256 indexed pid, uint256 amount);

    event SetReserveFundsAddress(
        address indexed oldAddress,
        address indexed newAddress
    );

    event SetFarmingRewarderAddress(
        address indexed oldAddress,
        address indexed newAddress
    );

    event UpdateEmissionRate(address indexed user, uint256 _tokensPerSec);
    event UpdateRewardsRate(address indexed user, uint256 _rewardsPerSec);

    constructor(
        TOSHA _token,
        address _reserveFundsAddress,
        address _farmingRewarderAddress,
        address _rewardPoolAddress,
        uint256 _tokensPerBlock,
        uint256 _startBlock
    ) public {
        require(
            _tokensPerBlock <= 6e18,
            "maximum emission rate of 6 tokens per block exceeded"
        );
        token = _token;
        reserveFundsAddress = _reserveFundsAddress;
        farmingRewarderAddress = _farmingRewarderAddress;
        rewardPoolAddress = _rewardPoolAddress;
        tokensPerBlock = _tokensPerBlock;
        lastRewardBlock = block.number > _startBlock ? block.number : _startBlock;

    }

   function harvest() public {

     if (block.number > lastRewardBlock) {
        uint256 blocksSinceLastReward = block.number - lastRewardBlock;

        // rewards for these many blocks
        uint256 tokenRewards = blocksSinceLastReward * tokensPerBlock;

        uint256 rewardsForFarming = (tokenRewards * FARMING_REWARDER_PERCENTAGE) / 1000;
        uint256 rewardsForReserves = (tokenRewards * RESERVE_FUND_PERCENTAGE) / 1000;

        token.mint(reserveFundsAddress,rewardsForReserves);

        uint256 rewardsForPool = (blocksSinceLastReward * rewardsPerBlock);
        if (rewardsForFarming > rewardsForPool) {
          token.mint(rewardPoolAddress, rewardsForPool);
          token.mint(farmingRewarderAddress, rewardsForFarming - rewardsForPool);
        } else {
          token.mint(rewardPoolAddress, rewardsForFarming);
        }

        lastRewardBlock = block.number;
      }
    }

    // Update reserve funds address by the owner
    function updateReserveFundsAddress(address _reserveFundsAddress) public onlyOwner {
        reserveFundsAddress = _reserveFundsAddress;
        emit SetReserveFundsAddress(reserveFundsAddress, _reserveFundsAddress);
    }

    // Update farming rewarder address by the owner
    function updateFarmingRewarderAddress(address _farmingRewarderAddress) public onlyOwner {
        farmingRewarderAddress = _farmingRewarderAddress;
        emit SetFarmingRewarderAddress(farmingRewarderAddress, _farmingRewarderAddress);
    }

    function updateEmissionRate(uint256 _tokensPerBlock) public onlyOwner {
        require(
            _tokensPerBlock <= 6e18,
            "maximum emission rate of 6 tokens per block exceeded"
        );
        tokensPerBlock = _tokensPerBlock;
        emit UpdateEmissionRate(msg.sender, _tokensPerBlock);
    }

    function updateRewardsRate(uint256 _rewardsPerBlock) public onlyOwner {
        require(
            _rewardsPerBlock <= 4e18,
            "maximum emission rate of 4 tokens per block exceeded"
        );
        rewardsPerBlock = _rewardsPerBlock;
        emit UpdateRewardsRate(msg.sender, _rewardsPerBlock);
    }
}
