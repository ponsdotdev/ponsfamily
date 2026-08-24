// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

interface IOwnable2StepTarget {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function transferOwnership(address newOwner) external;
}

/// @notice Initiates the reviewed two-step ownership handoff for every
/// owner-controlled contract in the canonical Pons V2 production stack.
contract TransferCanonicalPonsV2Ownership is Script {
    address private constant FACTORY = 0x7DCeEaB0A53684b001A4900768a52eAcDb27294e;
    address private constant LOCKER = 0x1006fA85294A9c38AA4214d52c86CC970Ddc5647;
    address private constant BUYBACK_VAULT = 0xA61f18568d3B817bbb95450D42F7403e871Ce0a1;
    address private constant HOOK = 0xE9Ec0Ffc7d5bEF33f815D7b0cDd15A7c5Dc1e044;

    function run() external {
        require(block.chainid == 4_663, "WRONG_CHAIN");

        address broadcaster = vm.envAddress("DEPLOYER_ADDRESS");
        address newOwner = vm.envAddress("NEW_OWNER");
        require(newOwner != address(0) && newOwner != broadcaster, "INVALID_NEW_OWNER");

        address[4] memory targets = [FACTORY, LOCKER, BUYBACK_VAULT, HOOK];
        for (uint256 i; i < targets.length; ++i) {
            IOwnable2StepTarget target = IOwnable2StepTarget(targets[i]);
            require(targets[i].code.length != 0, "TARGET_HAS_NO_CODE");
            require(target.owner() == broadcaster, "UNEXPECTED_CURRENT_OWNER");
            require(target.pendingOwner() == address(0), "PENDING_OWNER_ALREADY_SET");
        }

        vm.startBroadcast();
        for (uint256 i; i < targets.length; ++i) {
            IOwnable2StepTarget(targets[i]).transferOwnership(newOwner);
        }
        vm.stopBroadcast();

        for (uint256 i; i < targets.length; ++i) {
            IOwnable2StepTarget target = IOwnable2StepTarget(targets[i]);
            require(target.owner() == broadcaster, "OWNER_CHANGED_BEFORE_ACCEPTANCE");
            require(target.pendingOwner() == newOwner, "PENDING_OWNER_MISMATCH");
        }

        console2.log("Current owner", broadcaster);
        console2.log("Pending owner", newOwner);
        console2.log("PonsV2LaunchFactory", FACTORY);
        console2.log("PonsV2LaunchLocker", LOCKER);
        console2.log("PonsV2BuybackVault", BUYBACK_VAULT);
        console2.log("PonsV2MemeHook", HOOK);
    }
}
