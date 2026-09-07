// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPonsV2FeeEscrow} from "../src/v2/interfaces/ILaunchpadV2.sol";
import {IPonsV2CreatorControls, PonsV2TwoWayFeeSplitter} from "../src/v2/utilities/PonsV2TwoWayFeeSplitter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPonsV2CreatorControls} from "./mocks/MockPonsV2CreatorControls.sol";
import {MockPonsV2FeeEscrow} from "./mocks/MockPonsV2FeeEscrow.sol";

interface Vm {
    function deal(address account, uint256 newBalance) external;
    function prank(address sender) external;
    function expectRevert(bytes4 revertData) external;
    function expectRevert(bytes calldata revertData) external;
}

contract RejectNative {
    receive() external payable {
        revert("native rejected");
    }
}

contract ReentrantNativeRecipient {
    PonsV2TwoWayFeeSplitter public splitter;
    bool public attempted;
    bool public reentrySucceeded;

    function setSplitter(PonsV2TwoWayFeeSplitter splitter_) external {
        require(address(splitter) == address(0), "splitter already set");
        splitter = splitter_;
    }

    receive() external payable {
        if (!attempted) {
            attempted = true;
            (reentrySucceeded,) =
                address(splitter).call(abi.encodeCall(PonsV2TwoWayFeeSplitter.releaseNative, (address(this))));
        }
    }
}

