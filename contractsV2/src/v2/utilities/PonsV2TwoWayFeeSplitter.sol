// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPonsV2FeeEscrow} from "../interfaces/ILaunchpadV2.sol";

/**
 * @notice The two creator-only controls exposed by PonsV2LaunchFactory.
 */
interface IPonsV2CreatorControls {
    function transferCreatorFeeRecipient(address token, address newRecipient) external;
    function setBuybackEnabled(address token, bool enabled) external;
}

/**
 * @title PonsV2TwoWayFeeSplitter
 * @author bananawalnut
 * @notice Optional creator-fee recipient that splits native ETH and ERC-20
 * proceeds between two immutable recipients at an immutable ratio.
 *
 * @dev Pons v2 records this contract as `creatorFeeRecipient`. Anyone may
 * claim its accrued balance from the pons fee escrow, allocate direct or
 * forced transfers, and release either recipient's balance. No caller can
 * change the economic terms or redirect the held funds.
 *
 * An optional immutable controller preserves the two actions pons reserves
 * for the current creator fee recipient: transferring future creator fees
 * and enabling or disabling buybacks. Configure both `creatorControls_` and
 * `controller_` as zero to disable those actions permanently. A configured
 * controller cannot alter this splitter's recipients, ratio, or accrued
 * balances, and cannot replace itself.
 */
