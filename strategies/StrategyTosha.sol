// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "../libs/IERC20.sol";
import "../libs/SafeERC20.sol";
import "../libs/SafeMath.sol";
import "./StratManager.sol";
import "./FeeManager.sol";
import "../interfaces/IRewardPool.sol";
import "../interfaces/IUniswapRouterETH.sol";


contract StrategyTosha is StratManager, FeeManager {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // Tokens used
    address constant public output = address(0xC4C49De466b94ad79A992534Db2cbE40BafaF538); //TOSHA token
    address public want;

    // Third party contracts
    address public rewardPool;

    // Routes
    address[] public outputToWantRoute;

    bool public harvestOnDeposit;
    uint256 public lastHarvest;

    bool immutable public sameToken;


    /**
     * @dev Event that is fired each time someone harvests the strat.
     */
    event StratHarvest(address indexed harvester, uint256 wantHarvested, uint256 tvl);
    event Deposit(uint256 tvl);
    event Withdraw(uint256 tvl);

    constructor(
        address _want,
        address _rewardPool,
        address _vault,
        address _unirouter,
        address _keeper
    ) StratManager(_keeper, _unirouter, _vault) public {
        want = _want;
        rewardPool = _rewardPool;

        outputToWantRoute = [output, want];

        sameToken = output == want;

        _giveAllowances();
    }

    // puts the funds to work
    function deposit() public whenNotPaused {
        uint256 wantBal = balanceOfWant();

        if (wantBal > 0) {
            IRewardPool(rewardPool).stake(wantBal);
            emit Deposit(balanceOf());
        }
    }

    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");

        uint256 wantBal = balanceOfWant();

        if (wantBal < _amount) {
            IRewardPool(rewardPool).withdraw(_amount.sub(wantBal));
            wantBal = balanceOfWant();
        }

        if (wantBal > _amount) {
            wantBal = _amount;
        }

        if (tx.origin != owner() && !paused()) {
            uint256 withdrawalFeeAmount = wantBal.mul(withdrawalFee).div(WITHDRAWAL_MAX);
            wantBal = wantBal.sub(withdrawalFeeAmount);
        }

        IERC20(want).safeTransfer(vault, wantBal);

        emit Withdraw(balanceOf());
    }

    function beforeDeposit() external override {
        if (harvestOnDeposit) {
            require(msg.sender == vault, "!vault");
            _harvest(tx.origin);
        }
    }

    function harvest() external virtual {
        _harvest(tx.origin);
    }

    function harvest(address callFeeRecipient) external virtual {
        _harvest(callFeeRecipient);
    }

    // compounds earnings and charges performance fee
    function _harvest(address callFeeRecipient) internal {
        IRewardPool(rewardPool).getReward();
        uint256 outputBal = IERC20(output).balanceOf(address(this));
        if (outputBal > 0) {
            chargeFees(callFeeRecipient);
            if (!sameToken) {
               swapRewards();
            }
            uint256 wantHarvested = balanceOfWant();
            deposit();

            lastHarvest = block.timestamp;
            emit StratHarvest(msg.sender, wantHarvested, balanceOf());
        }
    }

    // performance fees
    function chargeFees(address callFeeRecipient) internal {
        uint256 callFee = IERC20(output).balanceOf(address(this)).mul(callFee).div(MAX_CALL_FEE);
        IERC20(output).safeTransfer(callFeeRecipient, callFee);
    }

    // Swaps Rewards for more BIFI.
    function swapRewards() internal {
        uint256 toBIFI = IERC20(output).balanceOf(address(this));
        IUniswapRouterETH(unirouter).swapExactTokensForTokens(toBIFI, 0, outputToWantRoute, address(this), now);
    }

    // calculate the total underlaying 'want' held by the strat.
    function balanceOf() public view returns (uint256) {
        return balanceOfWant().add(balanceOfPool());
    }

    // it calculates how much 'want' this contract holds.
    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    // it calculates how much 'want' the strategy has working in the farm.
    function balanceOfPool() public view returns (uint256) {
        return IRewardPool(rewardPool).balanceOf(address(this));
    }

    function rewardsAvailable() public view returns (uint256) {
        return IRewardPool(rewardPool).earned(address(this));
    }

    function callReward() public view returns (uint256) {
        return rewardsAvailable().mul(callFee).div(MAX_CALL_FEE);
    }

    function setHarvestOnDeposit(bool _harvestOnDeposit) external onlyManager {
        harvestOnDeposit = _harvestOnDeposit;

        if (harvestOnDeposit) {
            setWithdrawalFee(0);
        } else {
            setWithdrawalFee(10);
        }
    }

    // called as part of strat migration. Sends all the available funds back to the vault.
    function retireStrat() external {
        require(msg.sender == vault, "!vault");

        IRewardPool(rewardPool).withdraw(balanceOfPool());

        uint256 wantBal = IERC20(want).balanceOf(address(this));
        IERC20(want).transfer(vault, wantBal);
    }

    // pauses deposits and withdraws all funds from third party systems.
    function panic() public onlyManager {
        pause();
        IRewardPool(rewardPool).withdraw(balanceOfPool());
    }

    function pause() public onlyManager {
        _pause();

        _removeAllowances();
    }

    function unpause() external onlyManager {
        _unpause();

        _giveAllowances();

        deposit();
    }

    function _giveAllowances() internal {
        IERC20(want).safeApprove(rewardPool, uint256(-1));
        IERC20(output).safeApprove(unirouter, uint256(-1));
    }

    function _removeAllowances() internal {
        IERC20(want).safeApprove(rewardPool, 0);
        IERC20(output).safeApprove(unirouter, 0);
    }

    function outputToWant() external view returns (address[] memory) {
        return outputToWantRoute;
    }
}
