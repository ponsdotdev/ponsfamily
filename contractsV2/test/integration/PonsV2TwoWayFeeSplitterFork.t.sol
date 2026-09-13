// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPonsV2FeeEscrow} from "../../src/v2/interfaces/ILaunchpadV2.sol";
import {IPonsV2CreatorControls, PonsV2TwoWayFeeSplitter} from "../../src/v2/utilities/PonsV2TwoWayFeeSplitter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

interface VmFork {
    function createSelectFork(string calldata urlOrAlias) external returns (uint256 forkId);
    function deal(address account, uint256 newBalance) external;
    function envOr(string calldata name, string calldata defaultValue) external returns (string memory value);
    function skip(bool skipTest) external;
}

interface IPonsV2LaunchFactoryFork {
    function feeEscrow() external view returns (IPonsV2FeeEscrow);
}

contract PonsV2TwoWayFeeSplitterForkTest {
    VmFork private constant VM = VmFork(address(uint160(uint256(keccak256("hevm cheat code")))));

    address private constant PONS_V2_FACTORY = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    address private constant PONS_V2_FEE_ESCROW = 0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e;
    address payable private constant RECIPIENT_ONE = payable(address(0xA11CE));
    address payable private constant RECIPIENT_TWO = payable(address(0xB0B));

    function testForkClaimsAndReleasesNativeThroughDeployedEscrow() public {
        IPonsV2FeeEscrow escrow = _selectRobinhoodFork();
        PonsV2TwoWayFeeSplitter splitter = _deploy(escrow);
        VM.deal(address(this), 5);

        escrow.credit{value: 5}(address(splitter));
        (uint256 claimed, uint256 allocated) = splitter.claimNativeFromPons();

        _assertEq(claimed, 5);
        _assertEq(allocated, 5);
        _assertEq(splitter.pendingNative(RECIPIENT_ONE), 4);
        _assertEq(splitter.pendingNative(RECIPIENT_TWO), 1);

        uint256 firstBefore = RECIPIENT_ONE.balance;
        uint256 secondBefore = RECIPIENT_TWO.balance;
        splitter.releaseNative(RECIPIENT_ONE);
        splitter.releaseNative(RECIPIENT_TWO);
        _assertEq(RECIPIENT_ONE.balance - firstBefore, 4);
        _assertEq(RECIPIENT_TWO.balance - secondBefore, 1);
    }

    function testForkClaimsAndReleasesERC20ThroughDeployedEscrow() public {
        IPonsV2FeeEscrow escrow = _selectRobinhoodFork();
        PonsV2TwoWayFeeSplitter splitter = _deploy(escrow);
        MockERC20 token = new MockERC20();
        token.mint(address(this), 5);
        token.approve(address(escrow), 5);

        escrow.creditToken(address(splitter), address(token), 5);
        (uint256 claimed, uint256 allocated) = splitter.claimTokenFromPons(token);

        _assertEq(claimed, 5);
        _assertEq(allocated, 5);
        _assertEq(splitter.pendingToken(address(token), RECIPIENT_ONE), 4);
        _assertEq(splitter.pendingToken(address(token), RECIPIENT_TWO), 1);

        splitter.releaseToken(token, RECIPIENT_ONE);
        splitter.releaseToken(token, RECIPIENT_TWO);
        _assertEq(token.balanceOf(RECIPIENT_ONE), 4);
        _assertEq(token.balanceOf(RECIPIENT_TWO), 1);
    }

    function _selectRobinhoodFork() private returns (IPonsV2FeeEscrow escrow) {
        string memory rpcUrl = VM.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) VM.skip(true);

        VM.createSelectFork(rpcUrl);
        require(block.chainid == 4663, "unexpected chain");
        require(PONS_V2_FACTORY.code.length != 0, "factory not deployed");

        escrow = IPonsV2LaunchFactoryFork(PONS_V2_FACTORY).feeEscrow();
        _assertEq(address(escrow), PONS_V2_FEE_ESCROW);
        require(address(escrow).code.length != 0, "escrow not deployed");
    }

    function _deploy(IPonsV2FeeEscrow escrow) private returns (PonsV2TwoWayFeeSplitter) {
        return new PonsV2TwoWayFeeSplitter(
            escrow, RECIPIENT_ONE, RECIPIENT_TWO, 16, 4, IPonsV2CreatorControls(address(0)), address(0)
        );
    }

    function _assertEq(uint256 actual, uint256 expected) private pure {
        require(actual == expected, "uint mismatch");
    }

    function _assertEq(address actual, address expected) private pure {
        require(actual == expected, "address mismatch");
    }
}
