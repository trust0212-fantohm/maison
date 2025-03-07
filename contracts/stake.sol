// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract Stake is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    ERC20Upgradeable public stakeToken;
    ERC20Upgradeable public rewardToken;

    uint256 public rewardInterval;
    uint256 public rewardsRatioNumerator;
    uint256 public rewardsRatioDenominator;
    uint256 public minStakingPeriod;
    uint256 public maxStakingPeriod;

    address[] public stakers;

    mapping(address => mapping(uint256 => StakeInfo)) public stakeInfos;
    mapping(address => uint256) public stakedCount;

    struct StakeInfo {
        uint256 startTS;
        uint256 amount;
        uint256 lastClaimedTS;
        uint256 totalRewards;
        bool isActive;
    }

    event Staked(address indexed from, uint256 amount);
    event Unstaked(address indexed from, uint256 amount);
    event Claimed(address indexed from, uint256 amount);

    function initialize(
        address _stakeToken,
        address _rewardToken,
        uint256 _rewardInterval,
        uint256 _rewardsRatioNumerator,
        uint256 _rewardsRatioDenominator,
        uint256 _minStakingPeriod,
        uint256 _maxStakingPeriod
    ) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __Pausable_init();
        stakeToken = ERC20Upgradeable(_stakeToken);
        rewardToken = ERC20Upgradeable(_rewardToken);
        rewardInterval = _rewardInterval;
        rewardsRatioNumerator = _rewardsRatioNumerator;
        rewardsRatioDenominator = _rewardsRatioDenominator;
        minStakingPeriod = _minStakingPeriod;
        maxStakingPeriod = _maxStakingPeriod;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unPause() external onlyOwner {
        _unpause();
    }

    function setStakeToken(address _stakeToken) external onlyOwner {
        stakeToken = ERC20Upgradeable(_stakeToken);
    }

    function setRewardToken(address _rewardToken) external onlyOwner {
        rewardToken = ERC20Upgradeable(_rewardToken);
    }

    function setRewardInterval(uint256 _rewardInterval) external onlyOwner {
        require(_rewardInterval > 0, "Invalid Interval");
        rewardInterval = _rewardInterval;
    }

    function setRewardsRatioNumerator(
        uint256 _rewardsRatioNumerator
    ) external onlyOwner {
        require(_rewardsRatioNumerator > 0, "Invalid rewardsRatioNumerator");
        rewardsRatioNumerator = _rewardsRatioNumerator;
    }

    function setRewardsRatioDenominator(
        uint256 _rewardsRatioDenominator
    ) external onlyOwner {
        require(
            _rewardsRatioDenominator > 0,
            "Invalid rewardsRatioDenominator"
        );
        rewardsRatioDenominator = _rewardsRatioDenominator;
    }

    function setMinStakingPeriod(uint256 _minStakingPeriod) external onlyOwner {
        require(_minStakingPeriod > 0, "Invalid minStakingPeriod");
        minStakingPeriod = _minStakingPeriod;
    }

    function setMaxStakingPeriod(uint256 _maxStakingPeriod) external onlyOwner {
        require(_maxStakingPeriod > 0, "Invalid maxStakingPeriod");
        maxStakingPeriod = _maxStakingPeriod;
    }

    function stake(
        uint256 _stakeAmount
    ) external nonReentrant whenNotPaused returns (bool) {
        require(_stakeAmount > 0, "Stake amount should be correct");
        require(
            stakeToken.balanceOf(_msgSender()) >= _stakeAmount,
            "Insufficient Balance"
        );

        stakeToken.transferFrom(_msgSender(), address(this), _stakeAmount);

        uint256 id = stakedCount[msg.sender];

        stakeInfos[_msgSender()][id] = StakeInfo({
            startTS: block.timestamp,
            lastClaimedTS: block.timestamp,
            amount: _stakeAmount,
            totalRewards: 0,
            isActive: true
        });

        if (stakedCount[msg.sender] == 0) {
            stakers.push(msg.sender);
        }

        stakedCount[msg.sender]++;
        emit Staked(_msgSender(), _stakeAmount);

        return true;
    }

    function getTotalActiveRewards() public view returns (uint256) {
        uint256 totalActiveRewards = 0;

        for (uint256 i = 0; i < stakers.length; i++) {
            totalActiveRewards += getRewardsByUser(stakers[i]);
        }

        return totalActiveRewards;
    }

    function claim(
        uint256 _id
    ) external nonReentrant whenNotPaused returns (bool) {
        require(stakedCount[msg.sender] > 0, "You are not staked");
        StakeInfo storage stakeInfo = stakeInfos[_msgSender()][_id];

        require(stakeInfo.amount > 0, "Wrong ID");
        require(stakeInfo.isActive, "Stake is inactive");

        require(
            block.timestamp >= stakeInfo.lastClaimedTS + minStakingPeriod,
            "Already claimed"
        );

        uint256 rewardTokens = getRewardsByID(_msgSender(), _id);

        require(
            rewardToken.balanceOf(address(this)) >= rewardTokens,
            "Not enough rewards to claim"
        );

        stakeInfo.totalRewards += rewardTokens;

        rewardToken.transfer(_msgSender(), rewardTokens);

        stakeInfo.lastClaimedTS = block.timestamp;
        emit Claimed(_msgSender(), rewardTokens);

        return true;
    }

    function unStake(
        uint256 _id
    ) external nonReentrant whenNotPaused returns (bool) {
        require(stakedCount[msg.sender] > 0, "You are not staked");

        StakeInfo storage stakeInfo = stakeInfos[_msgSender()][_id];
        require(stakeInfo.amount > 0, "Wrong ID");
        require(stakeInfo.isActive, "Stake is inactive");

        bool isMinPeriodElapsed = block.timestamp >=
            stakeInfo.startTS + minStakingPeriod;

        uint256 totalAmount;

        if (isMinPeriodElapsed) {
            uint256 rewardTokens = getRewardsByID(_msgSender(), _id);
            stakeInfo.totalRewards += rewardTokens;
            totalAmount = stakeInfo.amount + rewardTokens;
        } else {
            totalAmount = stakeInfo.amount;
        }

        uint256 contractBalance = stakeToken.balanceOf(address(this));
        require(
            contractBalance >= totalAmount,
            "Contract balance is insufficient"
        );

        stakeToken.transfer(_msgSender(), totalAmount);

        stakeInfo.lastClaimedTS = block.timestamp;
        stakeInfo.isActive = false;

        emit Unstaked(_msgSender(), stakeInfo.amount);

        return true;
    }

    function getRewardsByID(
        address user,
        uint256 _id
    ) public view returns (uint256) {
        StakeInfo memory stakeInfo = stakeInfos[user][_id];

        if (!stakeInfo.isActive) {
            return 0;
        }

        uint256 rewardTokens;
        uint256 stakeAmount = stakeInfo.amount;

        if (block.timestamp <= stakeInfo.startTS + maxStakingPeriod) {
            rewardTokens =
                (stakeAmount *
                    rewardsRatioNumerator *
                    (block.timestamp - stakeInfo.lastClaimedTS)) /
                (rewardsRatioDenominator * rewardInterval);
        } else if (
            stakeInfo.lastClaimedTS <= stakeInfo.startTS + maxStakingPeriod
        ) {
            rewardTokens =
                (stakeAmount *
                    rewardsRatioNumerator *
                    (stakeInfo.startTS +
                        maxStakingPeriod -
                        stakeInfo.lastClaimedTS)) /
                (rewardsRatioDenominator * rewardInterval);
        } else {
            rewardTokens = 0;
        }
        return rewardTokens;
    }

    function getRewardsByUser(address user) public view returns (uint256) {
        uint256 totalRewards = 0;
        uint256 count = stakedCount[user];

        for (uint256 i = 0; i < count; i++) {
            StakeInfo memory stakeInfo = stakeInfos[user][i];

            if (stakeInfo.isActive) {
                totalRewards += getRewardsByID(user, i);
            }
        }

        return totalRewards;
    }

    struct StakeDetails {
        uint256 id;
        uint256 startDate;
        uint256 endDate;
        uint256 totalRewards;
    }

    function getUserStakes(
        address user
    )
        public
        view
        returns (
            StakeDetails[] memory activeStakes,
            StakeDetails[] memory inactiveStakes
        )
    {
        uint256 activeCount = 0;
        uint256 inactiveCount = 0;

        for (uint256 i = 0; i < stakedCount[user]; i++) {
            if (stakeInfos[user][i].isActive) {
                activeCount++;
            } else {
                inactiveCount++;
            }
        }

        activeStakes = new StakeDetails[](activeCount);
        inactiveStakes = new StakeDetails[](inactiveCount);

        uint256 activeIndex = 0;
        uint256 inactiveIndex = 0;

        for (uint256 i = 0; i < stakedCount[user]; i++) {
            StakeInfo memory stakeInfo = stakeInfos[user][i];

            if (stakeInfo.isActive) {
                activeStakes[activeIndex] = StakeDetails(
                    i,
                    stakeInfo.startTS,
                    0,
                    stakeInfo.totalRewards
                );
                activeIndex++;
            } else {
                inactiveStakes[inactiveIndex] = StakeDetails(
                    i,
                    stakeInfo.startTS,
                    stakeInfo.lastClaimedTS,
                    stakeInfo.totalRewards
                );
                inactiveIndex++;
            }
        }

        return (activeStakes, inactiveStakes);
    }

    function withdrawTokens(uint256 _amount) external onlyOwner {
        stakeToken.transfer(owner(), _amount);
    }

    function getContractTokenBalance() public view returns (uint256) {
        return stakeToken.balanceOf(address(this));
    }

    function getTotalStakedAmount() public view returns (uint256) {
        uint256 totalStakedAmount = 0;

        for (uint256 i = 0; i < stakers.length; i++) {
            address user = stakers[i];
            uint256 count = stakedCount[user];

            for (uint256 j = 0; j < count; j++) {
                StakeInfo memory stakeInfo = stakeInfos[user][j];
                if (stakeInfo.isActive) {
                    totalStakedAmount += stakeInfo.amount;
                }
            }
        }

        return totalStakedAmount;
    }
}
