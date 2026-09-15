// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title PonsV2StakingBETA
 *
 * @notice
 * Standalone experimental beta staking module for Pons V2.
 *
 * IMPORTANT:
 * This beta deployment is intentionally DISABLED.
 *
 * No public user can stake, withdraw, claim rewards, compound,
 * exit or perform any other state-changing staking operation.
 *
 * Only the deployer/owner can interact with administrative functions.
 *
 * The staking engine is therefore deployed as a dormant beta
 * contract for development, verification and future testing.
 *
 * This contract does not modify the production Pons V2 contracts.
 */
contract PonsV2StakingBETA is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 public constant PRECISION = 1e18;
    uint256 public constant YEAR = 365 days;

    uint256 public constant DEFAULT_REWARD_DURATION = 30 days;
    uint256 public constant MAX_REWARD_DURATION = 365 days;
    uint256 public constant MAX_REWARD_RATE = 1e24;

    /**
     * @notice
     * Global staking switch.
     *
     * This beta deployment starts disabled.
     *
     * It is intentionally immutable so that staking cannot accidentally
     * be enabled on this beta contract after deployment.
     */
    bool public constant stakingEnabled = false;

    // -------------------------------------------------------------------------
    // Immutable configuration
    // -------------------------------------------------------------------------

    /**
     * @notice Token used for staking and rewards.
     */
    IERC20 public immutable stakingToken;

    /**
     * @notice Address allowed to fund reward emissions.
     *
     * On the beta deployment this is the deployer.
     */
    address public rewardDistributor;

    // -------------------------------------------------------------------------
    // Global staking state
    // -------------------------------------------------------------------------

    uint256 public totalStaked;
    uint256 public totalRewardsPaid;
    uint256 public totalRewardsFunded;

    uint256 public rewardRate;
    uint256 public periodFinish;
    uint256 public lastUpdateTime;

    uint256 public rewardPerTokenStored;

    // -------------------------------------------------------------------------
    // User state
    // -------------------------------------------------------------------------

    mapping(address => uint256) public balanceOf;

    mapping(address => uint256) public rewards;

    mapping(address => uint256) public userRewardPerTokenPaid;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event Staked(
        address indexed account,
        uint256 amount,
        uint256 totalStaked
    );

    event Withdrawn(
        address indexed account,
        uint256 amount,
        uint256 totalStaked
    );

    event RewardPaid(
        address indexed account,
        uint256 reward
    );

    event RewardAdded(
        uint256 amount,
        uint256 rewardRate,
        uint256 duration,
        uint256 periodFinish
    );

    event RewardDistributorUpdated(
        address indexed previousDistributor,
        address indexed newDistributor
    );

    event Recovered(
        address indexed token,
        address indexed recipient,
        uint256 amount
    );

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /**
     * @notice
     * Deploys PonsV2StakingBETA.
     *
     * The deployer automatically becomes the owner.
     *
     * No external address can be assigned ownership during deployment.
     *
     * @param _stakingToken Pons token used for the beta staking system.
     */
    constructor(
        address _stakingToken
    )
        Ownable(msg.sender)
    {
        require(
            _stakingToken != address(0),
            "PonsV2StakingBETA: zero token"
        );

        stakingToken = IERC20(_stakingToken);

        // The deployer is the only reward distributor.
        rewardDistributor = msg.sender;
    }

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    /**
     * @dev Updates global and user reward accounting.
     */
    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();

        lastUpdateTime = lastTimeRewardApplicable();

        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }

        _;
    }

    /**
     * @dev Only the deployer/owner can perform administrative operations.
     */
    modifier onlyDeployer() {
        require(
            msg.sender == owner(),
            "PonsV2StakingBETA: deployer only"
        );
        _;
    }

    /**
     * @dev Explicitly blocks every public staking operation.
     */
    modifier stakingDisabled() {
        require(
            stakingEnabled,
            "PonsV2StakingBETA: staking disabled"
        );
        _;
    }

    // -------------------------------------------------------------------------
    // Staking
    // -------------------------------------------------------------------------

    /**
     * @notice
     * Stake Pons tokens.
     *
     * DISABLED in PonsV2StakingBETA.
     */
    function stake(
        uint256
    )
        external
        pure
    {
        revert("PonsV2StakingBETA: staking disabled");
    }

    /**
     * @notice
     * Withdraw staked Pons.
     *
     * DISABLED for public users.
     *
     * Only the deployer can call this function on the beta contract.
     */
    function withdraw(
        uint256 amount
    )
        public
        nonReentrant
        onlyDeployer
        updateReward(msg.sender)
    {
        require(
            amount > 0,
            "PonsV2StakingBETA: zero amount"
        );

        require(
            balanceOf[msg.sender] >= amount,
            "PonsV2StakingBETA: insufficient stake"
        );

        balanceOf[msg.sender] -= amount;
        totalStaked -= amount;

        stakingToken.safeTransfer(
            msg.sender,
            amount
        );

        emit Withdrawn(
            msg.sender,
            amount,
            totalStaked
        );
    }

    /**
     * @notice
     * Claim accumulated staking rewards.
     *
     * DISABLED for public users.
     */
    function getReward()
        public
        nonReentrant
        onlyDeployer
        updateReward(msg.sender)
    {
        uint256 reward = rewards[msg.sender];

        require(
            reward > 0,
            "PonsV2StakingBETA: no rewards"
        );

        rewards[msg.sender] = 0;
        totalRewardsPaid += reward;

        stakingToken.safeTransfer(
            msg.sender,
            reward
        );

        emit RewardPaid(
            msg.sender,
            reward
        );
    }

    /**
     * @notice
     * Withdraw stake and claim rewards.
     *
     * Only the deployer can call this beta function.
     */
    function exit()
        external
        nonReentrant
        onlyDeployer
        updateReward(msg.sender)
    {
        uint256 staked = balanceOf[msg.sender];
        uint256 reward = rewards[msg.sender];

        require(
            staked > 0 || reward > 0,
            "PonsV2StakingBETA: nothing to exit"
        );

        if (staked > 0) {
            balanceOf[msg.sender] = 0;
            totalStaked -= staked;
        }

        if (reward > 0) {
            rewards[msg.sender] = 0;
            totalRewardsPaid += reward;
        }

        if (staked > 0) {
            stakingToken.safeTransfer(
                msg.sender,
                staked
            );
        }

        if (reward > 0) {
            stakingToken.safeTransfer(
                msg.sender,
                reward
            );
        }

        if (staked > 0) {
            emit Withdrawn(
                msg.sender,
                staked,
                totalStaked
            );
        }

        if (reward > 0) {
            emit RewardPaid(
                msg.sender,
                reward
            );
        }
    }

    /**
     * @notice
     * Compound accumulated rewards.
     *
     * DISABLED in the beta deployment.
     */
    function compound()
        external
        pure
    {
        revert("PonsV2StakingBETA: staking disabled");
    }

    // -------------------------------------------------------------------------
    // Reward engine
    // -------------------------------------------------------------------------

    /**
     * @notice Returns the last timestamp relevant for reward emission.
     */
    function lastTimeRewardApplicable()
        public
        view
        returns (uint256)
    {
        return block.timestamp < periodFinish
            ? block.timestamp
            : periodFinish;
    }

    /**
     * @notice Returns accumulated reward per staked token.
     */
    function rewardPerToken()
        public
        view
        returns (uint256)
    {
        if (totalStaked == 0) {
            return rewardPerTokenStored;
        }

        uint256 elapsed =
            lastTimeRewardApplicable() - lastUpdateTime;

        return rewardPerTokenStored
            + (
                elapsed
                * rewardRate
                * PRECISION
                / totalStaked
            );
    }

    /**
     * @notice Returns a user's currently accrued rewards.
     */
    function earned(
        address account
    )
        public
        view
        returns (uint256)
    {
        return
            (
                balanceOf[account]
                * (
                    rewardPerToken()
                    - userRewardPerTokenPaid[account]
                )
                / PRECISION
            )
            + rewards[account];
    }

    // -------------------------------------------------------------------------
    // Reward funding
    // -------------------------------------------------------------------------

    /**
     * @notice
     * Internal reward funding implementation.
     */
    function _notifyRewardAmount(
        uint256 amount,
        uint256 duration
    )
        internal
        updateReward(address(0))
    {
        require(
            amount > 0,
            "PonsV2StakingBETA: zero reward"
        );

        require(
            duration > 0 &&
            duration <= MAX_REWARD_DURATION,
            "PonsV2StakingBETA: invalid duration"
        );

        uint256 leftover;

        if (block.timestamp < periodFinish) {
            leftover =
                (periodFinish - block.timestamp)
                * rewardRate;
        }

        uint256 totalReward =
            amount + leftover;

        uint256 newRewardRate =
            totalReward / duration;

        require(
            newRewardRate > 0,
            "PonsV2StakingBETA: rate too low"
        );

        require(
            newRewardRate <= MAX_REWARD_RATE,
            "PonsV2StakingBETA: rate too high"
        );

        stakingToken.safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );

        rewardRate = newRewardRate;
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + duration;

        totalRewardsFunded += amount;

        emit RewardAdded(
            amount,
            newRewardRate,
            duration,
            periodFinish
        );
    }

    /**
     * @notice
     * Fund a reward period.
     *
     * ONLY THE DEPLOYER CAN CALL THIS FUNCTION.
     *
     * NOTE:
     * Staking itself remains disabled.
     */
    function notifyRewardAmount(
        uint256 amount,
        uint256 duration
    )
        external
        nonReentrant
        onlyDeployer
    {
        _notifyRewardAmount(
            amount,
            duration
        );
    }

    /**
     * @notice
     * Convenience function using the default 30-day duration.
     *
     * ONLY THE DEPLOYER CAN CALL THIS FUNCTION.
     */
    function notifyRewardAmount(
        uint256 amount
    )
        external
        nonReentrant
        onlyDeployer
    {
        _notifyRewardAmount(
            amount,
            DEFAULT_REWARD_DURATION
        );
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /**
     * @notice Estimated annualized APY.
     *
     * This is only an informational value.
     */
    function estimatedAPY()
        external
        view
        returns (uint256 apyBps)
    {
        if (totalStaked == 0) {
            return 0;
        }

        apyBps =
            rewardRate
            * YEAR
            * 10_000
            / totalStaked;
    }

    /**
     * @notice Returns a user's stake and accrued reward.
     */
    function position(
        address account
    )
        external
        view
        returns (
            uint256 staked,
            uint256 pendingRewards,
            uint256 totalPosition
        )
    {
        staked = balanceOf[account];
        pendingRewards = earned(account);
        totalPosition = staked + pendingRewards;
    }

    /**
     * @notice Returns the amount of staking tokens held by the contract.
     */
    function rewardBalance()
        external
        view
        returns (uint256)
    {
        return stakingToken.balanceOf(
            address(this)
        );
    }

    /**
     * @notice Returns currently committed undistributed rewards.
     */
    function remainingRewardAllocation()
        public
        view
        returns (uint256)
    {
        if (block.timestamp >= periodFinish) {
            return 0;
        }

        return
            (periodFinish - block.timestamp)
            * rewardRate;
    }

    /**
     * @notice Returns whether the reward period is active.
     */
    function rewardPeriodActive()
        external
        view
        returns (bool)
    {
        return
            block.timestamp < periodFinish &&
            rewardRate > 0;
    }

    /**
     * @notice Returns current beta configuration.
     */
    function configuration()
        external
        view
        returns (
            address token,
            address distributor,
            uint256 currentRewardRate,
            uint256 currentPeriodFinish,
            uint256 currentTotalStaked,
            bool currentStakingEnabled
        )
    {
        token = address(stakingToken);
        distributor = rewardDistributor;
        currentRewardRate = rewardRate;
        currentPeriodFinish = periodFinish;
        currentTotalStaked = totalStaked;
        currentStakingEnabled = stakingEnabled;
    }

    // -------------------------------------------------------------------------
    // Administration
    // -------------------------------------------------------------------------

    /**
     * @notice
     * Update reward distributor.
     *
     * ONLY THE DEPLOYER CAN CALL THIS FUNCTION.
     */
    function setRewardDistributor(
        address newDistributor
    )
        external
        onlyDeployer
    {
        require(
            newDistributor != address(0),
            "PonsV2StakingBETA: zero distributor"
        );

        address previous =
            rewardDistributor;

        rewardDistributor =
            newDistributor;

        emit RewardDistributorUpdated(
            previous,
            newDistributor
        );
    }

    /**
     * @notice
     * Pause the beta contract.
     *
     * ONLY THE DEPLOYER CAN CALL THIS FUNCTION.
     */
    function pause()
        external
        onlyDeployer
    {
        _pause();
    }

    /**
     * @notice
     * Unpause the beta contract.
     *
     * ONLY THE DEPLOYER CAN CALL THIS FUNCTION.
     */
    function unpause()
        external
        onlyDeployer
    {
        _unpause();
    }

    /**
     * @notice
     * Recover unrelated ERC20 tokens.
     *
     * ONLY THE DEPLOYER CAN CALL THIS FUNCTION.
     *
     * The staking token itself cannot be recovered.
     */
    function recoverERC20(
        address token,
        uint256 amount
    )
        external
        onlyDeployer
    {
        require(
            token != address(stakingToken),
            "PonsV2StakingBETA: cannot recover staking token"
        );

        IERC20(token).safeTransfer(
            owner(),
            amount
        );

        emit Recovered(
            token,
            owner(),
            amount
        );
    }

    // -------------------------------------------------------------------------
    // Emergency withdrawal
    // -------------------------------------------------------------------------

    /**
     * @notice
     * Emergency withdrawal.
     *
     * ONLY THE DEPLOYER CAN CALL THIS FUNCTION.
     *
     * Public users cannot use this function.
     */
    function emergencyWithdraw()
        external
        nonReentrant
        onlyDeployer
    {
        uint256 amount =
            balanceOf[msg.sender];

        require(
            amount > 0,
            "PonsV2StakingBETA: no stake"
        );

        balanceOf[msg.sender] = 0;
        totalStaked -= amount;

        rewards[msg.sender] = 0;

        userRewardPerTokenPaid[msg.sender] =
            rewardPerTokenStored;

        stakingToken.safeTransfer(
            msg.sender,
            amount
        );

        emit Withdrawn(
            msg.sender,
            amount,
            totalStaked
        );
    }

    // -------------------------------------------------------------------------
    // ETH handling
    // -------------------------------------------------------------------------

    receive()
        external
        payable
    {
        revert("PonsV2StakingBETA: no ETH");
    }

    fallback()
        external
        payable
    {
        revert("PonsV2StakingBETA: invalid call");
    }
}
