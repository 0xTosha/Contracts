// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "../libs/IERC20.sol";
import "../libs/SafeERC20.sol";
import "../libs/SafeMath.sol";
import "../libs/GasThrottler.sol";
import "../interfaces/IRewardPool.sol";
import "../interfaces/IUniswapRouterETH.sol";
import "../interfaces/IUniswapV2Pair.sol";
import "../interfaces/IMasterChef.sol";
import "../interfaces/IRewarder.sol";
import "../interfaces/IVault.sol";
import "../utils/StringUtils.sol";
import "./StratManagerLP.sol";
import "./FeeManagerLP.sol";

contract StrategyCommonLP is StratManagerLP, FeeManagerLP, GasThrottler {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // Tokens used
    address public native;            
    address public output;             
    address public want;              
    address public coreToken;
    

    // Third party contracts
    address public chef;                //MasterChef
    uint256 public poolId;              //index of pool Id for above LP Token
    uint256 public lastHarvest;
    bool public harvestOnDeposit;
    string public pendingRewardsFunctionName;

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

        output = _outputToNativeRoute[0];
        native = _outputToNativeRoute[_outputToNativeRoute.length - 1];
        outputToNativeRoute = _outputToNativeRoute;
    
        // setup lp routing
        require(_nativeToCoreRoute[0] == native, "nativeToCoreRoute[0] != output");
        coreToken = _nativeToCoreRoute[_nativeToCoreRoute.length - 1];
        nativeToCoreRoute = _nativeToCoreRoute;
        _giveAllowances();
    }
    // puts the funds to work
    function deposit() public whenNotPaused {
        uint256 wantBal = IERC20(want).balanceOf(address(this));
        if (wantBal > 0) {
            IMasterChef(chef).deposit(poolId, wantBal);
            emit Deposit(balanceOf());
        }
    }
    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");

        uint256 wantBal = IERC20(want).balanceOf(address(this));
        if (wantBal < _amount) {
            IMasterChef(chef).withdraw(poolId, _amount.sub(wantBal));
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

    function harvest() external gasThrottle virtual {
        _harvest(tx.origin);
    }
    function harvestWithCallFeeRecipient(address callFeeRecipient) external gasThrottle virtual {
        _harvest(callFeeRecipient);
    }
    function managerHarvest() external onlyManager {
        _harvest(tx.origin);
    }
    // compounds earnings and charges performance fee
    function _harvest(address callFeeRecipient) internal whenNotPaused {
        IMasterChef(chef).deposit(poolId, 0);
        uint256 outputBal = IERC20(output).balanceOf(address(this));
        if (outputBal > 0) {
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
        (uint256 amount, ) =  IMasterChef(chef).userInfo(poolId, address(this));
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
        (uint256 _amount, ) = IMasterChef(chef).userInfo(poolId, address(this));
        return _amount;
    }
    // called as part of strat migration. Sends all the available funds back to the vault.
    function retireStrat() external {
        require(msg.sender == vault, "!vault");
        IMasterChef(chef).emergencyWithdraw(poolId);
        uint256 wantBal = IERC20(want).balanceOf(address(this));
        IERC20(want).transfer(vault, wantBal);
    }
    function setPendingRewardsFunctionName(string calldata _pendingRewardsFunctionName) external onlyManager {
        pendingRewardsFunctionName = _pendingRewardsFunctionName;
    }

    // returns rewards unharvested
    function rewardsAvailable() public view returns (uint256) {
        string memory signature = StringUtils.concat(pendingRewardsFunctionName, "(uint256,address)");
        bytes memory result = Address.functionStaticCall(
            chef,
            abi.encodeWithSignature(
                signature,
                poolId,
                address(this)
            )
        );
        return abi.decode(result, (uint256));
    }
    // native reward amount for calling harvest
    function callReward() public view returns (uint256) {
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

        return nativeOut.mul(45).div(1000).mul(callFee).div(MAX_FEE);
    }
    function setHarvestOnDeposit(bool _harvestOnDeposit) external onlyManager {
        harvestOnDeposit = _harvestOnDeposit;
        if (harvestOnDeposit) {
            setWithdrawalFee(0);
        } else {
            setWithdrawalFee(10);
        }
    }

    function setShouldGasThrottle(bool _shouldGasThrottle) external onlyManager {
        shouldGasThrottle = _shouldGasThrottle;
    }

    // pauses deposits and withdraws all funds from third party systems.
    function panic() public onlyManager {
        pause();
        IMasterChef(chef).emergencyWithdraw(poolId);
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
