// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "../libs/IERC20.sol";
import "../libs/SafeERC20.sol";
import "../libs/SafeMath.sol";
import "../interfaces/IRewardPool.sol";
import "../interfaces/IUniswapRouterETH.sol";
import "../interfaces/IUniswapV2Pair.sol";
import "../interfaces/IRewarder.sol";
import "../interfaces/IVault.sol";
import "../interfaces/IMiniChefV2.sol";
import "./StratManagerLP.sol";
import "./FeeManagerLP.sol";


contract StrategySushiLP is StratManagerLP, FeeManagerLP {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // Tokens used
    address public native;              //CELO
    address public output;              //SUSHI
    address public want;                //LP Pair Token e.g. cUSD/USDC
    address public coreToken;           //TOSHA


    // Third party contracts
    address public chef;                //Sushi MiniChef
    uint256 public poolId;              //index of sushi pool Id for above LP Token
    uint256 public lastHarvest;
    bool public harvestOnDeposit;
    // Routes
    address[] public outputToNativeRoute;
    address[] public nativeToCoreRoute;

    /**
     * @dev Event that is fired each time someone harvests the strat.
     */
    event StratHarvest(address indexed harvester, uint256 wantHarvested, uint256 tvl);
    event Deposit(uint256 tvl);
    event Withdraw(uint256 tvl);

    constructor(
        address _want,
        uint256 _poolId,
        address _chef,
        address _vault,
        address _unirouter,
        address _keeper,
        address _strategist,
        address _beefyFeeRecipient,
        address[] memory _outputToNativeRoute,
        address[] memory _nativeToCoreRoute
    ) StratManagerLP(_keeper, _strategist, _unirouter, _vault, _beefyFeeRecipient) public {
        want = _want;
        poolId = _poolId;
        chef = _chef;
        require(_outputToNativeRoute.length >= 2);
        output = _outputToNativeRoute[0];
        native = _outputToNativeRoute[_outputToNativeRoute.length - 1];
        outputToNativeRoute = _outputToNativeRoute;

        // setup lp routing
        require(_nativeToCoreRoute[0] == native);
        coreToken = _nativeToCoreRoute[_nativeToCoreRoute.length - 1];
        nativeToCoreRoute = _nativeToCoreRoute;
        _giveAllowances();
    }
    // puts the funds to work
    function deposit() public whenNotPaused {
        uint256 wantBal = IERC20(want).balanceOf(address(this));
        if (wantBal > 0) {
            IMiniChefV2(chef).deposit(poolId, wantBal, address(this));
            emit Deposit(balanceOf());
        }
    }
    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");

        uint256 wantBal = IERC20(want).balanceOf(address(this));
        if (wantBal < _amount) {
            IMiniChefV2(chef).withdraw(poolId, _amount.sub(wantBal), address(this));
            wantBal = IERC20(want).balanceOf(address(this));
        }
        if (wantBal > _amount) {
            wantBal = _amount;
        }

        if (tx.origin == owner() || paused()) {
            IERC20(want).safeTransfer(vault, wantBal);
        } else {
            uint256 withdrawalFeeAmount = wantBal.mul(withdrawalFee).div(WITHDRAWAL_MAX);
            IERC20(want).safeTransfer(vault, wantBal.sub(withdrawalFeeAmount));
        }
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
    function harvestWithCallFeeRecipient(address callFeeRecipient) external virtual {
        _harvest(callFeeRecipient);
    }
    function managerHarvest() external onlyManager {
        _harvest(tx.origin);
    }
    // compounds earnings and charges performance fee
    function _harvest(address callFeeRecipient) internal whenNotPaused {
        IMiniChefV2(chef).harvest(poolId, address(this));
        uint256 outputBal = IERC20(output).balanceOf(address(this));
        uint256 nativeBal = IERC20(native).balanceOf(address(this));
        if (outputBal > 0 || nativeBal > 0) {
            chargeFees(callFeeRecipient);
            uint256 wantHarvested = balanceOfWant();
            _deposit();
            lastHarvest = block.timestamp;
            emit StratHarvest(msg.sender, wantHarvested, balanceOf());
        }
    }
    // performance fees
    function chargeFees(address callFeeRecipient) internal {
        uint256 toNative = IERC20(output).balanceOf(address(this));
        IUniswapRouterETH(unirouter).swapExactTokensForTokens(toNative, 0, outputToNativeRoute, address(this), block.timestamp);
        uint256 feeBal = IERC20(native).balanceOf(address(this)).mul(45).div(1000);
        uint256 callFeeAmount = feeBal.mul(callFee).div(MAX_FEE);
        IERC20(native).safeTransfer(callFeeRecipient, callFeeAmount);
        uint256 beefyFeeAmount = feeBal.mul(beefyFee).div(MAX_FEE);
        IERC20(native).safeTransfer(beefyFeeRecipient, beefyFeeAmount);
        uint256 strategistFee = feeBal.mul(STRATEGIST_FEE).div(MAX_FEE);
        IERC20(native).safeTransfer(strategist, strategistFee);
    }
    // convert native to core token and deposit to vault
    function _deposit() internal {
        uint256 nativeToken = IERC20(native).balanceOf(address(this));
        if (coreToken != native) {
            IUniswapRouterETH(unirouter).swapExactTokensForTokens(nativeToken, 0, nativeToCoreRoute, address(this), block.timestamp);
        }
        uint256 coreBal = IERC20(coreToken).balanceOf(address(this));
        if (coreBal > 0) {
            IERC20(coreToken).safeTransfer(vault, coreBal);
            IVault(vault).notifyRewards(totalStake());
        }
    }

    function totalStake() public view returns (uint256) {
        (uint256 amount, ) =  IMiniChefV2(chef).userInfo(poolId, address(this));
        return amount;
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
        (uint256 _amount, ) = IMiniChefV2(chef).userInfo(poolId, address(this));
        return _amount;
    }
    // called as part of strat migration. Sends all the available funds back to the vault.
    function retireStrat() external {
        require(msg.sender == vault, "!vault");
        IMiniChefV2(chef).emergencyWithdraw(poolId, address(this));
        uint256 wantBal = IERC20(want).balanceOf(address(this));
        IERC20(want).transfer(vault, wantBal);
    }
    // returns rewards unharvested
    function rewardsAvailable() public view returns (uint256) {
        return IMiniChefV2(chef).pendingSushi(poolId, address(this));
    }
    // native reward amount for calling harvest
    function callReward() public view returns (uint256) {
        uint256 pendingReward;
        address rewarder = IMiniChefV2(chef).rewarder(poolId);
        if (rewarder != address(0)) {
            pendingReward = IRewarder(rewarder).pendingToken(poolId, address(this));
        }
        uint256 outputBal = rewardsAvailable();
        uint256 nativeOut;
        if (outputBal > 0) {
            try IUniswapRouterETH(unirouter).getAmountsOut(outputBal, outputToNativeRoute)
                returns (uint256[] memory amountOut)
            {
                nativeOut = amountOut[amountOut.length -1];
            }
            catch {}
        }
       uint256 totNative = nativeOut.add(pendingReward);
        return totNative.mul(45).div(1000).mul(callFee).div(MAX_FEE);
    }
    function setHarvestOnDeposit(bool _harvestOnDeposit) external onlyManager {
        harvestOnDeposit = _harvestOnDeposit;
        if (harvestOnDeposit) {
            setWithdrawalFee(0);
        } else {
            setWithdrawalFee(10);
        }
    }
    // pauses deposits and withdraws all funds from third party systems.
    function panic() public onlyManager {
        pause();
        IMiniChefV2(chef).emergencyWithdraw(poolId, address(this));
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
        IERC20(want).safeApprove(chef, type(uint256).max);
        IERC20(native).safeApprove(unirouter, type(uint256).max);
        IERC20(output).safeApprove(unirouter, type(uint256).max);
        IERC20(coreToken).safeApprove(unirouter, 0);
        IERC20(coreToken).safeApprove(unirouter, type(uint256).max);
    }
    function _removeAllowances() internal {
        IERC20(want).safeApprove(chef, 0);
        IERC20(native).safeApprove(unirouter, 0);
        IERC20(output).safeApprove(unirouter, 0);
        IERC20(coreToken).safeApprove(unirouter, 0);
    }
}
