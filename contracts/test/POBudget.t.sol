// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";
import {CountersignDemo as Vault} from "../src/CountersignDemo.sol";

contract BudgetCallbackOwner {
    Vault public vault;
    bool public decreaseBlocked;
    bool public increaseBlocked;
    bool public closeBlocked;

    function create(address agent) external payable {
        vault = new Vault{value: msg.value}(
            agent, payable(address(this)), 500 ether, uint64(block.timestamp + 30 days), 200 ether
        );
    }

    receive() external payable {
        try vault.decreasePOBudget(101, 100 ether) {}
        catch (bytes memory reason) {
            decreaseBlocked = bytes4(reason) == Vault.ReentrantCall.selector;
        }
        try vault.queuePOBudgetIncrease(101, 800 ether) {}
        catch (bytes memory reason) {
            increaseBlocked = bytes4(reason) == Vault.ReentrantCall.selector;
        }
        try vault.closePO(101) {}
        catch (bytes memory reason) {
            closeBlocked = bytes4(reason) == Vault.ReentrantCall.selector;
        }
    }
}

contract POBudgetTest is Test {
    Vault internal v;
    address internal agent = address(0xA);
    address payable internal vendor = payable(address(0xB));
    address internal stranger = address(0xC);
    bytes32 internal constant INVOICE = keccak256("paid-invoice");
    bytes32 internal constant OTHER = keccak256("other-invoice");

    function setUp() public {
        vm.warp(10 days + 1 hours);
        vm.deal(address(this), 1000 ether);
        v = new Vault{value: 500 ether}(agent, vendor, 500 ether, uint64(block.timestamp + 30 days), 200 ether);
        addPO(102, 0);
    }

    function addPO(uint256 poId, uint32 periodDays) internal {
        bytes32 id = v.queueAddPO(poId, 7, 100 ether, uint64(block.timestamp + 20 days), periodDays);
        execute(id);
    }

    function execute(bytes32 id) internal {
        vm.warp(block.timestamp + 120);
        vm.prank(stranger);
        v.execute(id);
    }

    function po(uint256 poId) internal view returns (Vault.PurchaseOrder memory p) {
        (bool ok, bytes memory data) = address(v).staticcall(abi.encodeWithSignature("purchaseOrders(uint256)", poId));
        require(ok, "PO query failed");
        return abi.decode(data, (Vault.PurchaseOrder));
    }

    // A budget change may change cap, but none of these accounting or identity fields.
    function ledger(uint256 poId) internal view returns (bytes32) {
        Vault.PurchaseOrder memory p = po(poId);
        p.cap = 0;
        return
            keccak256(abi.encode(p, v.totalPaid(), v.spentToday(), address(v).balance, vendor.balance, v.totalSpent()));
    }

    function pay(uint256 poId, uint256 amount, bytes32 invoice) internal returns (bool) {
        vm.prank(agent);
        return v.pay(7, vendor, poId, amount, invoice);
    }

    function blocked(Vault.BlockReason reason, uint256 poId, uint256 amount, bytes32 invoice) internal {
        bytes32 before = ledger(poId);
        uint256 remaining = v.poRemaining(poId);
        bool paid = v.paidInvoices(invoice);
        vm.expectEmit(false, false, false, true, address(v));
        emit Vault.Blocked(uint8(reason), 7, vendor, poId, amount, invoice, agent);
        assertFalse(pay(poId, amount, invoice));
        assertEq(ledger(poId), before);
        assertEq(v.poRemaining(poId), remaining);
        assertEq(v.paidInvoices(invoice), paid);
    }

    function test_Demo_POBudgetChangesThenClose() public {
        assertTrue(pay(102, 30 ether, INVOICE));
        bytes32 before = ledger(102);
        console2.log("PO-102 budget = 100; PAID 30; remaining = 70; vault = 470");
        v.decreasePOBudget(102, 60 ether);
        assertEq(v.poRemaining(102), 30 ether);
        assertEq(ledger(102), before);
        vm.expectRevert(Vault.InvalidLimitChange.selector);
        v.decreasePOBudget(102, 29 ether);
        console2.log("Lower to 60: remaining = 30; lowering below PAID 30 rejected");

        uint256 start = block.timestamp;
        bytes32 id = v.queuePOBudgetIncrease(102, 120 ether);
        assertEq(v.poRemaining(102), 30 ether);
        vm.warp(start + 119);
        vm.expectRevert(Vault.TimelockNotReady.selector);
        v.execute(id);
        assertEq(v.poRemaining(102), 30 ether);
        console2.log("Raise to 120 queued: at 119s old budget remains");
        vm.warp(start + 120);
        vm.prank(stranger);
        v.execute(id);
        assertEq(v.poRemaining(102), 90 ether);
        assertEq(ledger(102), before);
        assertTrue(v.paidInvoices(INVOICE));
        blocked(Vault.BlockReason.DuplicateInvoice, 102, 30 ether, INVOICE);
        console2.log("At 120s: raised to 120; remaining = 90; PAID history still = 30");
        console2.log("Duplicate invoice still BLOCKED; vault = 470; daily spending = 30");

        bytes32 cancelled = v.queuePOBudgetIncrease(102, 150 ether);
        v.closePO(102);
        assertEq(v.pendingPOBudgetChange(102), bytes32(0));
        vm.warp(block.timestamp + 120);
        vm.expectRevert(Vault.ChangeNotPending.selector);
        v.execute(cancelled);
        blocked(Vault.BlockReason.POClosed, 102, 1 ether, OTHER);
        assertEq(po(102).totalPaid, 30 ether);
        assertEq(address(v).balance, 470 ether);
        console2.log("Closed: pending raise cancelled; payment BLOCKED; vault still = 470");
        assertTrue(pay(101, 1 ether, OTHER));
        console2.log("PO-101 remains usable; closed PO cannot be reopened or reused");
        vm.expectRevert(Vault.POAlreadyExists.selector);
        v.queueAddPO(102, 7, 100 ether, uint64(block.timestamp + 20 days), 0);
    }

    function test_DecreaseFloorExactSpentAndZero() public {
        v.decreasePOBudget(102, 0);
        blocked(Vault.BlockReason.OverBudget, 102, 1 ether, INVOICE);
        execute(v.queuePOBudgetIncrease(102, 100 ether));
        assertTrue(pay(102, 30 ether, INVOICE));
        bytes32 before = ledger(102);
        vm.expectRevert(Vault.InvalidLimitChange.selector);
        v.decreasePOBudget(102, 29 ether);
        v.decreasePOBudget(102, 30 ether);
        assertEq(v.poRemaining(102), 0);
        assertEq(ledger(102), before);
    }

    function test_DirectionsMissingAndClosedPOs() public {
        vm.expectRevert(Vault.InvalidLimitChange.selector);
        v.decreasePOBudget(102, 100 ether);
        vm.expectRevert(Vault.InvalidLimitChange.selector);
        v.decreasePOBudget(102, 101 ether);
        vm.expectRevert(Vault.InvalidLimitChange.selector);
        v.queuePOBudgetIncrease(102, 100 ether);
        vm.expectRevert(Vault.InvalidLimitChange.selector);
        v.queuePOBudgetIncrease(102, 99 ether);
        vm.expectRevert(Vault.InvalidPO.selector);
        v.decreasePOBudget(999, 0);
        vm.expectRevert(Vault.InvalidPO.selector);
        v.queuePOBudgetIncrease(999, 200 ether);
        v.closePO(102);
        vm.expectRevert(Vault.InvalidPO.selector);
        v.decreasePOBudget(102, 0);
        vm.expectRevert(Vault.InvalidPO.selector);
        v.queuePOBudgetIncrease(102, 200 ether);
    }

    function test_QueueFieldsEventsBoundaryAndReplay() public {
        uint256 start = block.timestamp;
        vm.recordLogs();
        bytes32 id = v.queuePOBudgetIncrease(102, 120 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], keccak256("POBudgetChangeQueued(bytes32,uint256,uint256,uint256)"));
        assertEq(logs[0].topics[1], id);
        assertEq(logs[0].topics[2], bytes32(uint256(102)));
        assertEq(logs[0].data, abi.encode(120 ether, start + 120));
        (uint256 poId, uint256 cap, uint256 eta, Vault.ChangeStatus status) = v.poBudgetChanges(id);
        assertEq(poId, 102);
        assertEq(cap, 120 ether);
        assertEq(eta, start + 120);
        assertEq(uint8(status), uint8(Vault.ChangeStatus.Pending));
        vm.expectRevert(Vault.ChangeAlreadyPending.selector);
        v.queuePOBudgetIncrease(102, 150 ether);
        vm.warp(start + 119);
        vm.expectRevert(Vault.TimelockNotReady.selector);
        v.execute(id);
        vm.warp(start + 120);
        assertEq(po(102).cap, 100 ether); // Time alone does not execute.
        vm.expectEmit(true, false, false, true, address(v));
        emit Vault.POBudgetChanged(102, 100 ether, 120 ether);
        vm.expectEmit(true, true, false, true, address(v));
        emit Vault.POBudgetChangeExecuted(id, 102);
        vm.prank(stranger);
        v.execute(id);
        assertEq(v.pendingPOBudgetChange(102), bytes32(0));
        (,,, status) = v.poBudgetChanges(id);
        assertEq(uint8(status), uint8(Vault.ChangeStatus.Executed));
        vm.expectRevert(Vault.ChangeNotPending.selector);
        v.execute(id);
        vm.expectRevert(Vault.ChangeNotPending.selector);
        v.cancel(id);
    }

    function test_CancelAndRetryNeedsFullDelay() public {
        bytes32 id = v.queuePOBudgetIncrease(102, 120 ether);
        vm.expectEmit(true, true, false, true, address(v));
        emit Vault.POBudgetChangeCancelled(id, 102);
        v.cancel(id);
        (,,, Vault.ChangeStatus status) = v.poBudgetChanges(id);
        assertEq(uint8(status), uint8(Vault.ChangeStatus.Cancelled));
        vm.warp(block.timestamp + 119);
        bytes32 fresh = v.queuePOBudgetIncrease(102, 150 ether);
        assertTrue(fresh != id);
        vm.warp(block.timestamp + 1);
        vm.expectRevert(Vault.ChangeNotPending.selector);
        v.execute(id);
        vm.expectRevert(Vault.TimelockNotReady.selector);
        v.execute(fresh);
        execute(fresh);
        assertEq(po(102).cap, 150 ether);
    }

    function test_LoweringAndClosingCancelOnlyTargetPO() public {
        addPO(103, 0);
        bytes32 id = v.queuePOBudgetIncrease(102, 120 ether);
        bytes32 other = v.queuePOBudgetIncrease(103, 130 ether);
        bytes32 legacy = v.queueLimitIncrease(Vault.LimitKind.TotalBudget, 600 ether);
        bytes32 daily = v.queueLimitIncrease(Vault.LimitKind.DailyLimit, 250 ether);
        v.decreasePOBudget(102, 50 ether);
        assertEq(v.pendingPOBudgetChange(102), bytes32(0));
        assertEq(v.pendingPOBudgetChange(103), other);
        assertEq(v.pendingPOBudgetChange(101), legacy);
        assertEq(v.pendingLimitChange(Vault.LimitKind.DailyLimit), daily);
        vm.warp(block.timestamp + 120);
        vm.expectRevert(Vault.ChangeNotPending.selector);
        v.execute(id);
        v.closePO(103);
        vm.expectRevert(Vault.ChangeNotPending.selector);
        v.execute(other);
        v.execute(legacy);
        v.execute(daily);
        assertEq(v.totalBudget(), 600 ether);
        assertEq(v.dailyLimit(), 250 ether);
    }

    function test_PaymentDuringWaitStillUsesOldCapAndIsRetained() public {
        bytes32 id = v.queuePOBudgetIncrease(102, 150 ether);
        assertTrue(pay(102, 100 ether, INVOICE));
        blocked(Vault.BlockReason.OverBudget, 102, 1 ether, OTHER);
        execute(id);
        assertEq(v.poRemaining(102), 50 ether);
        assertEq(po(102).totalPaid, 100 ether);
        assertTrue(v.paidInvoices(INVOICE));
    }

    function test_LegacyAndNewEntrypointsSharePendingAndQueries() public {
        assertTrue(pay(101, 30 ether, INVOICE));
        bytes32 id = v.queuePOBudgetIncrease(101, 600 ether);
        assertEq(v.pendingPOBudgetChange(101), id);
        assertEq(v.pendingLimitChange(Vault.LimitKind.TotalBudget), id);
        (Vault.LimitKind kind, uint256 cap,, Vault.ChangeStatus status) = v.limitChanges(id);
        assertEq(uint8(kind), uint8(Vault.LimitKind.TotalBudget));
        assertEq(cap, 600 ether);
        assertEq(uint8(status), uint8(Vault.ChangeStatus.Pending));
        vm.expectRevert(Vault.ChangeAlreadyPending.selector);
        v.queueLimitIncrease(Vault.LimitKind.TotalBudget, 700 ether);
        v.decreaseLimit(Vault.LimitKind.TotalBudget, 400 ether);
        assertEq(v.pendingPOBudgetChange(101), bytes32(0));
        vm.warp(block.timestamp + 120);
        vm.expectRevert(Vault.ChangeNotPending.selector);
        v.execute(id);
        bytes32 second = v.queueLimitIncrease(Vault.LimitKind.TotalBudget, 800 ether);
        vm.expectRevert(Vault.ChangeAlreadyPending.selector);
        v.queuePOBudgetIncrease(101, 900 ether);
        v.decreasePOBudget(101, 300 ether);
        assertEq(v.pendingLimitChange(Vault.LimitKind.TotalBudget), bytes32(0));
        assertEq(v.totalBudget(), 300 ether);
        assertEq(v.remainingBudget(), 270 ether);
        assertEq(v.totalSpent(), 30 ether);
        assertEq(po(101).cap, 300 ether);
        vm.warp(block.timestamp + 120);
        vm.expectRevert(Vault.ChangeNotPending.selector);
        v.execute(second);
        execute(v.queuePOBudgetIncrease(101, 500 ether));
        assertEq(v.remainingBudget(), 470 ether);
        assertEq(po(101).totalPaid, 30 ether);
        assertEq(v.spentToday(), 30 ether);
        assertEq(address(v).balance, 470 ether);
    }

    function test_ClosingInitialPOCancelsLegacyRaiseAndBlocksBothEntrypoints() public {
        bytes32 id = v.queueLimitIncrease(Vault.LimitKind.TotalBudget, 600 ether);
        bytes32 other = v.queuePOBudgetIncrease(102, 120 ether);
        v.closePO(101);
        assertEq(v.pendingPOBudgetChange(101), bytes32(0));
        execute(other);
        vm.expectRevert(Vault.ChangeNotPending.selector);
        v.execute(id);
        vm.expectRevert(Vault.InvalidPO.selector);
        v.queueLimitIncrease(Vault.LimitKind.TotalBudget, 800 ether);
        vm.expectRevert(Vault.InvalidPO.selector);
        v.decreaseLimit(Vault.LimitKind.TotalBudget, 0);
        vm.expectRevert(Vault.InvalidPO.selector);
        v.queuePOBudgetIncrease(101, 800 ether);
        vm.expectRevert(Vault.InvalidPO.selector);
        v.decreasePOBudget(101, 0);
        assertTrue(pay(102, 10 ether, INVOICE));
    }

    function test_PeriodLoweringUsesCurrentSpentNotLifetimePaid() public {
        addPO(103, 1);
        uint256 start = po(103).startedAt;
        assertTrue(pay(103, 80 ether, INVOICE));
        vm.warp(start + 1 days - 1);
        vm.expectRevert(Vault.InvalidLimitChange.selector);
        v.decreasePOBudget(103, 50 ether);
        vm.warp(start + 1 days);
        bytes32 before = ledger(103);
        v.decreasePOBudget(103, 50 ether);
        assertEq(ledger(103), before);
        assertEq(v.poRemaining(103), 50 ether);
        assertEq(po(103).spent, 80 ether); // Stored old-period spending is not erased by lowering.
        assertTrue(pay(103, 20 ether, OTHER));
        before = ledger(103);
        vm.expectRevert(Vault.InvalidLimitChange.selector);
        v.decreasePOBudget(103, 19 ether);
        v.decreasePOBudget(103, 20 ether);
        assertEq(ledger(103), before);
        assertEq(po(103).totalPaid, 100 ether);
        assertEq(v.poRemaining(103), 0);
        vm.warp(start + 2 days);
        assertEq(v.poRemaining(103), 20 ether);
        blocked(Vault.BlockReason.DuplicateInvoice, 103, 1 ether, INVOICE);
    }

    function test_PeriodRaiseAcrossBoundaryDoesNotRestartCycle() public {
        addPO(103, 1);
        uint256 start = po(103).startedAt;
        assertTrue(pay(103, 80 ether, INVOICE));
        vm.warp(start + 1 days - 60);
        bytes32 id = v.queuePOBudgetIncrease(103, 120 ether);
        vm.warp(start + 1 days + 60);
        bytes32 before = ledger(103);
        v.execute(id);
        assertEq(ledger(103), before);
        assertEq(v.poRemaining(103), 120 ether);
        assertTrue(pay(103, 20 ether, OTHER));
        assertEq(v.poRemaining(103), 100 ether);
        assertEq(po(103).totalPaid, 100 ether);
        vm.warp(start + 2 days - 1);
        assertEq(v.poRemaining(103), 100 ether);
        vm.warp(start + 2 days);
        assertEq(v.poRemaining(103), 120 ether);
        assertEq(po(103).startedAt, start);
    }

    function test_RaiseDoesNotBypassPauseVendorExpiryOrDailyLimit() public {
        bytes32 id = v.queuePOBudgetIncrease(102, 300 ether);
        v.pause();
        execute(id);
        blocked(Vault.BlockReason.Paused, 102, 1 ether, INVOICE);
        execute(v.queueResume());
        assertTrue(pay(102, 200 ether, INVOICE));
        blocked(Vault.BlockReason.DailyLimitExceeded, 102, 1 ether, OTHER);
        v.deactivateVendor(7);
        execute(v.queuePOBudgetIncrease(102, 400 ether));
        blocked(Vault.BlockReason.VendorInactive, 102, 1 ether, OTHER);
    }

    function test_ExpiredPOCanChangeCapButCannotExtendOrPay() public {
        uint64 expiry = po(102).expiry;
        bytes32 id = v.queuePOBudgetIncrease(102, 120 ether);
        vm.warp(expiry);
        bytes32 before = ledger(102);
        v.execute(id);
        assertEq(ledger(102), before);
        assertEq(po(102).expiry, expiry);
        assertEq(v.poRemaining(102), 0);
        blocked(Vault.BlockReason.POExpired, 102, 1 ether, INVOICE);
    }

    function test_NewBudgetEntrypointsAreOwnerOnly() public {
        bytes32 id = v.queuePOBudgetIncrease(102, 120 ether);
        vm.startPrank(stranger);
        vm.expectRevert(Vault.UnauthorizedOwner.selector);
        v.decreasePOBudget(102, 50 ether);
        vm.expectRevert(Vault.UnauthorizedOwner.selector);
        v.queuePOBudgetIncrease(102, 150 ether);
        vm.expectRevert(Vault.UnauthorizedOwner.selector);
        v.cancel(id);
        vm.expectRevert(Vault.UnauthorizedOwner.selector);
        v.closePO(102);
        vm.stopPrank();
    }

    function test_OwnerRecipientCannotChangeBudgetDuringPayment() public {
        BudgetCallbackOwner recipient = new BudgetCallbackOwner();
        recipient.create{value: 500 ether}(agent);
        Vault other = recipient.vault();
        vm.prank(agent);
        assertTrue(other.pay(7, address(recipient), 101, 30 ether, INVOICE));
        assertTrue(recipient.decreaseBlocked());
        assertTrue(recipient.increaseBlocked());
        assertTrue(recipient.closeBlocked());
        assertEq(other.totalBudget(), 500 ether);
        assertEq(other.remainingBudget(), 470 ether);
        assertEq(other.pendingPOBudgetChange(101), bytes32(0));
        (,,,,,,,, bool closed,) = other.purchaseOrders(101);
        assertFalse(closed);
    }

    function testFuzz_BudgetChangesPreserveAccounting(uint96 paid, uint96 lower, uint96 higher) public {
        paid = uint96(bound(paid, 1, 100 ether - 1));
        lower = uint96(bound(lower, paid, 100 ether - 1));
        higher = uint96(bound(higher, 100 ether + 1, 500 ether));
        assertTrue(pay(102, paid, INVOICE));
        bytes32 before = ledger(102);
        v.decreasePOBudget(102, lower);
        assertEq(v.poRemaining(102), uint256(lower) - paid);
        assertEq(ledger(102), before);
        execute(v.queuePOBudgetIncrease(102, higher));
        assertEq(v.poRemaining(102), uint256(higher) - paid);
        assertEq(ledger(102), before);
        assertTrue(v.paidInvoices(INVOICE));
    }

    function testFuzz_PeriodLoweringNeverErasesLifetimeSpending(uint32 periods, uint96 cap) public {
        periods = uint32(bound(periods, 1, 10));
        cap = uint96(bound(cap, 0, 100 ether - 1));
        addPO(103, 1);
        uint256 start = po(103).startedAt;
        assertTrue(pay(103, 80 ether, INVOICE));
        vm.warp(start + uint256(periods) * 1 days);
        bytes32 before = ledger(103);
        v.decreasePOBudget(103, cap);
        assertEq(ledger(103), before);
        assertEq(v.poRemaining(103), cap);
        assertEq(po(103).totalPaid, 80 ether);
        assertEq(po(103).startedAt, start);
    }
}
