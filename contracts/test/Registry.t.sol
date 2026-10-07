// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {CountersignDemo as Vault} from "../src/CountersignDemo.sol";

contract WithdrawalOwner {
    Vault public vault;
    bytes32 public withdrawal;
    bool public reject;
    bool public callbackBlocked;

    function create(address a) external payable {
        vault = new Vault{value: msg.value}(
            a, payable(address(0xC)), 500 ether, uint64(block.timestamp + 30 days), 200 ether
        );
    }

    function queue(uint256 amount) external {
        withdrawal = vault.queueWithdraw(amount);
    }

    function setReject(bool value) external {
        reject = value;
    }

    receive() external payable {
        if (reject) revert("reject");
        try vault.execute(withdrawal) {}
            catch (bytes memory reason) {
            callbackBlocked = bytes4(reason) == Vault.ReentrantCall.selector;
        }
    }
}

contract RegistryTest is Test {
    Vault internal v;
    address internal a = address(0xA);
    address payable internal vendor = payable(address(0xC));
    address payable internal vendor2 = payable(address(0xD));
    address internal stranger = address(0xE);
    uint256 internal nonce;

    function setUp() public {
        vm.warp(10 days + 1 hours);
        vm.deal(address(this), 1000 ether);
        v = new Vault{value: 500 ether}(a, vendor, 500 ether, uint64(block.timestamp + 30 days), 200 ether);
    }
    receive() external payable {}

    function execute(bytes32 id) internal {
        vm.warp(block.timestamp + 120);
        vm.prank(stranger);
        v.execute(id);
    }

    function addVendor() internal {
        execute(v.queueAddVendor(8, vendor2));
    }

    function addPO(uint256 id, uint256 vid, uint256 cap, uint32 days_) internal {
        execute(v.queueAddPO(id, vid, cap, uint64(block.timestamp + 20 days), days_));
    }

    function pay(uint256 vid, address recipient, uint256 pid, uint256 amount) internal returns (bool) {
        vm.prank(a);
        return v.pay(vid, recipient, pid, amount, bytes32(++nonce));
    }

    function blocked(Vault.BlockReason reason, uint256 vid, address recipient, uint256 pid, uint256 amount) internal {
        uint256 balance = address(v).balance;
        uint256 daily = v.spentToday();
        vm.expectEmit(false, false, false, true, address(v));
        emit Vault.Blocked(uint8(reason), vid, recipient, pid, amount, bytes32(nonce + 1), a);
        assertFalse(pay(vid, recipient, pid, amount));
        assertEq(address(v).balance, balance);
        assertEq(v.spentToday(), daily);
    }

    function test_VendorWaitThenExecute() public {
        bytes32 id = v.queueAddVendor(8, vendor2);
        blocked(Vault.BlockReason.UnknownVendor, 8, vendor2, 102, 1 ether);
        vm.expectRevert(Vault.TimelockNotReady.selector);
        v.execute(id);
        execute(id);
        (address payout, bool exists, bool active) = v.vendors(8);
        assertEq(payout, vendor2);
        assertTrue(exists && active);
        assertEq(v.vendorCount(), 2);
        vm.expectRevert(Vault.ChangeNotPending.selector);
        v.execute(id);
    }

    // 第一个增量验收：只讲供应商生命周期；已有 PO 接口用于准备付款条件。
    function test_Demo_VendorRegistrationThenDeactivation() public {
        uint256 start = block.timestamp;
        bytes32 id = v.queueAddVendor(8, vendor2);
        assertEq(v.pendingVendorChange(8), id);
        vm.warp(start + 119);
        vm.expectRevert(Vault.TimelockNotReady.selector);
        v.execute(id);
        blocked(Vault.BlockReason.UnknownVendor, 8, vendor2, 102, 10 ether);
        assertEq(vendor2.balance, 0);
        assertFalse(v.paidInvoices(bytes32(nonce)));
        console2.log("At 119s: vendor not registered; BLOCKED; vault =", address(v).balance / 1 ether);

        // 恰好 120 秒也不会自动登记，仍需要执行交易。
        vm.warp(start + 120);
        (, bool exists,) = v.vendors(8);
        assertFalse(exists);
        vm.expectEmit(true, true, false, true, address(v));
        emit Vault.VendorAdded(id, 8, vendor2);
        vm.prank(stranger);
        v.execute(id);
        (address recipient, bool registered, bool active) = v.vendors(8);
        assertEq(recipient, vendor2);
        assertTrue(registered && active);
        assertEq(v.pendingVendorChange(8), bytes32(0));
        console2.log("At 120s: executed; vendor 8 registered and active");

        blocked(Vault.BlockReason.UnknownPO, 8, vendor2, 102, 10 ether);
        console2.log("Registration alone gives no budget: no PO; BLOCKED");
        addPO(102, 8, 100 ether, 0);
        vm.expectEmit(true, true, false, true, address(v));
        emit Vault.Paid(8, 102, vendor2, 10 ether, bytes32(nonce + 1), a);
        assertTrue(pay(8, vendor2, 102, 10 ether));
        assertEq(vendor2.balance, 10 ether);
        assertEq(address(v).balance, 490 ether);
        assertEq(v.poRemaining(102), 90 ether);
        assertTrue(v.paidInvoices(bytes32(nonce)));
        console2.log("With approved PO: PAID 10; vault =", address(v).balance / 1 ether);

        vm.expectEmit(true, false, false, true, address(v));
        emit Vault.VendorDeactivated(8);
        v.deactivateVendor(8);
        blocked(Vault.BlockReason.VendorInactive, 8, vendor2, 102, 10 ether);
        assertEq(vendor2.balance, 10 ether);
        assertEq(v.poRemaining(102), 90 ether);
        assertEq(v.totalPaid(), 10 ether);
        assertEq(v.spentToday(), 10 ether);
        assertFalse(v.paidInvoices(bytes32(nonce)));
        console2.log("Deactivated: BLOCKED; vault =", address(v).balance / 1 ether);
        console2.log("Vendor received = 10; PO remaining = 90; paid history retained");

        bytes32 cancelled = v.queueAddVendor(9, payable(address(0xF)));
        v.cancel(cancelled);
        vm.warp(block.timestamp + 120);
        vm.expectRevert(Vault.ChangeNotPending.selector);
        v.execute(cancelled);
        (, exists,) = v.vendors(9);
        assertFalse(exists);
        assertEq(v.pendingVendorChange(9), bytes32(0));
        console2.log("Cancelled vendor 9: cannot execute after delay");

        assertTrue(pay(7, vendor, 101, 1 ether));
        console2.log("Vendor 7 can still receive: deactivation is isolated");
    }

    function test_VendorCancelRetryFullDelay() public {
        bytes32 first = v.queueAddVendor(8, vendor2);
        v.cancel(first);
        vm.warp(block.timestamp + 119);
        bytes32 second = v.queueAddVendor(8, vendor2);
        assertTrue(first != second);
        vm.warp(block.timestamp + 1);
        vm.expectRevert(Vault.ChangeNotPending.selector);
        v.execute(first);
        vm.expectRevert(Vault.TimelockNotReady.selector);
        v.execute(second);
        execute(second);
    }

    function test_VendorIDsNotOverwritten() public {
        vm.expectRevert(Vault.VendorAlreadyExists.selector);
        v.queueAddVendor(7, vendor2);
        bytes32 id = v.queueAddVendor(8, vendor2);
        vm.expectRevert(Vault.ChangeAlreadyPending.selector);
        v.queueAddVendor(8, vendor);
        execute(id);
        v.deactivateVendor(8);
        vm.expectRevert(Vault.VendorAlreadyExists.selector);
        v.queueAddVendor(8, vendor);
    }

    function test_InvalidVendor() public {
        vm.expectRevert(Vault.InvalidVendor.selector);
        v.queueAddVendor(0, vendor2);
        vm.expectRevert(Vault.InvalidVendor.selector);
        v.queueAddVendor(8, address(0));
        vm.expectRevert(Vault.InvalidVendor.selector);
        v.deactivateVendor(99);
    }

    function test_DeactivateImmediatelyStopsAllVendorPOs() public {
        addVendor();
        addPO(102, 8, 100 ether, 0);
        addPO(103, 8, 100 ether, 0);
        assertTrue(pay(8, vendor2, 102, 10 ether));
        v.deactivateVendor(8);
        blocked(Vault.BlockReason.VendorInactive, 8, vendor2, 102, 1 ether);
        blocked(Vault.BlockReason.VendorInactive, 8, vendor2, 103, 1 ether);
        assertEq(v.poRemaining(102), 90 ether);
        assertTrue(pay(7, vendor, 101, 1 ether));
    }

    function test_DeactivateCancelsOnlyItsPayoutChange() public {
        addVendor();
        bytes32 first = v.queuePayoutChange(7, address(0xF));
        bytes32 second = v.queuePayoutChange(8, address(0x10));
        v.deactivateVendor(8);
        assertEq(v.pendingVendorPayoutChange(8), bytes32(0));
        assertEq(v.pendingPayoutChange(), first);
        vm.warp(block.timestamp + 120);
        vm.expectRevert(Vault.ChangeNotPending.selector);
        v.execute(second);
        v.execute(first);
        assertEq(v.payout(), address(0xF));
    }

    function test_NewVendorPayoutChangeActuallyRoutesPayment() public {
        addVendor();
        addPO(102, 8, 100 ether, 0);
        bytes32 id = v.queuePayoutChange(8, address(0xF));
        execute(id);
        blocked(Vault.BlockReason.PayoutMismatch, 8, vendor2, 102, 1 ether);
        assertTrue(pay(8, address(0xF), 102, 1 ether));
        assertEq(address(0xF).balance, 1 ether);
        assertEq(v.payout(), vendor);
    }

    function test_POIsInactiveUntilExecution() public {
        bytes32 id = v.queueAddPO(102, 7, 100 ether, uint64(block.timestamp + 20 days), 0);
        blocked(Vault.BlockReason.UnknownPO, 7, vendor, 102, 1 ether);
        vm.expectRevert(Vault.TimelockNotReady.selector);
        v.execute(id);
        execute(id);
        assertTrue(pay(7, vendor, 102, 10 ether));
        assertEq(v.poCount(), 2);
        assertEq(v.poRemaining(102), 90 ether);
    }

    function test_POBelongsToOneVendor() public {
        addVendor();
        addPO(102, 8, 100 ether, 0);
        blocked(Vault.BlockReason.POVendorMismatch, 7, vendor, 102, 1 ether);
        blocked(Vault.BlockReason.POVendorMismatch, 8, vendor2, 101, 1 ether);
        assertEq(v.poRemaining(102), 100 ether);
        assertEq(v.poRemaining(101), 500 ether);
    }

    // 第二个增量验收：两家供应商各用自己的 PO、预算与截止时间。
    function test_Demo_MultiplePOsAndVendorOwnership() public {
        addVendor();
        uint256 start = block.timestamp;
        uint64 expiry = uint64(start + 2 days);
        bytes32 id = v.queueAddPO(102, 8, 100 ether, expiry, 0);
        vm.warp(start + 119);
        vm.expectRevert(Vault.TimelockNotReady.selector);
        v.execute(id);
        blocked(Vault.BlockReason.UnknownPO, 8, vendor2, 102, 20 ether);
        assertFalse(v.paidInvoices(bytes32(nonce)));
        console2.log("PO-102 at 119s: not active; BLOCKED; vault =", address(v).balance / 1 ether);

        vm.warp(start + 120);
        vm.expectEmit(true, true, false, true, address(v));
        emit Vault.POAdded(id, 102, 8);
        vm.prank(stranger);
        v.execute(id);
        (uint256 ownerId, uint256 cap,,, uint64 deadline,,,,, bool exists) = v.purchaseOrders(102);
        assertEq(ownerId, 8);
        assertEq(cap, 100 ether);
        assertEq(deadline, expiry);
        assertTrue(exists);
        assertEq(v.poCount(), 2);
        console2.log("PO-101: vendor 7, budget 500; PO-102: vendor 8, budget 100");

        blocked(Vault.BlockReason.POVendorMismatch, 7, vendor, 102, 10 ether);
        assertFalse(v.paidInvoices(bytes32(nonce)));
        blocked(Vault.BlockReason.POVendorMismatch, 8, vendor2, 101, 10 ether);
        assertFalse(v.paidInvoices(bytes32(nonce)));
        assertEq(v.poRemaining(101), 500 ether);
        assertEq(v.poRemaining(102), 100 ether);
        assertEq(v.totalPaid(), 0);
        assertEq(vendor.balance, 0);
        assertEq(vendor2.balance, 0);
        console2.log("Both cross-vendor requests: POVendorMismatch; BLOCKED; budgets unchanged");

        vm.expectEmit(true, true, false, true, address(v));
        emit Vault.Paid(7, 101, vendor, 30 ether, bytes32(nonce + 1), a);
        assertTrue(pay(7, vendor, 101, 30 ether));
        assertTrue(v.paidInvoices(bytes32(nonce)));
        assertEq(v.poRemaining(101), 470 ether);
        assertEq(v.poRemaining(102), 100 ether);
        console2.log("Vendor 7 paid 30: PO-101 remaining = 470; PO-102 still = 100");

        vm.expectEmit(true, true, false, true, address(v));
        emit Vault.Paid(8, 102, vendor2, 20 ether, bytes32(nonce + 1), a);
        assertTrue(pay(8, vendor2, 102, 20 ether));
        assertTrue(v.paidInvoices(bytes32(nonce)));
        assertEq(v.poRemaining(101), 470 ether);
        assertEq(v.poRemaining(102), 80 ether);
        assertEq(vendor.balance, 30 ether);
        assertEq(vendor2.balance, 20 ether);
        assertEq(address(v).balance, 450 ether);
        assertEq(v.totalPaid(), 50 ether);
        assertEq(v.spentToday(), 50 ether);
        (,, uint256 spent1, uint256 paid1,,,,,,) = v.purchaseOrders(101);
        (,, uint256 spent2, uint256 paid2,,,,,,) = v.purchaseOrders(102);
        assertEq(spent1, 30 ether);
        assertEq(paid1, 30 ether);
        assertEq(spent2, 20 ether);
        assertEq(paid2, 20 ether);
        console2.log("Vendor 8 paid 20: PO-102 remaining = 80; PO-101 still = 470");
        console2.log("Shared vault = 450; shared daily spending = 50");

        vm.warp(expiry);
        blocked(Vault.BlockReason.POExpired, 8, vendor2, 102, 1 ether);
        assertFalse(v.paidInvoices(bytes32(nonce)));
        assertEq(vendor2.balance, 20 ether);
        assertEq(v.totalPaid(), 50 ether);
        assertEq(v.poRemaining(101), 470 ether);
        (,, spent2, paid2,,,,,,) = v.purchaseOrders(102);
        assertEq(spent2, 20 ether);
        assertEq(paid2, 20 ether);
        console2.log("At PO-102 deadline: POExpired; BLOCKED; vault still = 450");
        assertTrue(pay(7, vendor, 101, 1 ether));
        assertEq(v.poRemaining(101), 469 ether);
        console2.log("PO-101 remains valid: vendor 7 can still receive");
    }

    function test_SeparatePOBudgetsShareDailyLimitAndBalance() public {
        addVendor();
        addPO(102, 8, 100 ether, 0);
        assertTrue(pay(7, vendor, 101, 150 ether));
        assertTrue(pay(8, vendor2, 102, 50 ether));
        assertEq(v.poRemaining(101), 350 ether);
        assertEq(v.poRemaining(102), 50 ether);
        assertEq(v.totalPaid(), 200 ether);
        assertEq(v.totalSpent(), 150 ether);
        blocked(Vault.BlockReason.DailyLimitExceeded, 8, vendor2, 102, 1 ether);
        vm.warp((block.timestamp / 1 days + 1) * 1 days);
        assertTrue(pay(8, vendor2, 102, 50 ether));
        blocked(Vault.BlockReason.OverBudget, 8, vendor2, 102, 1 ether);
        assertEq(v.poRemaining(101), 350 ether);
    }

    function test_ClosePreservesHistoryAndDoesNotReopen() public {
        addPO(102, 7, 100 ether, 0);
        assertTrue(pay(7, vendor, 102, 10 ether));
        v.closePO(102);
        blocked(Vault.BlockReason.POClosed, 7, vendor, 102, 1 ether);
        assertEq(v.poRemaining(102), 0);
        (,, uint256 spent, uint256 paid,,,,, bool closed, bool exists) = v.purchaseOrders(102);
        assertEq(spent, 10 ether);
        assertEq(paid, 10 ether);
        assertTrue(closed && exists);
        vm.expectRevert(Vault.POAlreadyExists.selector);
        v.queueAddPO(102, 7, 200 ether, uint64(block.timestamp + 20 days), 0);
        vm.expectRevert(Vault.InvalidPO.selector);
        v.closePO(102);
        assertTrue(pay(7, vendor, 101, 1 ether));
    }

    function test_POCancelCannotExecuteOrResetBudget() public {
        bytes32 id = v.queueAddPO(102, 7, 100 ether, uint64(block.timestamp + 20 days), 0);
        v.cancel(id);
        vm.warp(block.timestamp + 120);
        vm.expectRevert(Vault.ChangeNotPending.selector);
        v.execute(id);
        assertEq(v.poCount(), 1);
        addPO(102, 7, 50 ether, 0);
        assertEq(v.poRemaining(102), 50 ether);
    }

    function test_POExecuteRechecksVendorAndExpiry() public {
        addVendor();
        bytes32 id = v.queueAddPO(102, 8, 100 ether, uint64(block.timestamp + 20 days), 0);
        v.deactivateVendor(8);
        vm.warp(block.timestamp + 120);
        vm.expectRevert(Vault.InvalidVendor.selector);
        v.execute(id);
        v.cancel(id);
        uint64 expiry = uint64(block.timestamp + 121);
        bytes32 expired = v.queueAddPO(103, 7, 100 ether, expiry, 0);
        vm.warp(expiry);
        vm.expectRevert(Vault.InvalidPO.selector);
        v.execute(expired);
        v.cancel(expired);
    }

    function test_InvalidPOAndDuplicatePending() public {
        vm.expectRevert(Vault.InvalidPO.selector);
        v.queueAddPO(0, 7, 100 ether, uint64(block.timestamp + 1 days), 0);
        vm.expectRevert(Vault.InvalidPO.selector);
        v.queueAddPO(102, 7, 0, uint64(block.timestamp + 1 days), 0);
        vm.expectRevert(Vault.InvalidPO.selector);
        v.queueAddPO(102, 7, 100 ether, uint64(block.timestamp + 120), 0);
        vm.expectRevert(Vault.InvalidVendor.selector);
        v.queueAddPO(102, 8, 100 ether, uint64(block.timestamp + 1 days), 0);
        v.queueAddPO(102, 7, 100 ether, uint64(block.timestamp + 1 days), 0);
        vm.expectRevert(Vault.ChangeAlreadyPending.selector);
        v.queueAddPO(102, 7, 100 ether, uint64(block.timestamp + 1 days), 0);
    }

    function test_CycleBoundaryRestoresOnlyOnePeriod() public {
        addPO(102, 7, 100 ether, 2);
        uint256 start = block.timestamp;
        assertTrue(pay(7, vendor, 102, 100 ether));
        vm.warp(start + 2 days - 1);
        assertEq(v.poRemaining(102), 0);
        blocked(Vault.BlockReason.OverBudget, 7, vendor, 102, 1 ether);
        vm.warp(start + 2 days);
        assertEq(v.poRemaining(102), 100 ether);
        assertTrue(pay(7, vendor, 102, 25 ether));
        assertEq(v.poRemaining(102), 75 ether);
        vm.warp(start + 8 days);
        assertEq(v.poRemaining(102), 100 ether);
        assertTrue(pay(7, vendor, 102, 100 ether));
        assertEq(v.totalPaid(), 225 ether);
    }

    function test_CycleCannotClearDuplicateOrClosedOrExpiry() public {
        addPO(102, 7, 100 ether, 1);
        bytes32 hash = keccak256("invoice");
        vm.prank(a);
        assertTrue(v.pay(7, vendor, 102, 1 ether, hash));
        vm.warp(block.timestamp + 1 days);
        vm.prank(a);
        assertFalse(v.pay(7, vendor, 102, 1 ether, hash));
        v.closePO(102);
        vm.warp(block.timestamp + 1 days);
        assertEq(v.poRemaining(102), 0);
        addPO(103, 7, 100 ether, 1);
        vm.warp(block.timestamp + 20 days);
        blocked(Vault.BlockReason.POExpired, 7, vendor, 103, 1 ether);
    }

    function test_CannotReuseInvoiceAcrossPOs() public {
        addPO(102, 7, 100 ether, 0);
        bytes32 hash = keccak256("invoice");
        vm.prank(a);
        assertTrue(v.pay(7, vendor, 101, 1 ether, hash));
        vm.prank(a);
        assertFalse(v.pay(7, vendor, 102, 1 ether, hash));
        assertEq(v.poRemaining(102), 100 ether);
    }

    function test_WithdrawalWaitFixedRecipientAndAccounting() public {
        assertTrue(pay(7, vendor, 101, 10 ether));
        bytes32 id = v.queueWithdraw(25 ether);
        vm.expectRevert(Vault.TimelockNotReady.selector);
        v.execute(id);
        uint256 before = address(this).balance;
        execute(id);
        assertEq(address(this).balance - before, 25 ether);
        assertEq(address(v).balance, 465 ether);
        assertEq(v.totalPaid(), 10 ether);
        assertEq(v.spentToday(), 10 ether);
        assertEq(v.remainingBudget(), 490 ether);
        vm.expectRevert(Vault.ChangeNotPending.selector);
        v.execute(id);
    }

    function test_WithdrawalCancelRetryAndPendingProtection() public {
        bytes32 first = v.queueWithdraw(25 ether);
        vm.expectRevert(Vault.ChangeAlreadyPending.selector);
        v.queueWithdraw(1 ether);
        v.cancel(first);
        bytes32 second = v.queueWithdraw(10 ether);
        vm.warp(block.timestamp + 120);
        vm.expectRevert(Vault.ChangeNotPending.selector);
        v.execute(first);
        v.execute(second);
        assertEq(address(v).balance, 490 ether);
    }

    function test_WithdrawalRechecksFundsAndCanRetryAfterFunding() public {
        bytes32 id = v.queueWithdraw(500 ether);
        assertTrue(pay(7, vendor, 101, 100 ether));
        vm.warp(block.timestamp + 120);
        vm.expectRevert(Vault.InvalidWithdrawal.selector);
        v.execute(id);
        assertEq(v.pendingWithdrawal(), id);
        (,, Vault.ChangeStatus status) = v.withdrawalChanges(id);
        assertEq(uint8(status), 1);
        (bool ok,) = address(v).call{value: 100 ether}("");
        assertTrue(ok);
        v.execute(id);
        assertEq(address(v).balance, 0);
        blocked(Vault.BlockReason.InsufficientFunds, 7, vendor, 101, 1 ether);
    }

    function test_InvalidWithdrawalAndWithdrawalWhilePaused() public {
        vm.expectRevert(Vault.InvalidWithdrawal.selector);
        v.queueWithdraw(0);
        vm.expectRevert(Vault.InvalidWithdrawal.selector);
        v.queueWithdraw(501 ether);
        bytes32 id = v.queueWithdraw(25 ether);
        v.pause();
        execute(id);
        assertTrue(v.paused());
        assertEq(address(v).balance, 475 ether);
    }

    function test_WithdrawalTransferFailureRollsBackAndCallbackCannotReenter() public {
        WithdrawalOwner recipient = new WithdrawalOwner();
        recipient.create{value: 500 ether}(a);
        Vault other = recipient.vault();
        recipient.queue(25 ether);
        recipient.setReject(true);
        vm.warp(block.timestamp + 120);
        bytes32 id = recipient.withdrawal();
        vm.expectRevert(Vault.TransferFailed.selector);
        other.execute(id);
        assertEq(address(other).balance, 500 ether);
        assertEq(other.pendingWithdrawal(), recipient.withdrawal());
        recipient.setReject(false);
        other.execute(recipient.withdrawal());
        assertTrue(recipient.callbackBlocked());
        assertEq(address(other).balance, 475 ether);
    }

    function test_NewGovernanceIsOwnerOnly() public {
        vm.startPrank(stranger);
        vm.expectRevert(Vault.UnauthorizedOwner.selector);
        v.queueAddVendor(8, vendor2);
        vm.expectRevert(Vault.UnauthorizedOwner.selector);
        v.deactivateVendor(7);
        vm.expectRevert(Vault.UnauthorizedOwner.selector);
        v.queueAddPO(102, 7, 100 ether, uint64(block.timestamp + 1 days), 0);
        vm.expectRevert(Vault.UnauthorizedOwner.selector);
        v.closePO(101);
        vm.expectRevert(Vault.UnauthorizedOwner.selector);
        v.queueWithdraw(1 ether);
        vm.stopPrank();
    }

    function testFuzz_IndependentPOAccounting(uint128 x, uint128 y) public {
        x = uint128(bound(x, 1, 100 ether));
        y = uint128(bound(y, 1, 100 ether));
        addPO(102, 7, 100 ether, 0);
        assertTrue(pay(7, vendor, 101, x));
        assertTrue(pay(7, vendor, 102, y));
        assertEq(v.poRemaining(101), 500 ether - x);
        assertEq(v.poRemaining(102), 100 ether - y);
        assertEq(v.totalPaid(), uint256(x) + y);
        assertEq(v.spentToday(), uint256(x) + y);
    }

    function testFuzz_PeriodUnusedAllowanceNeverAccumulates(uint32 periods) public {
        periods = uint32(bound(periods, 1, 10));
        addPO(102, 7, 100 ether, 1);
        uint256 start = block.timestamp;
        assertTrue(pay(7, vendor, 102, 1 ether));
        vm.warp(start + uint256(periods) * 1 days);
        assertEq(v.poRemaining(102), 100 ether);
        blocked(Vault.BlockReason.OverBudget, 7, vendor, 102, 101 ether);
    }
}
