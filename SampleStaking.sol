// SPDX-License-Identifier: UNLINCENSED
import "./libs/Context.sol";
import "./libs/Ownable.sol";
import "./libs/ReentrancyGuard.sol";

import "./interfaces/IERC20.sol";

pragma solidity ^0.8.0;

contract SampleStaking is Ownable, ReentrancyGuard {
    bool private isInitialized = false;
    bool private suspended = false;

    ItReward private itReward;

    // The staked token
    IERC20 public stakedToken;
    // The reward token
    IERC20 public rewardToken;
    // Reward start / end time
    uint256 public rewardStartBlock;
    uint256 public rewardEndBlock;

    uint256 public totalLockedUpRewards;

    uint256 public PRECISION_FACTOR; // The precision factor

    // uint256 public rewardPerSecond; // reward distributed per sec.
    uint256 public lastRewardBlock; // Last timestamp that reward distribution occurs
    uint256 public accRewardPerShare; // Accumlated rewards per share

    uint256 public totalStakings; // Total staking tokens

    // Stakers
    address[] public userList;
    mapping(address => UserInfo) public userInfo;

    struct UserInfo {
        uint256 amount; // How many staked tokens the user has provided
        uint256 rewardDebt; // Reward debt.
        bool registered; // it will add user in address list on first deposit
        address addr; //address of user
        uint256 lockupReward; // Reward locked up.
        uint256 lastHarvestedAt; // Last harvested block
        uint256 lastDepositedAt; // Last withdrawn block
        uint256 rewardReceived; // total received reward
    }

    /// @notice Max 50 rewards can be stored
    uint256 public MAX_REWARD_COUNT = 50;
    // reward will be distrubuted in 30 days
    uint256 public rewardingPeriod;

    mapping(address => bool) public addRewardWhiteList;

    struct UserDebt {
        // reward debt
        uint256 debt;
        // lockup reward
        uint256 lockupReward;
    }
    struct ItReward {
        // start time => amount
        // reward per block
        mapping(uint256 => uint256) rewards;
        // start time => index
        mapping(uint256 => uint256) indexs;
        // start time => accumlated reward per share
        mapping(uint256 => uint256) accRewardPerShares;
        // array of reward start block
        uint256[] rewardStartBlocks;
        // user reward debt & lockup reward
        mapping(address => mapping(uint256 => UserDebt)) rewardDebts;
    }

    event Deposited(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event EmergencyRewardWithdrawn(address indexed account, uint256 amount);
    event AdminTokenRecovery(address tokenRecovered, uint256 amount);
    event UserRewarded(address indexed account, uint256 amount);
    event LockupReward(address _account, uint256 _reward, uint256 _rewardLocked);
    event CanHarvest(bool available, uint256 fee, uint256 reward);
    event Log(string message);

    function updateAddRewardWhiteList(
        address _account,
        bool _permission
    ) external onlyOwner {
        require(addRewardWhiteList[_account] != _permission, "not changed");
        addRewardWhiteList[_account] = _permission;
    }

    function addReward(
        uint256 _amount
    ) external {
        require(addRewardWhiteList[_msgSender()], "you don't have permission");
        require(
            rewardToken.allowance(_msgSender(), address(this)) >= _amount,
            "not approved yet"
        );
        uint256 _rewardStartBlock = block.number;
        if (lastRewardBlock > _rewardStartBlock) {
            _rewardStartBlock = lastRewardBlock;
        }

        uint256 keyIndex = itReward.indexs[_rewardStartBlock];
        itReward.rewards[_rewardStartBlock] += _amount / rewardingPeriod;

        rewardToken.transferFrom(_msgSender(), address(this), _amount);

        updatePool();

        if (keyIndex > 0) return;
        // When the key not exists, add it
        itReward.indexs[_rewardStartBlock] = itReward.rewardStartBlocks.length + 1;
        itReward.rewardStartBlocks.push(_rewardStartBlock);
        require(itReward.rewardStartBlocks.length <= MAX_REWARD_COUNT, "Too many rewards");
    }

    function initialize(
        IERC20 _stakedToken,
        IERC20 _rewardToken,
        uint256 _rewardStartBlock,
        uint256 _rewardEndBlock,
        uint256 _rewardingPeriod,
        address _admin
    ) external onlyOwner {
        require(!isInitialized, "Already initialized");
        require(
            block.number < _rewardStartBlock &&
                _rewardStartBlock <= _rewardEndBlock,
            "Invalid blocks"
        );
        require(_rewardingPeriod > 0, "rewarding period must be greater than 0");

        // Make this contract initialized
        isInitialized = true;

        stakedToken = _stakedToken;
        rewardToken = _rewardToken;
        rewardStartBlock = _rewardStartBlock;
        rewardEndBlock = _rewardEndBlock;
        rewardingPeriod = _rewardingPeriod;

        uint256 decimalsRewardToken = uint256(rewardToken.decimals());
        require(decimalsRewardToken < 30, "Must be inferior to 30");

        PRECISION_FACTOR = uint256(10**(uint256(30) - decimalsRewardToken));

        lastRewardBlock = _rewardStartBlock; // Set the last reward block as the start block

        addRewardWhiteList[_admin] = true;
    }

    function updateMaxRewardCount(uint256 _maxRewardCount) external onlyOwner {
        require(MAX_REWARD_COUNT < _maxRewardCount, "you should set greater than current one");
        MAX_REWARD_COUNT = _maxRewardCount;
    }

    function getRewardedAmount() public view returns (uint256 rewarded) {
        rewarded = 0;
        for (uint256 i=0; i<itReward.rewardStartBlocks.length; i++) {
            uint256 multipilier = getMultipilier(
                itReward.rewardStartBlocks[i],
                block.number,
                itReward.rewardStartBlocks[i] + rewardingPeriod    
            );
            rewarded += multipilier * itReward.rewards[itReward.rewardStartBlocks[i]];
        }
    }

    function suspend(bool _suspended) external onlyOwner {
        require(_suspended != suspended, "not changed");
        suspended = _suspended;
    }

    function updatePool() internal {
        if (block.number <= lastRewardBlock) {
            return;
        }

        if (totalStakings == 0 || getRewardedAmount() == 0) {
            lastRewardBlock = block.number;
            return;
        }

        for (uint256 i=0; i<itReward.rewardStartBlocks.length; i++) {
            uint256 multipilier = getMultipilier(
                lastRewardBlock, 
                block.number,
                itReward.rewardStartBlocks[i] + rewardingPeriod
            );
            uint256 key = itReward.rewardStartBlocks[i];
            uint256 rewardAccum = itReward.rewards[key] * multipilier;

            itReward.accRewardPerShares[key] = itReward.accRewardPerShares[key] + (
                rewardAccum * PRECISION_FACTOR / totalStakings
            );
        }
        lastRewardBlock = block.number;

    }

    function lockupReward() internal {
        UserInfo storage user = userInfo[_msgSender()];
        uint256 _reward = 0;
        for (uint256 i=0; i<itReward.rewardStartBlocks.length; i++) {
            uint256 key = itReward.rewardStartBlocks[i];

            itReward.rewardDebts[_msgSender()][key].lockupReward = pendingReward(_msgSender(), i);
            _reward += itReward.rewardDebts[_msgSender()][key].lockupReward;
        }
        emit LockupReward(_msgSender(), _reward, user.lockupReward);
        totalLockedUpRewards += _reward - user.lockupReward;
        user.lockupReward = _reward;
    }

    function updateRewardDebt() internal {
        UserInfo storage user = userInfo[_msgSender()];
        user.rewardDebt = 0;
        for (uint256 i=0; i<itReward.rewardStartBlocks.length; i++) {
            uint256 key = itReward.rewardStartBlocks[i];
            itReward.rewardDebts[_msgSender()][key].debt = 
                user.amount * itReward.accRewardPerShares[key] / PRECISION_FACTOR;

            user.rewardDebt += itReward.rewardDebts[_msgSender()][key].debt;
        }
    }

    function pendingReward(
        address _account, 
        uint256 _index
    ) internal view returns (uint256 reward) {
        if (_index >= itReward.rewardStartBlocks.length) {
            return 0;
        }
        UserInfo memory user = userInfo[_account];

        uint256 multipilier = getMultipilier(
            lastRewardBlock, 
            block.number,
            itReward.rewardStartBlocks[_index] + rewardingPeriod
        );
        uint256 key = itReward.rewardStartBlocks[_index];
        uint256 adjustedTokenPerShare = itReward.accRewardPerShares[key];
        if (totalStakings > 0) {
            uint256 rewardAccum = itReward.rewards[key] * multipilier;

            adjustedTokenPerShare = adjustedTokenPerShare + (
                rewardAccum * PRECISION_FACTOR / totalStakings
            );
        }
        reward = user.amount * adjustedTokenPerShare / PRECISION_FACTOR;
        if (reward > itReward.rewardDebts[_account][key].debt) {
            reward = reward - itReward.rewardDebts[_account][key].debt;
        } else {
            reward = 0;
        }
        reward = reward + itReward.rewardDebts[_account][key].lockupReward;
    }

    function pendingReward(address _account)
        public view
        returns (uint256 reward)
    {
        reward = 0;
        for (uint256 i=0; i<itReward.rewardStartBlocks.length; i++) {
            reward += pendingReward(_account, i);
        }
    }

    /**
     * @param _from: from
     * @param _to: to
     * @param _end: reward end time
     */
    function getMultipilier(uint256 _from, uint256 _to, uint256 _end)
        internal
        pure
        returns (uint256)
    {
        if (_to >= _end) {
            _to = _end;
        }
        if (_to <= _from) {
            return 0;
        } else {
            return _to - _from;
        }

    }

    /*
     * @notice Deposit staked tokens and collect reward tokens (if any)
     * @param _amount: amount to withdraw (in rewardToken)
     */
    function deposit(uint256 _amount) external nonReentrant {
        require(suspended == false, "suspended");
        require(_msgSender() == tx.origin, "Invalid Access");

        UserInfo storage user = userInfo[_msgSender()];
        updatePool();
        lockupReward();

        if (user.amount == 0 && user.registered == false) {
            userList.push(msg.sender);
            user.registered = true;
            user.addr = address(msg.sender);
        }

        if (_amount > 0) {
            // Every time when there is a new deposit, reset last withdrawn block
            user.lastDepositedAt = block.number;

            uint256 balanceBefore = stakedToken.balanceOf(address(this));
            stakedToken.transferFrom(
                address(_msgSender()),
                address(this),
                _amount
            );
            _amount = stakedToken.balanceOf(address(this)) - balanceBefore;

            user.amount = user.amount + _amount;
            totalStakings = totalStakings + _amount;

            emit Deposited(msg.sender, _amount);
        }

        updateRewardDebt();
    }

    /*
     * @notice Withdraw staked tokens
     * @param _amount: amount to withdraw (in rewardToken)
     */
    function withdraw(uint256 _amount) external nonReentrant {
        require(suspended == false, "suspended");
        require(_amount > 0, "zero amount");
        UserInfo storage user = userInfo[_msgSender()];
        require(user.amount >= _amount, "Amount to withdraw too high");
        require(totalStakings >= _amount, "Exceed total staking amount");

        updatePool();
        lockupReward();

        bool withdrawAvailable = canWithdraw(
            _msgSender(),
            _amount
        );
        require(withdrawAvailable, "Cannot withdraw");
        if (withdrawAvailable) {
            user.amount = user.amount - _amount;
            totalStakings = totalStakings - _amount;

            if (_amount > 0) {
                stakedToken.transfer(_msgSender(), _amount);
            }

            emit Withdrawn(_msgSender(), _amount);

        }

        updateRewardDebt();
    }

    /**
     * @notice View function to see if user can withdraw.
     */
    function canWithdraw(address _user, uint256 _amount)
        public
        view
        returns (bool _available)
    {
        UserInfo memory user = userInfo[_user];
        _available = user.amount >= _amount && suspended == false;
    }

    function claim() external {
        require(suspended == false, "suspended");
        UserInfo storage user = userInfo[_msgSender()];
        
        uint256 pending = pendingReward(_msgSender());

        bool _available = canHarvest(_msgSender(), pending);
        require(_available, "cannot claim");

        updatePool();
        lockupReward();

        uint256 reward = 0;
        for (uint256 i=0; i<itReward.rewardStartBlocks.length; i++) {
            uint256 key = itReward.rewardStartBlocks[i];
            reward += itReward.rewardDebts[_msgSender()][key].lockupReward;
            itReward.rewardDebts[_msgSender()][key].lockupReward = 0;
        }
        require(pending == reward, "something went wrong");

        rewardToken.transfer(_msgSender(), reward);

        user.rewardReceived += reward;

        user.lastHarvestedAt = block.number;
        if (totalLockedUpRewards >= reward) {
            totalLockedUpRewards -= reward;
        } else {
            totalLockedUpRewards = 0;
        }
        user.lockupReward = 0;
        updateRewardDebt();

        emit UserRewarded(_msgSender(), reward);
    }

    /**
     * @notice View function to see if user can harvest.
     */
    function canHarvest(address _user, uint256 _amount) public view 
        returns (bool _canHarvest) 
    {
        uint256 reward = pendingReward(_user);
        _canHarvest = reward >= _amount && suspended == false;
    }

    /**
     * @notice It allows the admin to recover wrong tokens sent to the contract
     * @param _tokenAddress: the address of the token to withdraw
     * @param _tokenAmount: the number of tokens to withdraw
     * @dev This function is only callable by admin.
     */
    function recoverWrongTokens(address _tokenAddress, uint256 _tokenAmount)
        external
        onlyOwner
    {
        require(
            _tokenAddress != address(stakedToken) &&
                _tokenAddress != address(rewardToken),
            "Cannot be staked token"
        );

        IERC20(_tokenAddress).transfer(address(msg.sender), _tokenAmount);

        emit AdminTokenRecovery(_tokenAddress, _tokenAmount);
    }

    /*
     * @notice Stop rewards
     * @dev Only callable by owner. Needs to be for emergency.
     */
    function emergencyRewardWithdraw(uint256 _amount) external onlyOwner {
        uint256 availableRewardAmount = rewardToken.balanceOf(address(this));
        // when staked token and reward token same, it should not occupy the staked amount
        if (address(stakedToken) == address(rewardToken)) {
            availableRewardAmount = availableRewardAmount - totalStakings;
        }
        require(availableRewardAmount >= _amount, "Too much amount");

        rewardToken.transfer(_msgSender(), _amount);
        emit EmergencyRewardWithdrawn(_msgSender(), _amount);
    }
}
