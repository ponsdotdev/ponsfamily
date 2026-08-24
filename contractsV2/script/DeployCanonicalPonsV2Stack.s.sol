// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {PonsV2BuybackVault} from "../src/v2/PonsV2BuybackVault.sol";
import {PonsV2GraduationExecutor} from "../src/v2/PonsV2GraduationExecutor.sol";
import {PonsV2LaunchDeployer} from "../src/v2/PonsV2LaunchDeployer.sol";
import {PonsV2LaunchFactory} from "../src/v2/PonsV2LaunchFactory.sol";
import {PonsV2LaunchLocker} from "../src/v2/PonsV2LaunchLocker.sol";
import {PonsV2MemeHook} from "../src/v2/hooks/PonsV2MemeHook.sol";
import {IPonsV2FeeEscrow} from "../src/v2/interfaces/ILaunchpadV2.sol";

/// @notice Deploys the canonical-token-capable Pons V2 stack while preserving
/// the economics of the currently published Robinhood Chain deployment.
contract DeployCanonicalPonsV2Stack is Script {
    address private constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 private constant REQUIRED_HOOK_FLAGS =
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    uint256 private constant LAUNCH_FEE = 0.0005 ether;
    uint256 private constant SUPPLY = 1_000_000_000 ether;
    uint256 private constant CURVE_FEE_BPS = 100;
    uint256 private constant PHANTOM_QUOTE = 1.68 ether;
    uint256 private constant GRADUATION_THRESHOLD = 4.2 ether;
    uint24 private constant POOL_FEE = 0;
    int24 private constant TICK_SPACING = 200;

    function run()
        external
        returns (
            PonsV2LaunchFactory factory,
            PonsV2MemeHook hook,
            PonsV2LaunchLocker locker,
            PonsV2BuybackVault buybackVault,
            PonsV2GraduationExecutor graduationExecutor,
            PonsV2LaunchDeployer launchDeployer
        )
    {
        require(block.chainid == 4_663, "WRONG_CHAIN");

        address broadcaster = vm.envAddress("DEPLOYER_ADDRESS");
        IPoolManager poolManager = IPoolManager(vm.envAddress("V4_POOL_MANAGER"));
        IPositionManager positionManager = IPositionManager(vm.envAddress("V4_POSITION_MANAGER"));
        IAllowanceTransfer permit2 = IAllowanceTransfer(vm.envAddress("PERMIT2"));
        IPonsV2FeeEscrow feeEscrow = IPonsV2FeeEscrow(vm.envAddress("PONS_FEE_ESCROW"));
        address protocolFeeRecipient = vm.envAddress("PONS_PROTOCOL_FEE_RECIPIENT");
        address feeSweepOperator = vm.envAddress("PONS_FEE_SWEEP_OPERATOR");

        bytes memory hookCreationCode = abi.encodePacked(
            type(PonsV2MemeHook).creationCode, abi.encode(poolManager, feeEscrow, protocolFeeRecipient, broadcaster)
        );
        (bytes32 hookSalt, address predictedHook) = _mineHook(hookCreationCode);

        vm.startBroadcast();
        hook = PonsV2MemeHook(payable(_deployCreate2(hookSalt, hookCreationCode)));
        require(address(hook) == predictedHook, "HOOK_ADDRESS_MISMATCH");

        locker = new PonsV2LaunchLocker(broadcaster, address(positionManager));
        buybackVault = new PonsV2BuybackVault(broadcaster, hook, feeEscrow);
        factory = new PonsV2LaunchFactory(
            broadcaster, poolManager, positionManager, permit2, locker, hook, feeEscrow, buybackVault, LAUNCH_FEE
        );
        graduationExecutor = new PonsV2GraduationExecutor(positionManager, permit2, locker, address(factory));
        launchDeployer = new PonsV2LaunchDeployer(address(factory));

        hook.setFactory(address(factory));
        hook.setBuybackVault(buybackVault);
        hook.setFeeSweepOperator(feeSweepOperator);
        locker.setFactory(address(factory));
        buybackVault.setFactory(address(factory));
        factory.setGraduationExecutor(graduationExecutor);
        factory.setLaunchDeployer(launchDeployer);
        factory.addLaunchConfig(
            PonsV2LaunchFactory.LaunchConfig({
                supply: SUPPLY,
                curveFeeBps: CURVE_FEE_BPS,
                phantomQuote: PHANTOM_QUOTE,
                graduationThreshold: GRADUATION_THRESHOLD,
                poolFee: POOL_FEE,
                tickSpacing: TICK_SPACING,
                enabled: true
            })
        );
        factory.setSnipeTaxSeconds(3);
        factory.setLaunchEnabled(true);
        vm.stopBroadcast();

        _verify(factory, hook, locker, buybackVault, graduationExecutor, launchDeployer, feeEscrow);
        console2.log("PonsV2LaunchFactory", address(factory));
        console2.log("PonsV2MemeHook", address(hook));
        console2.log("PonsV2LaunchLocker", address(locker));
        console2.log("PonsV2BuybackVault", address(buybackVault));
        console2.log("PonsV2GraduationExecutor", address(graduationExecutor));
        console2.log("PonsV2LaunchDeployer", address(launchDeployer));
        console2.logBytes32(hookSalt);
    }

    function _mineHook(bytes memory creationCode) private pure returns (bytes32 salt, address hook) {
        bytes32 creationCodeHash = keccak256(creationCode);
        for (uint256 i;; ++i) {
            salt = bytes32(i);
            hook = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, creationCodeHash))))
            );
            if (uint160(hook) & Hooks.ALL_HOOK_MASK == REQUIRED_HOOK_FLAGS) return (salt, hook);
        }
    }

    function _deployCreate2(bytes32 salt, bytes memory creationCode) private returns (address deployed) {
        (bool ok, bytes memory result) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, creationCode));
        require(ok && result.length == 20, "CREATE2_DEPLOYMENT_FAILED");
        assembly ("memory-safe") {
            deployed := shr(96, mload(add(result, 0x20)))
        }
        require(deployed.code.length != 0, "HOOK_NOT_DEPLOYED");
    }

    function _verify(
        PonsV2LaunchFactory factory,
        PonsV2MemeHook hook,
        PonsV2LaunchLocker locker,
        PonsV2BuybackVault buybackVault,
        PonsV2GraduationExecutor graduationExecutor,
        PonsV2LaunchDeployer launchDeployer,
        IPonsV2FeeEscrow feeEscrow
    ) private view {
        require(address(factory).code.length != 0 && address(hook).code.length != 0, "MISSING_CODE");
        require(address(factory.memeHook()) == address(hook), "HOOK_BINDING_MISMATCH");
        require(address(factory.feeEscrow()) == address(feeEscrow), "ESCROW_BINDING_MISMATCH");
        require(address(factory.locker()) == address(locker), "LOCKER_BINDING_MISMATCH");
        require(address(factory.buybackVault()) == address(buybackVault), "VAULT_BINDING_MISMATCH");
        require(address(factory.graduationExecutor()) == address(graduationExecutor), "EXECUTOR_BINDING_MISMATCH");
        require(address(factory.launchDeployer()) == address(launchDeployer), "DEPLOYER_BINDING_MISMATCH");
        require(
            hook.factory() == address(factory) && address(hook.buybackVault()) == address(buybackVault),
            "HOOK_NOT_WIRED"
        );
        require(locker.factory() == address(factory) && buybackVault.factory() == address(factory), "CUSTODY_NOT_WIRED");
        require(factory.launchEnabled() && factory.launchConfigCount() == 1, "LAUNCH_NOT_ENABLED");
        require(factory.snipeTaxSeconds() == 3 && factory.launchFee() == LAUNCH_FEE, "POLICY_MISMATCH");
    }
}