contract PonsV2TwoWayFeeSplitter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant BASIS_POINTS = 10_000;

    IPonsV2FeeEscrow public immutable feeEscrow;
    IPonsV2CreatorControls public immutable creatorControls;
    address public immutable controller;
    address payable public immutable recipientOne;
    address payable public immutable recipientTwo;
    uint16 public immutable recipientOneShareBps;
    uint16 public immutable recipientTwoShareBps;

    mapping(address recipient => uint256 amount) public pendingNative;
    mapping(address token => mapping(address recipient => uint256 amount)) public pendingToken;

    error ZeroAddress();
    error DuplicateRecipient();
    error InvalidShare();
    error InvalidControllerConfiguration();
    error NotController();
    error UnknownRecipient();
    error NothingToRelease();
    error NativeTransferFailed(address recipient, uint256 amount);
    error AccountingInvariant();

    event NativeAllocated(uint256 amount, uint256 recipientOneAmount, uint256 recipientTwoAmount);
    event TokenAllocated(address indexed token, uint256 amount, uint256 recipientOneAmount, uint256 recipientTwoAmount);
    event NativeReleased(address indexed recipient, uint256 amount);
    event TokenReleased(address indexed token, address indexed recipient, uint256 amount);
    event CreatorFeeRecipientTransferred(address indexed token, address indexed newRecipient);
    event BuybackEnabledSet(address indexed token, bool enabled);

    modifier onlyController() {
        _requireController();
        _;
    }

    constructor(
        IPonsV2FeeEscrow feeEscrow_,
        address payable recipientOne_,
        address payable recipientTwo_,
        uint16 recipientOneShareBps_,
        IPonsV2CreatorControls creatorControls_,
        address controller_
    ) {
        if (address(feeEscrow_) == address(0) || recipientOne_ == address(0) || recipientTwo_ == address(0)) {
            revert ZeroAddress();
        }
        if (recipientOne_ == recipientTwo_) revert DuplicateRecipient();
        if (recipientOneShareBps_ == 0 || recipientOneShareBps_ >= BASIS_POINTS) revert InvalidShare();

        bool controlsDisabled = address(creatorControls_) == address(0) && controller_ == address(0);
        bool controlsEnabled = address(creatorControls_) != address(0) && controller_ != address(0);
        if (!controlsDisabled && !controlsEnabled) revert InvalidControllerConfiguration();

        feeEscrow = feeEscrow_;
        recipientOne = recipientOne_;
        recipientTwo = recipientTwo_;
        recipientOneShareBps = recipientOneShareBps_;
        recipientTwoShareBps = BASIS_POINTS - recipientOneShareBps_;
        creatorControls = creatorControls_;
        controller = controller_;
    }

    receive() external payable {}

    /**
     * @notice Claims every native fee currently credited to the splitter and
     * allocates it together with any other unaccounted native balance.
     */
    function claimNativeFromPons() external nonReentrant returns (uint256 claimed, uint256 allocated) {
        claimed = feeEscrow.claim();
        allocated = _allocateNative();
    }

    /**
     * @notice Claims every `token` fee currently credited to the splitter and
     * allocates it together with any other unaccounted `token` balance.
     */
    function claimTokenFromPons(IERC20 token) external nonReentrant returns (uint256 claimed, uint256 allocated) {
        if (address(token) == address(0)) revert ZeroAddress();
        claimed = feeEscrow.claimToken(address(token));
        allocated = _allocateToken(token);
    }

    /**
     * @notice Allocates native ETH received outside `claimNativeFromPons`.
     */
    function allocateNative() external nonReentrant returns (uint256 allocated) {
        allocated = _allocateNative();
    }

    /**
     * @notice Allocates ERC-20s received outside `claimTokenFromPons`.
     */
    function allocateToken(IERC20 token) external nonReentrant returns (uint256 allocated) {
        if (address(token) == address(0)) revert ZeroAddress();
        allocated = _allocateToken(token);
    }

    /**
     * @notice Releases all accrued native ETH for either immutable recipient.
     * Anyone may call this function; the destination cannot be changed.
     */
    function releaseNative(address recipient) external nonReentrant returns (uint256 amount) {
        _requireRecipient(recipient);
        amount = pendingNative[recipient];
        if (amount == 0) revert NothingToRelease();

        pendingNative[recipient] = 0;
        (bool success,) = payable(recipient).call{value: amount}("");
        if (!success) revert NativeTransferFailed(recipient, amount);

        emit NativeReleased(recipient, amount);
    }

    /**
     * @notice Releases all accrued `token` for either immutable recipient.
     * Anyone may call this function; the destination cannot be changed.
     */
    function releaseToken(IERC20 token, address recipient) external nonReentrant returns (uint256 amount) {
        if (address(token) == address(0)) revert ZeroAddress();
        _requireRecipient(recipient);
        amount = pendingToken[address(token)][recipient];
        if (amount == 0) revert NothingToRelease();

        pendingToken[address(token)][recipient] = 0;
        token.safeTransfer(recipient, amount);

        emit TokenReleased(address(token), recipient, amount);
    }

    /**
     * @notice Directs future pons creator fees for `token` to `newRecipient`.
     * Existing balances credited to this splitter remain claimable here.
     */
    function transferCreatorFeeRecipient(address token, address newRecipient) external onlyController nonReentrant {
        if (token == address(0) || newRecipient == address(0)) revert ZeroAddress();
        creatorControls.transferCreatorFeeRecipient(token, newRecipient);
        emit CreatorFeeRecipientTransferred(token, newRecipient);
    }

    /**
     * @notice Enables or disables pons buyback-and-lock for `token`.
     */
    function setBuybackEnabled(address token, bool enabled) external onlyController nonReentrant {
        if (token == address(0)) revert ZeroAddress();
        creatorControls.setBuybackEnabled(token, enabled);
        emit BuybackEnabledSet(token, enabled);
    }

    function _allocateNative() private returns (uint256 amount) {
        uint256 accounted = pendingNative[recipientOne] + pendingNative[recipientTwo];
        uint256 balance = address(this).balance;
        if (balance < accounted) revert AccountingInvariant();

        amount = balance - accounted;
        if (amount == 0) return 0;

        (uint256 firstAmount, uint256 secondAmount) = _split(amount);
        pendingNative[recipientOne] += firstAmount;
        pendingNative[recipientTwo] += secondAmount;

        emit NativeAllocated(amount, firstAmount, secondAmount);
    }

    function _allocateToken(IERC20 token) private returns (uint256 amount) {
        uint256 accounted = pendingToken[address(token)][recipientOne] + pendingToken[address(token)][recipientTwo];
        uint256 balance = token.balanceOf(address(this));
        if (balance < accounted) revert AccountingInvariant();

        amount = balance - accounted;
        if (amount == 0) return 0;

        (uint256 firstAmount, uint256 secondAmount) = _split(amount);
        pendingToken[address(token)][recipientOne] += firstAmount;
        pendingToken[address(token)][recipientTwo] += secondAmount;

        emit TokenAllocated(address(token), amount, firstAmount, secondAmount);
    }

    function _split(uint256 amount) private view returns (uint256 firstAmount, uint256 secondAmount) {
        firstAmount = Math.mulDiv(amount, recipientOneShareBps, BASIS_POINTS);
        // Assign the indivisible remainder to recipient two so no dust is trapped.
        secondAmount = amount - firstAmount;
    }

    function _requireRecipient(address recipient) private view {
        if (recipient != recipientOne && recipient != recipientTwo) revert UnknownRecipient();
    }

    function _requireController() private view {
        if (msg.sender != controller || controller == address(0)) revert NotController();
    }
}
