// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {CountersignDemo as Vault} from "../src/CountersignDemo.sol";

contract PeriodBudgetTest is Test {
    Vault internal v;
    address internal agent = address(0xA);
    address payable internal vendor = payable(address(0xB));
    uint256 internal start;
    bytes32 internal constant FIRST = keccak256("first-period-invoice");
    bytes32 internal constant SECOND = keccak256("second-period-invoice");

    function setUp() public {
        vm.warp(10 days + 1 hours);
        vm.deal(address(this), 2000 ether);
        v = create(1000 ether);
        start = addPO(102, 30, uint64(block.timestamp + 365 days));
    }

    function create(uint256 funds) internal returns (Vault) {
        return new Vault{value: funds}(agent, vendor, 500 ether, uint64(block.timestamp + 365 days), 200 ether);
    }

    function addPO(uint256 poId, uint32 periodDays, uint64 expiry) internal returns (uint256) {
        bytes32 id = v.queueAddPO(poId, 7, 100 ether, expiry, periodDays);
        vm.warp(block.timestamp + 120);
        v.execute(id);
        return block.timestamp;
    }

    function po(uint256 poId) internal view returns (Vault.PurchaseOrder memory) {
        (bool ok, bytes memory data) = address(v).staticcall(abi.encodeWithSignature("purchaseOrders(uint256)", poId));
        require(ok, "PO query failed");
        return abi.decode(data, (Vault.PurchaseOrder));
    }

    function pay(uint256 poId, uint256 amount, bytes32 invoice) internal returns (bool) {
        vm.prank(agent);
        return v.pay(7, vendor, poId, amount, invoice);
    }

    function blocked(Vault.BlockReason reason, uint256 poId, uint256 amount, bytes32 invoice) internal {
        bytes32 state =
            keccak256(abi.encode(po(poId), v.totalPaid(), v.spentToday(), v.totalSpent(), v.remainingBudget()));
        uint256 funds = address(v).balance;
        uint256 received = vendor.balance;
        bool wasPaid = v.paidInvoices(invoice);
        vm.expectEmit(false, false, false, true, address(v));
        emit Vault.Blocked(uint8(reason), 7, vendor, poId, amount, invoice, agent);
        assertFalse(pay(poId, amount, invoice));
        assertEq(address(v).balance, funds);
        assertEq(vendor.balance, received);
        assertEq(
            keccak256(abi.encode(po(poId), v.totalPaid(), v.spentToday(), v.totalSpent(), v.remainingBudget())), state
        );
        assertEq(v.paidInvoices(invoice), wasPaid);
    }

    function test_Demo_ThirtyDayBudgetAndHistory() public {
        assertTrue(pay(102, 100 ether, FIRST));
        assertEq(v.poRemaining(102), 0);
        console2.log("Fixed 30-day PO: PAID 100; remaining = 0; vault = 900");

        vm.warp(start + 1 days);
        assertEq(v.spentToday(), 0);
        assertEq(v.poRemaining(102), 0);
        blocked(Vault.BlockReason.OverBudget, 102, 1 ether, SECOND);
        console2.log("Next UTC day: daily spending = 0; PO still exhausted; BLOCKED");
        vm.warp(start + 30 days - 1);
        assertEq(v.poRemaining(102), 0);
        blocked(Vault.BlockReason.OverBudget, 102, 1 ether, SECOND);
        console2.log("One second before cycle boundary: remaining = 0; BLOCKED");

        vm.warp(start + 30 days);
        assertEq(v.poRemaining(102), 100 ether);
        assertEq(address(v).balance, 900 ether);
        assertEq(po(102).totalPaid, 100 ether);
        assertTrue(v.paidInvoices(FIRST));
        blocked(Vault.BlockReason.DuplicateInvoice, 102, 1 ether, FIRST);
        console2.log("At 30-day boundary: allowance = 100; vault still = 900; duplicate BLOCKED");
        assertTrue(pay(102, 20 ether, SECOND));
        assertEq(v.poRemaining(102), 80 ether);
        assertEq(po(102).totalPaid, 120 ether);
        console2.log("New cycle PAID 20: remaining = 80; lifetime PAID = 120; vault = 880");

        vm.warp(start + 60 days);
        assertEq(v.poRemaining(102), 100 ether);
        console2.log("Next cycle: allowance = 100, not 180; unused 80 does not carry over");
        vm.warp(start + 150 days);
        assertEq(v.poRemaining(102), 100 ether);
        assertEq(address(v).balance, 880 ether);
        assertEq(po(102).totalPaid, 120 ether);
        assertEq(v.totalPaid(), 120 ether);
        assertTrue(v.paidInvoices(FIRST) && v.paidInvoices(SECOND));
        console2.log("Skip several cycles: allowance still = 100; lifetime PAID still = 120");

        v.closePO(102);
        vm.warp(start + 180 days);
        assertEq(v.poRemaining(102), 0);
        blocked(Vault.BlockReason.POClosed, 102, 1 ether, keccak256("closed"));
        console2.log("Closed PO stays closed next cycle; BLOCKED; vault still = 880");
    }

    function test_CycleDoesNotResetSameUTCDaySpending() public {
        uint256 dailyStart = addPO(103, 1, uint64(block.timestamp + 30 days));
        assertTrue(pay(103, 100 ether, FIRST));
        vm.warp(dailyStart + 1 days - 1);
        assertTrue(pay(101, 200 ether, SECOND));
        assertEq(v.spentToday(), 200 ether);
        vm.warp(dailyStart + 1 days);
        assertEq(v.poRemaining(103), 100 ether);
        assertEq(v.spentToday(), 200 ether);
        blocked(Vault.BlockReason.DailyLimitExceeded, 103, 1 ether, keccak256("same-utc-day"));
        assertEq(po(103).totalPaid, 100 ether);
    }

    function test_UTCMidnightDoesNotRestoreThirtyDayAllowance() public {
        assertTrue(pay(102, 100 ether, FIRST));
        vm.warp((start / 1 days + 1) * 1 days - 1);
        assertEq(v.spentToday(), 100 ether);
        vm.warp(block.timestamp + 1);
        assertEq(v.spentToday(), 0);
        assertEq(v.poRemaining(102), 0);
        blocked(Vault.BlockReason.OverBudget, 102, 1 ether, SECOND);
    }

    function test_CycleRestoresAllowanceButNotActualFunds() public {
        v = create(100 ether);
        uint256 fundedStart = addPO(102, 30, uint64(block.timestamp + 365 days));
        assertTrue(pay(102, 100 ether, FIRST));
        assertEq(address(v).balance, 0);
        vm.warp(fundedStart + 30 days);
        assertEq(v.poRemaining(102), 100 ether);
        blocked(Vault.BlockReason.InsufficientFunds, 102, 1 ether, SECOND);
        assertEq(po(102).totalPaid, 100 ether);
    }

    function test_ExpiryExactlyAtCycleBoundaryStillBlocks() public {
        uint64 expiry = uint64(block.timestamp + 120 + 1 days);
        uint256 expiringStart = addPO(103, 1, expiry);
        assertEq(uint256(expiry), expiringStart + 1 days);
        assertTrue(pay(103, 10 ether, FIRST));
        vm.warp(expiry);
        assertEq(v.poRemaining(103), 0);
        blocked(Vault.BlockReason.POExpired, 103, 1 ether, SECOND);
        assertEq(po(103).totalPaid, 10 ether);
    }

    function test_PauseAndInactiveVendorSurviveCycleBoundary() public {
        assertTrue(pay(102, 10 ether, FIRST));
        v.pause();
        vm.warp(start + 30 days);
        assertEq(v.poRemaining(102), 100 ether);
        blocked(Vault.BlockReason.Paused, 102, 1 ether, SECOND);
        v.deactivateVendor(7);
        bytes32 resume = v.queueResume();
        vm.warp(block.timestamp + 120);
        v.execute(resume);
        blocked(Vault.BlockReason.VendorInactive, 102, 1 ether, SECOND);
        assertEq(po(102).totalPaid, 10 ether);
    }

    function testFuzz_SkippingPeriodsNeverAccumulatesAllowance(uint32 periods, uint96 paid) public {
        periods = uint32(bound(periods, 1, 10));
        paid = uint96(bound(paid, 1, 100 ether - 1));
        assertTrue(pay(102, paid, FIRST));
        vm.warp(start + uint256(periods) * 30 days);
        assertEq(v.poRemaining(102), 100 ether);
        assertEq(po(102).totalPaid, paid);
        assertEq(po(102).startedAt, start);
        assertEq(address(v).balance, 1000 ether - paid);
        assertTrue(v.paidInvoices(FIRST));
        blocked(Vault.BlockReason.OverBudget, 102, 100 ether + 1, SECOND);
    }
}
