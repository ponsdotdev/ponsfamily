// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PonsV2BondingCurve} from "./PonsV2BondingCurve.sol";
import {PonsV2LaunchFactory} from "./PonsV2LaunchFactory.sol";

/**
 * @title PonsV2LaunchRouter
 * @notice Creates a launch and takes its first position in one transaction.
 *
 * The opening-window levy in PonsV2BondingCurve makes a creator's own first
 * buy prohibitively expensive if it lands as a separate transaction, since
 * nothing distinguishes it from a bot's. Rather than weaken the window, this
 * router closes it for the one case that is provably not a race: the buy that
 * is atomic with the launch itself and therefore cannot have observed it.
 *
 * @dev A separate contract purely for bytecode budget. PonsV2LaunchFactory
 * already sits within a few hundred bytes of EIP-170's deployed-code limit,
 * and this logic would not fit alongside it.
 *
 * The owner must call `setTrustedRouter(address(this), true)` on the factory
 * before this contract works. That trust lets it attribute a launch to its
 * caller; it does not let it launch on behalf of someone who could not launch
 * themselves, because the factory still gates the named launcher through
 * `canLaunch`.
 */
contract PonsV2LaunchRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error NativeValueMismatch(uint256 supplied, uint256 expected);
    error UnexpectedNativeValue();
    error RefundFailed();

    event LaunchedAndBought(
        address indexed launcher, address indexed token, address curve, uint256 quoteIn, uint256 tokensOut
    );

    PonsV2LaunchFactory public immutable factory;

    /**
     * @dev Set to the curve for the duration of a buy and cleared immediately
     * after. The curve refunds an unfilled remainder to `msg.sender`, which is
     * this router, so the router has to be able to receive ETH — but only from
     * the curve it is mid-call with. Without the guard, `receive()` would be
     * an open door for value this contract has no way to attribute.
     */
    address private _refundSource;

    constructor(PonsV2LaunchFactory factory_) {
        if (address(factory_) == address(0)) revert ZeroAddress();
        factory = factory_;
    }

    receive() external payable {
        if (msg.sender != _refundSource) revert UnexpectedNativeValue();
    }

    /**
     * @notice Launches a token and immediately buys from its curve, exempt
     * from the opening window.
     *
     * @param quoteIn Amount of the quote asset to spend on the opening buy.
     * Zero launches without buying, which is a plain launch that still routes
     * the exemption list through.
     * @param recipient Receives the tokens, and is exempted from the window.
     * Exempting the recipient rather than the caller is what makes the
     * exemption non-transferable: a sniper cannot buy entry by routing
     * through an address that happens to be excused.
     *
     * @dev For a native-quote launch the caller sends `launchFee + quoteIn`.
     * For an ERC-20 quote they send `launchFee` and this contract pulls
     * `quoteIn` from them, so the router needs an allowance on the quote asset
     * rather than on the curve.
     */
    function launchAndBuy(
        PonsV2LaunchFactory.TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        uint256 quoteIn,
        uint256 minTokensOut,
        address recipient,
        address[] calldata snipeTaxExemptions
    ) external payable nonReentrant returns (address token, address curve, uint256 tokensOut) {
        if (recipient == address(0)) revert ZeroAddress();

        uint256 launchFee = factory.launchFee();
        bool nativeQuote = pairToken == address(0);
        uint256 expectedValue = nativeQuote ? launchFee + quoteIn : launchFee;
        if (msg.value != expectedValue) revert NativeValueMismatch(msg.value, expectedValue);

        // The factory prepends the launcher and the creator fee recipient, so
        // only the recipient and the caller's own list are passed on here.
        address[] memory exemptions = new address[](snipeTaxExemptions.length + 1);
        exemptions[0] = recipient;
        for (uint256 i = 0; i < snipeTaxExemptions.length; ++i) {
            exemptions[i + 1] = snipeTaxExemptions[i];
        }

        (token, curve) = factory.launchTokenFor{value: launchFee}(
            params, launchConfigId, pairToken, msg.sender, exemptions
        );

        if (quoteIn == 0) {
            emit LaunchedAndBought(msg.sender, token, curve, 0, 0);
            return (token, curve, 0);
        }

        _refundSource = curve;
        if (nativeQuote) {
            tokensOut = PonsV2BondingCurve(payable(curve)).buy{value: quoteIn}(quoteIn, minTokensOut, recipient);
        } else {
            IERC20 quote = IERC20(pairToken);
            quote.safeTransferFrom(msg.sender, address(this), quoteIn);
            // forceApprove rather than approve: the quote asset is only known
            // to be ERC-20-shaped, and a non-standard token may not return a
            // bool or may reject a non-zero-to-non-zero change.
            quote.forceApprove(curve, quoteIn);
            tokensOut = PonsV2BondingCurve(payable(curve)).buy(quoteIn, minTokensOut, recipient);
            // The curve pulls only what it fills, so a clamped fill leaves
            // both an allowance and a balance behind. Clearing the allowance
            // matters more than the dust: a standing approval on a curve
            // anyone can call is a liability that outlives this transaction.
            quote.forceApprove(curve, 0);
            uint256 remaining = quote.balanceOf(address(this));
            if (remaining != 0) quote.safeTransfer(msg.sender, remaining);
        }
        _refundSource = address(0);

        // A clamped fill refunds native quote to the caller of buy(), which is
        // this contract. Forwarding the whole balance rather than a computed
        // remainder means a rounding difference cannot strand value here.
        uint256 balance = address(this).balance;
        if (balance != 0) {
            (bool ok,) = msg.sender.call{value: balance}("");
            if (!ok) revert RefundFailed();
        }

        emit LaunchedAndBought(msg.sender, token, curve, quoteIn, tokensOut);
    }
}