contract PonsV2TwoWayFeeSplitterTest {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address payable private constant RECIPIENT_ONE = payable(address(0xA11CE));
    address payable private constant RECIPIENT_TWO = payable(address(0xB0B));
    address private constant CONTROLLER = address(0xC011EC70);
    address private constant LAUNCH_TOKEN = address(0x70CE0);

    MockPonsV2FeeEscrow private escrow;
    MockPonsV2CreatorControls private controls;
    MockERC20 private token;
    PonsV2TwoWayFeeSplitter private splitter;

    receive() external payable {}

    function setUp() public {
        VM.deal(address(this), 100 ether);
        escrow = new MockPonsV2FeeEscrow();
        controls = new MockPonsV2CreatorControls();
        token = new MockERC20();
        splitter = _deploy(RECIPIENT_ONE, RECIPIENT_TWO, 16, 4, address(controls), CONTROLLER);
    }

    function testConstructorStoresImmutableTerms() public view {
        _assertEq(address(splitter.feeEscrow()), address(escrow));
        _assertEq(address(splitter.creatorControls()), address(controls));
        _assertEq(splitter.controller(), CONTROLLER);
        _assertEq(splitter.recipientOne(), RECIPIENT_ONE);
        _assertEq(splitter.recipientTwo(), RECIPIENT_TWO);
        _assertEq(splitter.SHARE_UNITS(), 20);
        _assertEq(splitter.PERCENT_PER_SHARE_UNIT(), 5);
        _assertEq(splitter.recipientOneShareUnits(), 16);
        _assertEq(splitter.recipientTwoShareUnits(), 4);
    }

    function testClaimsAndSplitsNativeFees() public {
        escrow.credit{value: 1 ether}(address(splitter));

        (uint256 claimed, uint256 allocated) = splitter.claimNativeFromPons();

        _assertEq(claimed, 1 ether);
        _assertEq(allocated, 1 ether);
        _assertEq(splitter.pendingNative(RECIPIENT_ONE), 0.8 ether);
        _assertEq(splitter.pendingNative(RECIPIENT_TWO), 0.2 ether);
        _assertEq(escrow.balanceOf(address(splitter)), 0);

        uint256 oneBefore = RECIPIENT_ONE.balance;
        uint256 twoBefore = RECIPIENT_TWO.balance;
        splitter.releaseNative(RECIPIENT_ONE);
        splitter.releaseNative(RECIPIENT_TWO);

        _assertEq(RECIPIENT_ONE.balance - oneBefore, 0.8 ether);
        _assertEq(RECIPIENT_TWO.balance - twoBefore, 0.2 ether);
        _assertEq(address(splitter).balance, 0);
    }

    function testClaimsAndSplitsERC20Fees() public {
        token.mint(address(this), 1_000 ether);
        token.approve(address(escrow), 1_000 ether);
        escrow.creditToken(address(splitter), token, 1_000 ether);

        (uint256 claimed, uint256 allocated) = splitter.claimTokenFromPons(token);

        _assertEq(claimed, 1_000 ether);
        _assertEq(allocated, 1_000 ether);
        _assertEq(splitter.pendingToken(address(token), RECIPIENT_ONE), 800 ether);
        _assertEq(splitter.pendingToken(address(token), RECIPIENT_TWO), 200 ether);

        splitter.releaseToken(token, RECIPIENT_ONE);
        splitter.releaseToken(token, RECIPIENT_TWO);

        _assertEq(token.balanceOf(RECIPIENT_ONE), 800 ether);
        _assertEq(token.balanceOf(RECIPIENT_TWO), 200 ether);
        _assertEq(token.balanceOf(address(splitter)), 0);
    }

    function testRemainderCarryMakesTinyAllocationsMatchOneBatch() public {
        PonsV2TwoWayFeeSplitter batched = _deploy(RECIPIENT_ONE, RECIPIENT_TWO, 16, 4, address(0), address(0));
        PonsV2TwoWayFeeSplitter oneBatch = _deploy(RECIPIENT_ONE, RECIPIENT_TWO, 16, 4, address(0), address(0));

        for (uint256 i; i < 5; ++i) {
            (bool tinySent,) = address(batched).call{value: 1}("");
            require(tinySent, "native funding failed");
            batched.allocateNative();

            token.mint(address(batched), 1);
            batched.allocateToken(token);
        }

        (bool batchSent,) = address(oneBatch).call{value: 5}("");
        require(batchSent, "native funding failed");
        oneBatch.allocateNative();
        token.mint(address(oneBatch), 5);
        oneBatch.allocateToken(token);

        _assertEq(batched.pendingNative(RECIPIENT_ONE), oneBatch.pendingNative(RECIPIENT_ONE));
        _assertEq(batched.pendingNative(RECIPIENT_TWO), oneBatch.pendingNative(RECIPIENT_TWO));
        _assertEq(
            batched.pendingToken(address(token), RECIPIENT_ONE), oneBatch.pendingToken(address(token), RECIPIENT_ONE)
        );
        _assertEq(
            batched.pendingToken(address(token), RECIPIENT_TWO), oneBatch.pendingToken(address(token), RECIPIENT_TWO)
        );
        _assertEq(batched.pendingNative(RECIPIENT_ONE), 4);
        _assertEq(batched.pendingNative(RECIPIENT_TWO), 1);
        _assertEq(batched.nativeRecipientOneRemainder(), 0);
        _assertEq(batched.tokenRecipientOneRemainder(address(token)), 0);
    }

    function testDirectTransfersAreAllocatedWithoutPonsClaim() public {
        (bool sent,) = address(splitter).call{value: 5}("");
        require(sent, "native funding failed");
        token.mint(address(splitter), 5);

        _assertEq(splitter.allocateNative(), 5);
        _assertEq(splitter.allocateToken(token), 5);
        _assertEq(splitter.pendingNative(RECIPIENT_ONE), 4);
        _assertEq(splitter.pendingNative(RECIPIENT_TWO), 1);
        _assertEq(splitter.pendingToken(address(token), RECIPIENT_ONE), 4);
        _assertEq(splitter.pendingToken(address(token), RECIPIENT_TWO), 1);
    }

    function testFuzzAllocationConservesNativeAndToken(uint96 rawAmount, uint16 rawFirstShareUnits) public {
        uint256 amount = uint256(rawAmount) + 1;
        uint8 firstShareUnits = uint8((uint256(rawFirstShareUnits) % 19) + 1);
        uint8 secondShareUnits = 20 - firstShareUnits;
        PonsV2TwoWayFeeSplitter fuzzed =
            _deploy(RECIPIENT_ONE, RECIPIENT_TWO, firstShareUnits, secondShareUnits, address(0), address(0));

        VM.deal(address(this), amount);
        (bool sent,) = address(fuzzed).call{value: amount}("");
        require(sent, "native funding failed");
        token.mint(address(fuzzed), amount);

        _assertEq(fuzzed.allocateNative(), amount);
        _assertEq(fuzzed.allocateToken(token), amount);

        uint256 expectedFirst = (amount * firstShareUnits) / 20;
        uint256 expectedSecond = amount - expectedFirst;
        _assertEq(fuzzed.pendingNative(RECIPIENT_ONE), expectedFirst);
        _assertEq(fuzzed.pendingNative(RECIPIENT_TWO), expectedSecond);
        _assertEq(fuzzed.pendingToken(address(token), RECIPIENT_ONE), expectedFirst);
        _assertEq(fuzzed.pendingToken(address(token), RECIPIENT_TWO), expectedSecond);
        _assertEq(expectedFirst + expectedSecond, amount);
    }

    function testFuzzAllocationIsIndependentOfBatching(
        uint64 rawFirstAmount,
        uint64 rawSecondAmount,
        uint8 rawFirstShareUnits
    ) public {
        uint256 firstAmount = uint256(rawFirstAmount) + 1;
        uint256 secondAmount = uint256(rawSecondAmount) + 1;
        uint256 totalAmount = firstAmount + secondAmount;
        uint8 firstShareUnits = uint8((uint256(rawFirstShareUnits) % 19) + 1);
        uint8 secondShareUnits = 20 - firstShareUnits;
        PonsV2TwoWayFeeSplitter batched =
            _deploy(RECIPIENT_ONE, RECIPIENT_TWO, firstShareUnits, secondShareUnits, address(0), address(0));
        PonsV2TwoWayFeeSplitter oneBatch =
            _deploy(RECIPIENT_ONE, RECIPIENT_TWO, firstShareUnits, secondShareUnits, address(0), address(0));

        VM.deal(address(this), totalAmount * 2);

        _fundAndAllocate(batched, firstAmount);
        _fundAndAllocate(batched, secondAmount);
        _fundAndAllocate(oneBatch, totalAmount);

        _assertEq(batched.pendingNative(RECIPIENT_ONE), oneBatch.pendingNative(RECIPIENT_ONE));
        _assertEq(batched.pendingNative(RECIPIENT_TWO), oneBatch.pendingNative(RECIPIENT_TWO));
        _assertEq(
            batched.pendingToken(address(token), RECIPIENT_ONE), oneBatch.pendingToken(address(token), RECIPIENT_ONE)
        );
        _assertEq(
            batched.pendingToken(address(token), RECIPIENT_TWO), oneBatch.pendingToken(address(token), RECIPIENT_TWO)
        );
        _assertEq(batched.nativeRecipientOneRemainder(), oneBatch.nativeRecipientOneRemainder());
        _assertEq(
            batched.tokenRecipientOneRemainder(address(token)), oneBatch.tokenRecipientOneRemainder(address(token))
        );
    }

    function testNativeReleaseFailureDoesNotBlockOtherRecipient() public {
        RejectNative rejector = new RejectNative();
        PonsV2TwoWayFeeSplitter rejecting =
            _deploy(payable(address(rejector)), RECIPIENT_TWO, 10, 10, address(0), address(0));
        (bool sent,) = address(rejecting).call{value: 10}("");
        require(sent, "native funding failed");
        rejecting.allocateNative();

        VM.expectRevert(
            abi.encodeWithSelector(PonsV2TwoWayFeeSplitter.NativeTransferFailed.selector, address(rejector), 5)
        );
        rejecting.releaseNative(address(rejector));

        _assertEq(rejecting.pendingNative(address(rejector)), 5);
        uint256 secondBefore = RECIPIENT_TWO.balance;
        rejecting.releaseNative(RECIPIENT_TWO);
        _assertEq(RECIPIENT_TWO.balance - secondBefore, 5);
    }

    function testERC20ReleaseFailurePreservesPendingBalance() public {
        token.mint(address(splitter), 10);
        splitter.allocateToken(token);
        token.setFailTransfers(true);

        VM.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        splitter.releaseToken(token, RECIPIENT_ONE);

        _assertEq(splitter.pendingToken(address(token), RECIPIENT_ONE), 8);
        token.setFailTransfers(false);
        splitter.releaseToken(token, RECIPIENT_ONE);
        _assertEq(token.balanceOf(RECIPIENT_ONE), 8);
    }

    function testNativeReleaseCannotBeReentered() public {
        ReentrantNativeRecipient attacker = new ReentrantNativeRecipient();
        PonsV2TwoWayFeeSplitter guarded =
            _deploy(payable(address(attacker)), RECIPIENT_TWO, 10, 10, address(0), address(0));
        attacker.setSplitter(guarded);
        (bool sent,) = address(guarded).call{value: 10}("");
        require(sent, "native funding failed");
        guarded.allocateNative();

        guarded.releaseNative(address(attacker));

        require(attacker.attempted(), "reentry was not attempted");
        require(!attacker.reentrySucceeded(), "reentry unexpectedly succeeded");
        _assertEq(address(attacker).balance, 5);
        _assertEq(guarded.pendingNative(address(attacker)), 0);
        _assertEq(guarded.pendingNative(RECIPIENT_TWO), 5);
    }

    function testControllerCanForwardOnlyPonsCreatorControls() public {
        VM.prank(CONTROLLER);
        splitter.transferCreatorFeeRecipient(LAUNCH_TOKEN, RECIPIENT_TWO);
        _assertEq(controls.lastCaller(), address(splitter));
        _assertEq(controls.lastToken(), LAUNCH_TOKEN);
        _assertEq(controls.lastRecipient(), RECIPIENT_TWO);

        VM.prank(CONTROLLER);
        splitter.setBuybackEnabled(LAUNCH_TOKEN, true);
        _assertEq(controls.lastCaller(), address(splitter));
        _assertEq(controls.lastToken(), LAUNCH_TOKEN);
        require(controls.lastBuybackEnabled(), "buyback flag not forwarded");
    }

    function testNonControllerCannotForwardCreatorControls() public {
        VM.expectRevert(PonsV2TwoWayFeeSplitter.NotController.selector);
        splitter.setBuybackEnabled(LAUNCH_TOKEN, true);
    }

    function testCreatorControlsCanBePermanentlyDisabled() public {
        PonsV2TwoWayFeeSplitter ownerless = _deploy(RECIPIENT_ONE, RECIPIENT_TWO, 10, 10, address(0), address(0));
        VM.expectRevert(PonsV2TwoWayFeeSplitter.NotController.selector);
        ownerless.transferCreatorFeeRecipient(LAUNCH_TOKEN, RECIPIENT_TWO);
    }

    function testRejectsInvalidConstructorTerms() public {
        VM.expectRevert(PonsV2TwoWayFeeSplitter.DuplicateRecipient.selector);
        _deploy(RECIPIENT_ONE, RECIPIENT_ONE, 10, 10, address(0), address(0));

        VM.expectRevert(PonsV2TwoWayFeeSplitter.InvalidShareUnits.selector);
        _deploy(RECIPIENT_ONE, RECIPIENT_TWO, 0, 20, address(0), address(0));

        VM.expectRevert(PonsV2TwoWayFeeSplitter.InvalidShareUnits.selector);
        _deploy(RECIPIENT_ONE, RECIPIENT_TWO, 20, 0, address(0), address(0));

        VM.expectRevert(PonsV2TwoWayFeeSplitter.InvalidShareUnits.selector);
        _deploy(RECIPIENT_ONE, RECIPIENT_TWO, 10, 9, address(0), address(0));

        VM.expectRevert(PonsV2TwoWayFeeSplitter.InvalidShareUnits.selector);
        _deploy(RECIPIENT_ONE, RECIPIENT_TWO, 10, 11, address(0), address(0));

        VM.expectRevert(PonsV2TwoWayFeeSplitter.InvalidControllerConfiguration.selector);
        _deploy(RECIPIENT_ONE, RECIPIENT_TWO, 10, 10, address(controls), address(0));
    }

    function testUnknownRecipientCannotBeReleased() public {
        VM.expectRevert(PonsV2TwoWayFeeSplitter.UnknownRecipient.selector);
        splitter.releaseNative(address(0xBAD));
    }

    function _deploy(
        address payable first,
        address payable second,
        uint8 firstShareUnits,
        uint8 secondShareUnits,
        address creatorControls,
        address controller
    ) private returns (PonsV2TwoWayFeeSplitter deployed) {
        deployed = new PonsV2TwoWayFeeSplitter(
            IPonsV2FeeEscrow(address(escrow)),
            first,
            second,
            firstShareUnits,
            secondShareUnits,
            IPonsV2CreatorControls(creatorControls),
            controller
        );
    }

    function _fundAndAllocate(PonsV2TwoWayFeeSplitter target, uint256 amount) private {
        (bool sent,) = address(target).call{value: amount}("");
        require(sent, "native funding failed");
        target.allocateNative();

        token.mint(address(target), amount);
        target.allocateToken(token);
    }

    function _assertEq(uint256 actual, uint256 expected) private pure {
        require(actual == expected, "uint mismatch");
    }

    function _assertEq(address actual, address expected) private pure {
        require(actual == expected, "address mismatch");
    }
}
