// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;


import "../libs/IERC20.sol";
import "../libs/ERC20.sol";
import "../libs/SafeERC20.sol";
import "../libs/SafeMath.sol";
import "../libs/ReentrancyGuard.sol";
import "../libs/Ownable.sol";
import "../interfaces/IStrategy.sol";
import "../interfaces/IVault.sol";


/**
 * @dev Implementation of a vault to deposit funds for yield optimizing.
 * This is the contract that receives funds and that users interface with.
 * The yield optimizing strategy itself is implemented in a separate 'Strategy.sol' contract.
 */
contract ToshaLPVault is ERC20, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    struct UserInfo {
        uint256 shares; // number of shares for a user
        // How many staked $Core user had at his last action
        uint256 autoCoreShares;
        // Core shares not entitled to the user
        uint256 rewardDebt;
        // Timestamp of last user deposit
        uint256 lastDepositedTime;
    }

    struct StratCandidate {
        address implementation;
        uint proposedTime;
    }

    // The last proposed strategy to switch to.
    StratCandidate public stratCandidate;
    // The strategy currently in use by the vault.
    IStrategy public strategy;
    // The minimum time it has to pass before a strat candidate can be approved.
    uint256 public immutable approvalDelay;

    mapping(address => UserInfo) public userInfo;

    uint256 public accSharesPerStakedToken; // Accumulated shares per core token, times 1e18.
    IVault public coreVault;           //Tosha Vault address
    address public coreToken;           //Tosha

    event NewStratCandidate(address implementation);
    event UpgradeStrat(address implementation);

    /**
     * @dev Sets the value of {token} to the token that the vault will
     * hold as underlying value. It initializes the vault's own 'moo' token.
     * This token is minted when someone does a deposit. It is burned in order
     * to withdraw the corresponding portion of the underlying assets.
     * @param _strategy the address of the strategy.
     * @param _name the name of the vault token.
     * @param _symbol the symbol of the vault token.
     * @param _approvalDelay the delay before a new strat can be approved.
     */
    constructor (
        IVault _coreVault,
        IStrategy _strategy,
        string memory _name,
        string memory _symbol,
        uint256 _approvalDelay
    ) public ERC20(
        _name,
        _symbol
    ) {
        coreVault = _coreVault;
        coreToken = address(IVault(_coreVault).want());
        strategy = _strategy;
        approvalDelay = _approvalDelay;
        IERC20(coreToken).safeApprove(address(coreVault), type(uint256).max);
    }

    function want() public view returns (IERC20) {
        return IERC20(strategy.want());
    }

    /**
     * @dev It calculates the total underlying value of {token} held by the system.
     * It takes into account the vault contract balance, the strategy contract balance
     *  and the balance deployed in other contracts as part of the strategy.
     */
    function balance() public view returns (uint) {
        return want().balanceOf(address(this)).add(IStrategy(strategy).balanceOf());
    }

    /**
     * @dev Custom logic in here for how much the vault allows to be borrowed.
     * We return 100% of tokens for now. Under certain conditions we might
     * want to keep some of the system funds at hand in the vault, instead
     * of putting them to work.
     */
    function available() public view returns (uint256) {
        return want().balanceOf(address(this));
    }

    /**
     * @dev Function for various UIs to display the current value of one of our yield tokens.
     * Returns an uint256 with 18 decimals of how much underlying asset one vault share represents.
     */
    function getPricePerFullShare() public view returns (uint256) {
        return totalSupply() == 0 ? 1e18 : balance().mul(1e18).div(totalSupply());
    }

    /**
     * @dev A helper function to call deposit() with all the sender's funds.
     */
    function depositAll() external {
        deposit(want().balanceOf(msg.sender));
    }

    /**
     * @dev The entrypoint of funds into the system. People deposit with this function
     * into the vault. The vault is then in charge of sending funds into the strategy.
     */
    function deposit(uint _amount) public nonReentrant {
        strategy.beforeDeposit();

        uint256 _pool = balance();
        want().safeTransferFrom(msg.sender, address(this), _amount);
        earn();
        uint256 _after = balance();
        _amount = _after.sub(_pool); // Additional check for deflationary tokens
        uint256 shares = 0;
        if (totalSupply() == 0) {
            shares = _amount;
        } else {
            shares = (_amount.mul(totalSupply())).div(_pool);
        }

        UserInfo storage user = userInfo[msg.sender];
        user.autoCoreShares = user.autoCoreShares.add(user.shares.mul(accSharesPerStakedToken).div(1e18).sub(user.rewardDebt));
        user.shares = user.shares.add(shares);
        user.rewardDebt = user.shares.mul(accSharesPerStakedToken).div(1e18);
        user.lastDepositedTime = block.timestamp;

        _mint(msg.sender, shares);
    }

    /**
     * @dev Function to send funds into the strategy and put them to work. It's primarily called
     * by the vault's deposit() function.
     */
    function earn() public {
        uint _bal = available();
        want().safeTransfer(address(strategy), _bal);
        strategy.deposit();
    }

    /**
     * @dev A helper function to call withdraw() with all the sender's funds.
     */
    function withdrawAll() external {
        withdraw(balanceOf(msg.sender));
    }

    /**
     * @dev Function to exit the system. The vault will withdraw the required tokens
     * from the strategy and pay up the token holder. A proportional number of IOU
     * tokens are burned in the process.
     */
    function withdraw(uint256 _shares) public {
        UserInfo storage user = userInfo[msg.sender];
        if (user.shares > 0) {
            uint256 sharePerc = _getPercent(_shares, user.shares);
            uint256 r = (balance().mul(_shares)).div(totalSupply());
            _burn(msg.sender, _shares);

            uint b = want().balanceOf(address(this));
            if (b < r) {
                uint _withdraw = r.sub(b);
                strategy.withdraw(_withdraw);
                uint _after = want().balanceOf(address(this));
                uint _diff = _after.sub(b);
                if (_diff < _withdraw) {
                    r = b.add(_diff);
                }
            }

            want().safeTransfer(msg.sender, r);

            user.autoCoreShares = user.autoCoreShares.add(user.shares.mul(accSharesPerStakedToken).div(1e18).sub(user.rewardDebt));
            user.shares = user.shares.sub(_shares);
            user.rewardDebt = user.shares.mul(accSharesPerStakedToken).div(1e18);

            // Withdraw rewards if user leaves
            if (user.shares == 0 && user.autoCoreShares > 0) {
                _claimRewards(user.autoCoreShares);
            } else if (sharePerc > 0) { // withdraw rewards based on share percentage
                _claimRewards(user.autoCoreShares.mul(sharePerc).div(100));
            }

        }
    }

    function _getPercent(uint256 part, uint256 whole) pure private returns(uint256 percent) {
        uint numerator = part.mul(1000);
        require(numerator > part);
        uint temp = numerator.div(whole).add(5);
        return temp.div(10);
    }

    function _claimRewards(uint256 _shares) private {
        UserInfo storage user = userInfo[msg.sender];
        user.autoCoreShares = user.autoCoreShares.sub(_shares);
        uint256 coreBalanceBefore = _coreBalance();
        IVault(coreVault).withdraw(_shares);
        uint256 withdrawAmount = _coreBalance().sub(coreBalanceBefore);
        _safeCoreTransfer(msg.sender, withdrawAmount);
    }

    // Safe Core transfer function, just in case if rounding error causes pool to not have enough
    function _safeCoreTransfer(address _to, uint256 _amount) private {
        uint256 _balance = _coreBalance();

        if (_amount > _balance) {
            IERC20(coreToken).transfer(_to, _balance);
        } else {
            IERC20(coreToken).transfer(_to, _amount);
        }
    }

    function notifyRewards(uint256 _totalStake) external {
        require(msg.sender == address(strategy), "!strategy");
        uint256 coreBal = IERC20(coreToken).balanceOf(address(this));
        if (coreBal > 0) {
            uint256 previousShares = totalAutoCoreShares();
            IVault(coreVault).deposit(coreBal);
            uint256 currentShares = totalAutoCoreShares();
            accSharesPerStakedToken = accSharesPerStakedToken.add(
                currentShares.sub(previousShares).mul(1e18).div(_totalStake)
            );
        }
    }

    function totalAutoCoreShares() public view returns (uint256) {
        uint256 shares = IVault(coreVault).userInfo(address(this));
        return shares;
    }

    function _coreBalance() private view returns (uint256) {
        return IERC20(coreToken).balanceOf(address(this));
    }

    /**
     * @dev Sets the candidate for the new strat to use with this vault.
     * @param _implementation The address of the candidate strategy.
     */
    function proposeStrat(address _implementation) public onlyOwner {
        require(address(this) == IStrategy(_implementation).vault(), "Proposal not valid for this Vault");
        stratCandidate = StratCandidate({
            implementation: _implementation,
            proposedTime: block.timestamp
         });

        emit NewStratCandidate(_implementation);
    }

    /**
     * @dev It switches the active strat for the strat candidate. After upgrading, the
     * candidate implementation is set to the 0x00 address, and proposedTime to a time
     * happening in +100 years for safety.
     */

    function upgradeStrat() public onlyOwner {
        require(stratCandidate.implementation != address(0), "There is no candidate");
        require(stratCandidate.proposedTime.add(approvalDelay) < block.timestamp, "Delay has not passed");

        emit UpgradeStrat(stratCandidate.implementation);

        strategy.retireStrat();
        strategy = IStrategy(stratCandidate.implementation);
        stratCandidate.implementation = address(0);
        stratCandidate.proposedTime = 5000000000;

        earn();
    }

    /**
     * @dev Rescues random funds stuck that the strat can't handle.
     * @param _token address of the token to rescue.
     */
    function inCaseTokensGetStuck(address _token) external onlyOwner {
        require(_token != address(want()), "!token");

        uint256 amount = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransfer(msg.sender, amount);
    }
}
