// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PonsV2LauncherToken} from "./PonsV2LauncherToken.sol";
import {PonsV2BondingCurve} from "./PonsV2BondingCurve.sol";
import {PonsV2BuybackVault} from "./PonsV2BuybackVault.sol";
import {FeePolicySnapshot, IPonsV2FeeEscrow, IPonsV2FeePolicy} from "./interfaces/ILaunchpadV2.sol";

interface IProjectVotesTokenFactoryV2 {
    struct Socials {
        string twitter;
        string telegram;
        string discord;
        string website;
        string farcaster;
    }

    struct TokenConfig {
        string name;
        string symbol;
        string logo;
        string description;
        Socials socials;
        address registry;
        address creator;
        address curve;
        address launchFactory;
        address votingExclusionConfigurator;
        uint256 supply;
        address[] votingExclusions;
    }

    struct PonsTokenDeployment {
        TokenConfig token;
        bytes32 salt;
    }

    function deployPons(PonsTokenDeployment calldata deployment) external returns (address token);
    function predictPons(PonsTokenDeployment calldata deployment, address launchpad)
        external
        view
        returns (address token);
}

interface IPonsProjectVotesToken {
    function registry() external view returns (address);
    function creator() external view returns (address);
    function deployer() external view returns (address);
    function launchFactory() external view returns (address);
    function curve() external view returns (address);
    function votingExclusionConfigurator() external view returns (address);
    function initialSupply() external view returns (uint256);
    function isVotingExcluded(address account) external view returns (bool);
}

struct ProjectTokenDeploymentData {
    address tokenFactory;
    address registry;
    address votingExclusionConfigurator;
    address[] votingExclusions;
}

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
    uint256 supply;
    bytes32 salt;
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
    error InvalidProjectToken(address token);

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

        bytes32 salt = _launchSalt(params);
        curve = Create2.deploy(0, salt, _curveCreationCode(params));
        token = Create2.deploy(0, salt, _tokenCreationCode(params, curve));
    }

    function deployProjectLaunch(LaunchDeployment calldata params, bytes calldata projectTokenData)
        external
        onlyFactory
        returns (address token, address curve)
    {
        _requireMetadataWithinLimits(params);
        ProjectTokenDeploymentData memory project = abi.decode(projectTokenData, (ProjectTokenDeploymentData));
        bytes32 salt = _launchSalt(params);
        curve = Create2.deploy(0, salt, _curveCreationCode(params));
        token = _deployProjectToken(params, curve, project);
    }

    function predictLaunchAddresses(LaunchDeployment calldata params)
        external
        view
        returns (address token, address curve)
    {
        bytes32 salt = _launchSalt(params);
        curve = Create2.computeAddress(salt, keccak256(_curveCreationCode(params)));
        token = Create2.computeAddress(salt, keccak256(_tokenCreationCode(params, curve)));
    }

    function predictProjectLaunchAddresses(LaunchDeployment calldata params, bytes calldata projectTokenData)
        external
        view
        returns (address token, address curve)
    {
        ProjectTokenDeploymentData memory project = abi.decode(projectTokenData, (ProjectTokenDeploymentData));
        bytes32 salt = _launchSalt(params);
        curve = Create2.computeAddress(salt, keccak256(_curveCreationCode(params)));
        token = IProjectVotesTokenFactoryV2(project.tokenFactory)
            .predictPons(_projectTokenDeployment(params, curve, project), address(this));
    }

    function _launchSalt(LaunchDeployment calldata params) private pure returns (bytes32) {
        return keccak256(abi.encode(params.originalDeployer, params.salt));
    }

    function _curveCreationCode(LaunchDeployment calldata params) private view returns (bytes memory) {
        return abi.encodePacked(
            type(PonsV2BondingCurve).creationCode,
            abi.encode(
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
                params.graduationThreshold
            )
        );
    }

    function _tokenCreationCode(LaunchDeployment calldata params, address curve) private view returns (bytes memory) {
        return abi.encodePacked(
            type(PonsV2LauncherToken).creationCode,
            abi.encode(
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

    function _deployProjectToken(
        LaunchDeployment calldata params,
        address curve,
        ProjectTokenDeploymentData memory project
    ) private returns (address token) {
        if (
            project.registry.code.length == 0 || project.tokenFactory.code.length == 0
                || project.votingExclusionConfigurator.code.length == 0
        ) {
            revert InvalidProjectToken(address(0));
        }
        token = IProjectVotesTokenFactoryV2(project.tokenFactory)
            .deployPons(_projectTokenDeployment(params, curve, project));
        IPonsProjectVotesToken projectToken = IPonsProjectVotesToken(token);
        if (
            token.code.length == 0 || projectToken.registry() != project.registry
                || projectToken.creator() != params.originalDeployer
                || projectToken.deployer() != params.originalDeployer || projectToken.launchFactory() != factory
                || projectToken.curve() != curve
                || projectToken.votingExclusionConfigurator() != project.votingExclusionConfigurator
                || projectToken.initialSupply() != params.supply || IERC20(token).totalSupply() != params.supply
                || IERC20(token).balanceOf(curve) != params.supply
        ) revert InvalidProjectToken(token);
    }

    function _projectTokenDeployment(
        LaunchDeployment calldata params,
        address curve,
        ProjectTokenDeploymentData memory project
    ) private view returns (IProjectVotesTokenFactoryV2.PonsTokenDeployment memory deployment) {
        PonsV2LauncherToken.Socials calldata socials = params.socials;
        deployment = IProjectVotesTokenFactoryV2.PonsTokenDeployment({
            token: IProjectVotesTokenFactoryV2.TokenConfig({
                name: params.name,
                symbol: params.symbol,
                logo: params.logo,
                description: params.description,
                socials: IProjectVotesTokenFactoryV2.Socials({
                    twitter: socials.twitter,
                    telegram: socials.telegram,
                    discord: socials.discord,
                    website: socials.website,
                    farcaster: socials.farcaster
                }),
                registry: project.registry,
                creator: params.originalDeployer,
                curve: curve,
                launchFactory: factory,
                votingExclusionConfigurator: project.votingExclusionConfigurator,
                supply: params.supply,
                votingExclusions: project.votingExclusions
            }),
            salt: params.salt
        });
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
