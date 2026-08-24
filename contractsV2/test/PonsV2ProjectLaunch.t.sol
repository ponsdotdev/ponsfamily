// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PonsV2BondingCurve} from "../src/v2/PonsV2BondingCurve.sol";
import {PonsV2BuybackVault} from "../src/v2/PonsV2BuybackVault.sol";
import {LaunchDeployment, PonsV2LaunchDeployer, ProjectTokenDeploymentData} from "../src/v2/PonsV2LaunchDeployer.sol";
import {PonsV2LauncherToken} from "../src/v2/PonsV2LauncherToken.sol";
import {FeePolicySnapshot, IPonsV2FeeEscrow, IPonsV2FeePolicy} from "../src/v2/interfaces/ILaunchpadV2.sol";
import {PonsProjectVotesToken} from "@sinjoh-v2/token/PonsProjectVotesToken.sol";
import {ProjectVotesTokenFactoryV2} from "@sinjoh-v2/token/ProjectVotesTokenFactoryV2.sol";

contract MockProjectRegistry {}

contract MockFeePolicy is IPonsV2FeePolicy {
    function protocolFeeShareBps() external pure returns (uint256) {
        return 1_000;
    }

    function buybackBurnBps() external pure returns (uint256) {
        return 0;
    }

    function protocolFeeRecipient() external pure returns (address) {
        return address(0xFEE);
    }

    function feeEscrow() external pure returns (IPonsV2FeeEscrow) {
        return IPonsV2FeeEscrow(address(0xE5C0));
    }

    function maxInternalPriceImpactBps() external pure returns (uint256) {
        return 500;
    }

    function feeSweepOperator() external pure returns (address) {
        return address(0x5EED);
    }

    function currentFeePolicy() external pure returns (FeePolicySnapshot memory) {
        return FeePolicySnapshot({
            protocolFeeRecipient: address(0xFEE),
            protocolFeeShareBps: 1_000,
            buybackBurnBps: 0,
            hookFeeBps: 100,
            maxInternalPriceImpactBps: 500
        });
    }
}

contract PonsV2ProjectLaunchTest is Test {
    address private constant CREATOR = address(0xC0FFEE);
    address private constant BUYER = address(0xB0B);
    uint256 private constant SUPPLY = 1_000_000e18;

    PonsV2LaunchDeployer private deployer;
    ProjectVotesTokenFactoryV2 private tokenFactory;
    MockProjectRegistry private registry;
    MockFeePolicy private feePolicy;

    function setUp() public {
        vm.warp(1_000);
        deployer = new PonsV2LaunchDeployer(address(this));
        tokenFactory = new ProjectVotesTokenFactoryV2();
        registry = new MockProjectRegistry();
        feePolicy = new MockFeePolicy();
    }

    function snipeTaxStartBps() external pure returns (uint256) {
        return 0;
    }

    function snipeTaxSeconds() external pure returns (uint256) {
        return 15;
    }

    function testProjectLaunchDeploysOnePonsAndGovernanceToken() public {
        LaunchDeployment memory launch = _launchDeployment();
        bytes memory projectData = _projectData(new address[](0));
        (, address predictedCurve) = deployer.predictProjectLaunchAddresses(launch, projectData);
        (address predictedToken, address curvePrediction) = deployer.predictProjectLaunchAddresses(launch, projectData);
        assertEq(curvePrediction, predictedCurve);

        (address tokenAddress, address curveAddress) = deployer.deployProjectLaunch(launch, projectData);
        assertEq(tokenAddress, predictedToken);
        assertEq(curveAddress, predictedCurve);

        PonsV2BondingCurve(curveAddress).initialize(tokenAddress);
        PonsProjectVotesToken token = PonsProjectVotesToken(tokenAddress);
        assertEq(token.curve(), curveAddress);
        assertEq(token.launchFactory(), address(this));
        assertEq(token.registry(), address(registry));
        assertEq(token.creator(), CREATOR);
        assertEq(token.deployer(), CREATOR);
        assertEq(token.votingExclusionConfigurator(), address(this));
        assertEq(token.initialSupply(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(curveAddress), SUPPLY);
        assertEq(token.eligibleVotingSupply(), SUPPLY);
        assertFalse(token.isVotingExcluded(curveAddress));

        address[] memory finalExclusions = new address[](1);
        finalExclusions[0] = curveAddress;
        token.finalizeVotingExclusions(finalExclusions);
        assertEq(token.eligibleVotingSupply(), 0);
        assertTrue(token.isVotingExcluded(curveAddress));

        vm.prank(curveAddress);
        IERC20(tokenAddress).transfer(BUYER, 10_000e18);
        assertEq(token.getVotes(BUYER), 10_000e18);
        assertEq(token.eligibleVotingSupply(), 10_000e18);
    }

    function _launchDeployment() private view returns (LaunchDeployment memory) {
        return LaunchDeployment({
            pairToken: address(0),
            creatorFeeRecipient: CREATOR,
            originalDeployer: CREATOR,
            feePolicy: feePolicy,
            policy: feePolicy.currentFeePolicy(),
            feeEscrow: IPonsV2FeeEscrow(address(0xE5C0)),
            buybackVault: PonsV2BuybackVault(address(0xBACC)),
            phantomQuote: 10 ether,
            curveFeeBps: 100,
            creatorTaxBps: 0,
            buybackEnabled: false,
            graduationThreshold: 100 ether,
            supply: SUPPLY,
            salt: keccak256("PROJECT_PONS"),
            name: "Project Pons",
            symbol: "PPONS",
            logo: "",
            description: "",
            socials: PonsV2LauncherToken.Socials({twitter: "", telegram: "", discord: "", website: "", farcaster: ""})
        });
    }

    function _projectData(address[] memory exclusions) private view returns (bytes memory) {
        return abi.encode(
            ProjectTokenDeploymentData({
                tokenFactory: address(tokenFactory),
                registry: address(registry),
                votingExclusionConfigurator: address(this),
                votingExclusions: exclusions
            })
        );
    }
}
