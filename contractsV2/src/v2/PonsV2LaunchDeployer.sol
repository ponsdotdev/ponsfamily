// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PonsV2LauncherToken} from "./PonsV2LauncherToken.sol";
import {PonsV2BondingCurve} from "./PonsV2BondingCurve.sol";
import {PonsV2BuybackVault} from "./PonsV2BuybackVault.sol";
import {FeePolicySnapshot, IPonsV2FeeEscrow, IPonsV2FeePolicy, SnipeTaxTerms} from "./interfaces/ILaunchpadV2.sol";

/**
 * @notice Every input PonsV2LaunchFactory hands the deployer to stand up one
 * launch. Grouped into a single calldata struct rather than a flat parameter
 * list so the deployer stays inside the EVM's 16-slot stack window when
 * compiled without the IR pipeline, which is the mode `forge coverage` uses.
 */
struct LaunchDeployment {
    address pairToken;
    address creatorFeeRecipient;
    address originalDeployer;
    IPonsV2FeePolicy feePolicy;
    FeePolicySnapshot policy;
    IPonsV2FeeEscrow feeEscrow;
    PonsV2BuybackVault buybackVault;
    uint256 phantomQuote;
    uint256 curveFeeBps;
    uint256 creatorTaxBps;
    bool buybackEnabled;
    uint256 graduationThreshold;
    SnipeTaxTerms snipeTax;
    uint256 supply;
    string name;
    string symbol;
    string logo;
    string description;
    PonsV2LauncherToken.Socials socials;
}

/**
 * @title PonsV2LaunchDeployer
 * @notice Deploys the bonding curve and launch token pair for one pons v2
 * launch on PonsV2LaunchFactory's behalf. Split out into its own contract
 * purely so PonsV2LaunchFactory's own bytecode stays under EIP-170's
 * 24576-byte deployed-code limit: embedding two full contracts' creation
 * code via `new` inside the factory itself was the single largest
 * contributor to its size. Both new contracts still record the real
 * factory's address explicitly (never this deployer's), since they gate
 * privileged calls on it.
 */
contract PonsV2LaunchDeployer {
    // Metadata is stored on the token and read back by unbounded-return view
    // functions, so an unbounded write here becomes a permanently unreadable
    // token: `socials()` returns all five strings at once and would run out
    // of gas or time out an RPC node. Bounding the write is the only place
    // the limit can be enforced, since the strings are immutable afterwards.
    uint256 private constant MAX_NAME_LENGTH = 64;
    uint256 private constant MAX_SYMBOL_LENGTH = 16;
    uint256 private constant MAX_LOGO_LENGTH = 512;
    uint256 private constant MAX_DESCRIPTION_LENGTH = 2048;
    uint256 private constant MAX_SOCIAL_LENGTH = 256;

    error NotFactory();
    error MetadataTooLong();

    address public immutable factory;

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    constructor(address factory_) {
        if (factory_ == address(0)) revert NotFactory();
        factory = factory_;
    }

    /**
     * @notice Deploys a fresh curve/token pair and returns both addresses.
     * Both contracts are told `factory` (not this deployer) is their
     * privileged caller. Wiring the curve to its token via `initialize()` is
     * left to the factory itself, since that call is `onlyFactory`-gated.
     */
    function deployLaunch(LaunchDeployment calldata params)
        external
        onlyFactory
        returns (address token, address curve)
    {
        _requireMetadataWithinLimits(params);

        curve = address(
            new PonsV2BondingCurve(
                params.pairToken,
                params.creatorFeeRecipient,
                factory,
                params.feePolicy,
                params.policy,
                params.feeEscrow,
                params.buybackVault,
                params.phantomQuote,
                params.curveFeeBps,
                params.creatorTaxBps,
                params.buybackEnabled,
                params.graduationThreshold,
                params.snipeTax
            )
        );
        token = address(
            new PonsV2LauncherToken(
                params.name,
                params.symbol,
                params.logo,
                params.description,
                params.socials,
                params.originalDeployer,
                curve,
                factory,
                params.supply
            )
        );
    }

    /**
     * @notice Reverts unless every metadata string fits its length cap.
     * @dev The factory already rejects an empty name or symbol, so only the
     * upper bound is checked here.
     */
    function _requireMetadataWithinLimits(LaunchDeployment calldata params) private pure {
        if (
            bytes(params.name).length > MAX_NAME_LENGTH || bytes(params.symbol).length > MAX_SYMBOL_LENGTH
                || bytes(params.logo).length > MAX_LOGO_LENGTH
                || bytes(params.description).length > MAX_DESCRIPTION_LENGTH
        ) {
            revert MetadataTooLong();
        }
        if (
            bytes(params.socials.twitter).length > MAX_SOCIAL_LENGTH
                || bytes(params.socials.telegram).length > MAX_SOCIAL_LENGTH
                || bytes(params.socials.discord).length > MAX_SOCIAL_LENGTH
                || bytes(params.socials.website).length > MAX_SOCIAL_LENGTH
                || bytes(params.socials.farcaster).length > MAX_SOCIAL_LENGTH
        ) {
            revert MetadataTooLong();
        }
    }
}
