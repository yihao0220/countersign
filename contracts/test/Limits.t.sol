// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;
import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {CountersignDemo as Vault} from "../src/CountersignDemo.sol";

contract LimitsTest is Test {
    Vault v;
    address agent = address(0xA);
    address payable vendor = payable(address(0xB));
    uint64 expiry;
    uint256 nonce;

    function setUp() public {
        vm.warp(10 days + 1 hours);
        vm.deal(address(this), 1000 ether);
        expiry = uint64(block.timestamp + 30 days);
        v = new Vault{value: 1000 ether}(agent, vendor, 500 ether, expiry, 200 ether);
    }

    function pay(uint256 amount) internal returns (bool) {
        vm.prank(agent);
        return v.pay(7, vendor, 101, amount, bytes32(++nonce));
    }

    function kind(bool daily) internal pure returns (Vault.LimitKind) {
        return daily ? Vault.LimitKind.DailyLimit : Vault.LimitKind.TotalBudget;
    }

    function test_Demo_DailyLimitAndOwnerChanges() public {
        assertTrue(pay(150 ether));
        assertTrue(pay(50 ether));
        assertFalse(pay(1 ether));
        assertEq(v.remainingBudget(), 300 ether);
        console2.log("Today paid 200; another 1 BLOCKED; remaining total = 300");
        vm.warp(11 days);
        assertEq(v.spentToday(), 0);
        assertTrue(pay(100 ether));
        console2.log("Next UTC day: paid 100; remaining total = 200");
        bytes32 id = v.queueLimitIncrease(Vault.LimitKind.TotalBudget, 800 ether);
        vm.expectRevert(Vault.TimelockNotReady.selector);
        v.execute(id);
        vm.warp(block.timestamp + 120);
        vm.prank(address(0xC));
        v.execute(id);
        assertEq(v.remainingBudget(), 500 ether);
        console2.log("After delay: total raised to 800; already paid 300; remaining = 500");
        v.decreaseLimit(Vault.LimitKind.DailyLimit, 50 ether);
        assertFalse(pay(1 ether));
        assertEq(v.spentToday(), 100 ether);
        console2.log("Owner lowered daily limit to 50; today's paid 100 retained; payment BLOCKED");
    }

    function test_DailyBlockEventAndUnchangedAccounts() public {
        assertTrue(pay(200 ether));
        vm.expectEmit(false, false, false, true, address(v));
        emit Vault.Blocked(
            uint8(Vault.BlockReason.DailyLimitExceeded), 7, vendor, 101, 1 ether, bytes32(uint256(2)), agent
        );
        assertFalse(pay(1 ether));
        assertEq(v.spentToday(), 200 ether);
        assertEq(v.totalSpent(), 200 ether);
        assertEq(v.remainingBudget(), 300 ether);
        assertEq(vendor.balance, 200 ether);
        assertFalse(v.paidInvoices(bytes32(uint256(2))));
    }

    function test_ExactUTCResetAndNoBudgetRefill() public {
        vm.warp(11 days - 1);
        assertTrue(pay(200 ether));
        assertFalse(pay(1));
        vm.warp(11 days);
        assertTrue(pay(200 ether));
        vm.warp(12 days);
        assertTrue(pay(100 ether));
        assertFalse(pay(1));
        assertEq(v.totalSpent(), 500 ether);
        assertEq(v.spentByDay(10), 200 ether);
        assertEq(v.remainingBudget(), 0);
    }

    function test_LoweringTotalPreservesSpent() public {
        assertTrue(pay(100 ether));
        vm.expectRevert(Vault.InvalidLimitChange.selector);
        v.decreaseLimit(Vault.LimitKind.TotalBudget, 99 ether);
        v.decreaseLimit(Vault.LimitKind.TotalBudget, 100 ether);
        assertEq(v.remainingBudget(), 0);
        assertFalse(pay(1));
    }

    function test_DailyIncreaseRetainsTodayAndDoesNotFundVault() public {
        assertTrue(pay(150 ether));
        bytes32 id = v.queueLimitIncrease(Vault.LimitKind.DailyLimit, 300 ether);
        assertEq(v.dailyLimit(), 200 ether);
        vm.warp(block.timestamp + 120);
        v.execute(id);
        assertEq(v.spentToday(), 150 ether);
        assertEq(address(v).balance, 850 ether);
        assertTrue(pay(150 ether));
        assertFalse(pay(1));
    }

    function test_PaymentWhileTotalIncreasePending() public {
        bytes32 id = v.queueLimitIncrease(Vault.LimitKind.TotalBudget, 800 ether);
        assertTrue(pay(100 ether));
        vm.warp(block.timestamp + 120);
        v.execute(id);
        assertEq(v.remainingBudget(), 700 ether);
    }

    function test_ExpiryStillBlocksAfterLimitIncrease() public {
        bytes32 id = v.queueLimitIncrease(Vault.LimitKind.TotalBudget, 800 ether);
        vm.warp(expiry);
        v.execute(id);
        assertFalse(pay(100 ether));
        assertEq(v.poExpiry(), expiry);
        assertEq(v.totalSpent(), 0);
    }

    function test_IndependentPendingOperationsWhilePaused() public {
        v.pause();
        bytes32 a = v.queueLimitIncrease(Vault.LimitKind.TotalBudget, 800 ether);
        bytes32 b = v.queueLimitIncrease(Vault.LimitKind.DailyLimit, 300 ether);
        bytes32 c = v.queueResume();
        bytes32 d = v.queuePayoutChange(7, address(0xD));
        vm.warp(block.timestamp + 120);
        v.execute(a);
        v.execute(b);
        v.execute(d);
        assertTrue(v.paused());
        v.execute(c);
        assertFalse(v.paused());
        assertEq(v.totalBudget(), 800 ether);
        assertEq(v.dailyLimit(), 300 ether);
    }

    function testFuzz_OnlyOwnerCanManageLimits(bool daily, address caller) public {
        vm.assume(caller != address(this));
        vm.startPrank(caller);
        vm.expectRevert(Vault.UnauthorizedOwner.selector);
        v.decreaseLimit(kind(daily), 0);
        vm.expectRevert(Vault.UnauthorizedOwner.selector);
        v.queueLimitIncrease(kind(daily), 800 ether);
        vm.stopPrank();
    }

    function testFuzz_TimelockCancelReplayAndRequeue(bool daily) public {
        Vault.LimitKind k = kind(daily);
        bytes32 id = v.queueLimitIncrease(k, 800 ether);
        vm.expectRevert(Vault.ChangeAlreadyPending.selector);
        v.queueLimitIncrease(k, 900 ether);
        vm.prank(agent);
        vm.expectRevert(Vault.UnauthorizedOwner.selector);
        v.cancel(id);
        v.cancel(id);
        vm.expectRevert(Vault.ChangeNotPending.selector);
        v.execute(id);
        vm.warp(block.timestamp + 119);
        bytes32 fresh = v.queueLimitIncrease(k, 800 ether);
        assertTrue(fresh != id);
        vm.warp(block.timestamp + 119);
        vm.expectRevert(Vault.TimelockNotReady.selector);
        v.execute(fresh);
        vm.warp(block.timestamp + 1);
        vm.prank(agent);
        v.execute(fresh);
        vm.expectRevert(Vault.ChangeNotPending.selector);
        v.execute(fresh);
        vm.expectRevert(Vault.ChangeNotPending.selector);
        v.cancel(fresh);
    }

    function testFuzz_DecreaseCancelsOldIncrease(bool daily) public {
        Vault.LimitKind k = kind(daily);
        bytes32 id = v.queueLimitIncrease(k, 800 ether);
        v.decreaseLimit(k, 0);
        assertEq(v.pendingLimitChange(k), bytes32(0));
        (,,, Vault.ChangeStatus status) = v.limitChanges(id);
        assertEq(uint256(status), uint256(Vault.ChangeStatus.Cancelled));
        vm.warp(block.timestamp + 120);
        vm.expectRevert(Vault.ChangeNotPending.selector);
        v.execute(id);
        assertFalse(pay(1));
    }

    function testFuzz_InvalidDirections(bool daily) public {
        Vault.LimitKind k = kind(daily);
        uint256 current = daily ? 200 ether : 500 ether;
        vm.expectRevert(Vault.InvalidLimitChange.selector);
        v.decreaseLimit(k, current);
        vm.expectRevert(Vault.InvalidLimitChange.selector);
        v.decreaseLimit(k, current + 1);
        vm.expectRevert(Vault.InvalidLimitChange.selector);
        v.queueLimitIncrease(k, current);
        vm.expectRevert(Vault.InvalidLimitChange.selector);
        v.queueLimitIncrease(k, current - 1);
    }

    function testFuzz_AccountingAfterTotalChange(uint96 paid, uint96 added) public {
        uint256 amount = bound(paid, 1, 200 ether);
        uint256 target = 500 ether + bound(added, 1, 1000 ether);
        assertTrue(pay(amount));
        bytes32 id = v.queueLimitIncrease(Vault.LimitKind.TotalBudget, target);
        vm.warp(block.timestamp + 120);
        v.execute(id);
        assertEq(v.remainingBudget() + v.totalSpent(), target);
        assertEq(v.spentToday(), amount);
        assertEq(vendor.balance, amount);
    }

    function test_TransferFailureRollsBackDailyAndTotal() public {
        vm.etch(vendor, hex"60006000fd");
        vm.expectRevert(Vault.TransferFailed.selector);
        pay(100 ether);
        assertEq(v.spentToday(), 0);
        assertEq(v.totalSpent(), 0);
        assertEq(v.remainingBudget(), 500 ether);
        assertFalse(v.paidInvoices(bytes32(uint256(1))));
    }

    function test_ZeroDailyLimitAtCreationBlocksPayment() public {
        v = new Vault(agent, vendor, 500 ether, expiry, 0);
        vm.deal(address(v), 500 ether);
        assertFalse(pay(1));
        assertEq(v.totalSpent(), 0);
    }

    function testFuzz_LimitEventsAndStoredParameters(bool daily) public {
        Vault.LimitKind k = kind(daily);
        bytes32 id = keccak256(abi.encode(address(v), block.chainid, uint256(1), "limit", k, uint256(800 ether)));
        vm.expectEmit(true, true, false, true, address(v));
        emit Vault.LimitChangeQueued(id, k, 800 ether, block.timestamp + 120);
        assertEq(v.queueLimitIncrease(k, 800 ether), id);
        (Vault.LimitKind storedKind, uint256 target, uint256 due, Vault.ChangeStatus status) = v.limitChanges(id);
        assertEq(uint256(storedKind), uint256(k));
        assertEq(target, 800 ether);
        assertEq(due, block.timestamp + 120);
        assertEq(uint256(status), uint256(Vault.ChangeStatus.Pending));
        vm.warp(due);
        vm.expectEmit(true, false, false, true, address(v));
        emit Vault.LimitChanged(k, daily ? 200 ether : 500 ether, 800 ether);
        vm.expectEmit(true, false, false, true, address(v));
        emit Vault.LimitChangeExecuted(id);
        v.execute(id);
        assertEq(v.pendingLimitChange(k), bytes32(0));
        id = v.queueLimitIncrease(k, 900 ether);
        vm.expectEmit(true, false, false, true, address(v));
        emit Vault.LimitChangeCancelled(id);
        vm.expectEmit(true, false, false, true, address(v));
        emit Vault.LimitChanged(k, 800 ether, 100 ether);
        v.decreaseLimit(k, 100 ether);
    }
}
