// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {CountersignDemo as Vault} from "../src/CountersignDemo.sol";

contract InitializationTest is Test {
    Vault internal v;
    address internal a = address(0xA);
    address internal b = address(0xB);
    address payable internal vendor = payable(address(0xC));
    address payable internal vendor2 = payable(address(0xD));
    address internal stranger = address(0xE);
    uint64 internal expiry;

    function setUp() public {
        vm.warp(10 days + 1 hours);
        vm.deal(address(this), 1000 ether);
        expiry = uint64(block.timestamp + 365 days);
        v = new Vault(address(0), payable(address(0)), 0, 0, 0);
    }

    function po(uint256 id) internal view returns (Vault.PurchaseOrder memory) {
        (bool ok, bytes memory data) = address(v).staticcall(abi.encodeWithSignature("purchaseOrders(uint256)", id));
        require(ok, "PO query failed");
        return abi.decode(data, (Vault.PurchaseOrder));
    }

    function execute(bytes32 id) internal {
        vm.prank(stranger);
        v.execute(id);
    }

    function fund() internal {
        (bool ok,) = address(v).call{value: 500 ether}("");
        assertTrue(ok);
    }

    function firstPhase() internal {
        bytes32[5] memory ids = [
            v.queueAddVendor(7, vendor),
            v.queueAddVendor(8, vendor2),
            v.queueAgentAuthorization(a),
            v.queueAgentAuthorization(b),
            v.queueLimitIncrease(Vault.LimitKind.DailyLimit, 200 ether)
        ];
        vm.warp(block.timestamp + 119);
        for (uint256 i; i < ids.length; ++i) {
            vm.expectRevert(Vault.TimelockNotReady.selector);
            v.execute(ids[i]);
        }
        assertEq(v.vendorCount(), 0);
        assertFalse(v.authorizedAgents(a));
        assertEq(v.dailyLimit(), 0);
        vm.warp(block.timestamp + 1);
        assertEq(v.vendorCount(), 0); // Passing time does not execute approvals.
        for (uint256 i; i < ids.length; ++i) {
            execute(ids[i]);
        }
    }

    function initialize() internal {
        firstPhase();
        bytes32[3] memory ids =
            [v.queueAddPO(101, 7, 500 ether, expiry, 0), v.queueAddPO(102, 8, 100 ether, expiry, 30), v.queueResume()];
        fund();
        vm.warp(block.timestamp + 119);
        for (uint256 i; i < ids.length; ++i) {
            vm.expectRevert(Vault.TimelockNotReady.selector);
            v.execute(ids[i]);
        }
        assertEq(v.poCount(), 0);
        assertTrue(v.paused());
        vm.warp(block.timestamp + 1);
        assertEq(v.poCount(), 0);
        for (uint256 i; i < ids.length; ++i) {
            execute(ids[i]);
        }
    }

    function pay(uint256 vid, address recipient, uint256 pid, uint256 amount, bytes32 invoice) internal returns (bool) {
        vm.prank(a);
        return v.pay(vid, recipient, pid, amount, invoice);
    }

    function blocked(Vault.BlockReason reason, uint256 vid, address recipient, uint256 pid, bytes32 invoice) internal {
        bytes32 state = keccak256(abi.encode(po(101), po(102), v.totalPaid(), v.spentToday(), v.remainingBudget()));
        uint256 funds = address(v).balance;
        vm.expectEmit(false, false, false, true, address(v));
        emit Vault.Blocked(uint8(reason), vid, recipient, pid, 1 ether, invoice, a);
        assertFalse(pay(vid, recipient, pid, 1 ether, invoice));
        assertEq(address(v).balance, funds);
        assertEq(keccak256(abi.encode(po(101), po(102), v.totalPaid(), v.spentToday(), v.remainingBudget())), state);
        assertFalse(v.paidInvoices(invoice));
    }

    function test_DeploymentStartsEmptyPausedAndUnauthorized() public {
        assertEq(v.owner(), address(this));
        assertEq(v.agent(), address(0));
        assertTrue(v.paused());
        assertEq(v.vendorCount(), 0);
        assertEq(v.poCount(), 0);
        assertEq(v.payout(), address(0));
        assertEq(v.poExpiry(), 0);
        assertEq(v.totalBudget(), 0);
        assertEq(v.remainingBudget(), 0);
        assertEq(v.totalSpent(), 0);
        assertEq(v.dailyLimit(), 0);
        assertEq(v.spentToday(), 0);
        assertEq(v.totalPaid(), 0);
        assertEq(address(v).balance, 0);
        assertFalse(v.authorizedAgents(a));
        vm.recordLogs();
        vm.expectRevert(Vault.UnauthorizedAgent.selector);
        vm.prank(a);
        v.pay(7, vendor, 101, 1 ether, bytes32(uint256(1)));
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_DepositDoesNotInitializePermissionsOrBudget() public {
        fund();
        assertEq(address(v).balance, 500 ether);
        assertEq(v.vendorCount(), 0);
        assertEq(v.poCount(), 0);
        assertEq(v.totalBudget(), 0);
        assertEq(v.dailyLimit(), 0);
        assertTrue(v.paused());
        assertFalse(v.authorizedAgents(a));
    }

    function test_PendingVendorCannotCreatePOEvenAfterTimePasses() public {
        bytes32 id = v.queueAddVendor(7, vendor);
        vm.warp(block.timestamp + 120);
        vm.expectRevert(Vault.InvalidVendor.selector);
        v.queueAddPO(101, 7, 500 ether, expiry, 0);
        execute(id);
        v.queueAddPO(101, 7, 500 ether, expiry, 0);
        assertEq(v.poCount(), 0);
    }

    function test_Demo_EmptyVaultInitializeThenTwoVendorsPay() public {
        assertEq(v.vendorCount(), 0);
        assertEq(v.poCount(), 0);
        assertEq(address(v).balance, 0);
        assertTrue(v.paused());
        console2.log("Empty deployment: 0 vendors; 0 POs; 0 funds; no Agent permission; PAUSED");
        initialize();
        console2.log("Two stages waited 120s each: vendors/Agents/daily cap, then POs/resume");
        assertEq(v.agent(), address(0));
        assertTrue(v.authorizedAgents(a) && v.authorizedAgents(b));
        assertEq(v.vendorCount(), 2);
        assertEq(v.poCount(), 2);
        assertEq(v.payout(), vendor);
        assertEq(v.poExpiry(), expiry);
        assertFalse(v.paused());
        blocked(Vault.BlockReason.POVendorMismatch, 7, vendor, 102, bytes32(uint256(1)));
        assertTrue(pay(7, vendor, 101, 30 ether, bytes32(uint256(2))));
        vm.prank(b);
        assertTrue(v.pay(8, vendor2, 102, 20 ether, bytes32(uint256(3))));
        assertEq(v.poRemaining(101), 470 ether);
        assertEq(v.poRemaining(102), 80 ether);
        assertEq(address(v).balance, 450 ether);
        assertEq(v.spentToday(), 50 ether);
        assertEq(v.totalPaid(), 50 ether);
        assertEq(v.totalSpent(), 30 ether);
        assertEq(v.remainingBudget(), 470 ether);
        console2.log("Vendor 7 paid 30; PO-101 remaining = 470; vendor 8 paid 20; PO-102 remaining = 80");
        console2.log("Vault = 450; shared daily spent = 50; total paid = 50; accounts isolated");
        vm.expectEmit(false, false, false, true, address(v));
        emit Vault.Blocked(uint8(Vault.BlockReason.DuplicateInvoice), 7, vendor, 101, 30 ether, bytes32(uint256(2)), a);
        assertFalse(pay(7, vendor, 101, 30 ether, bytes32(uint256(2))));
        assertEq(address(v).balance, 450 ether);
        v.closePO(102);
        blocked(Vault.BlockReason.POClosed, 8, vendor2, 102, bytes32(uint256(4)));
        v.deactivateVendor(7);
        blocked(Vault.BlockReason.VendorInactive, 7, vendor, 101, bytes32(uint256(5)));
        console2.log("Replay / closed PO / inactive vendor: BLOCKED; balance and payment history retained");
    }

    function test_CancelFirstStageThenRequeueRequiresFullWait() public {
        bytes32[3] memory ids = [
            v.queueAddVendor(7, vendor),
            v.queueAgentAuthorization(a),
            v.queueLimitIncrease(Vault.LimitKind.DailyLimit, 200 ether)
        ];
        for (uint256 i; i < ids.length; ++i) {
            v.cancel(ids[i]);
        }
        vm.warp(block.timestamp + 120);
        for (uint256 i; i < ids.length; ++i) {
            vm.expectRevert(Vault.ChangeNotPending.selector);
            v.execute(ids[i]);
        }
        ids = [
            v.queueAddVendor(7, vendor),
            v.queueAgentAuthorization(a),
            v.queueLimitIncrease(Vault.LimitKind.DailyLimit, 200 ether)
        ];
        vm.warp(block.timestamp + 119);
        for (uint256 i; i < ids.length; ++i) {
            vm.expectRevert(Vault.TimelockNotReady.selector);
            v.execute(ids[i]);
        }
        vm.warp(block.timestamp + 1);
        for (uint256 i; i < ids.length; ++i) {
            execute(ids[i]);
        }
        assertTrue(v.authorizedAgents(a));
        assertEq(v.vendorCount(), 1);
        assertEq(v.poCount(), 0);
        assertTrue(v.paused());
    }

    function test_CancelInitialPOAndResumeThenRequeueRequiresFullWait() public {
        firstPhase();
        bytes32 poId = v.queueAddPO(101, 7, 500 ether, expiry, 0);
        bytes32 resumeId = v.queueResume();
        v.cancel(poId);
        v.cancel(resumeId);
        vm.warp(block.timestamp + 120);
        vm.expectRevert(Vault.ChangeNotPending.selector);
        v.execute(poId);
        vm.expectRevert(Vault.ChangeNotPending.selector);
        v.execute(resumeId);
        poId = v.queueAddPO(101, 7, 500 ether, expiry, 0);
        resumeId = v.queueResume();
        vm.warp(block.timestamp + 119);
        vm.expectRevert(Vault.TimelockNotReady.selector);
        v.execute(poId);
        vm.expectRevert(Vault.TimelockNotReady.selector);
        v.execute(resumeId);
        vm.warp(block.timestamp + 1);
        execute(poId);
        execute(resumeId);
        assertEq(v.poCount(), 1);
        assertFalse(v.paused());
    }

    function test_NonOwnerCannotBootstrapOrCancel() public {
        vm.startPrank(stranger);
        vm.expectRevert(Vault.UnauthorizedOwner.selector);
        v.queueAddVendor(7, vendor);
        vm.expectRevert(Vault.UnauthorizedOwner.selector);
        v.queueAgentAuthorization(a);
        vm.expectRevert(Vault.UnauthorizedOwner.selector);
        v.queueLimitIncrease(Vault.LimitKind.DailyLimit, 200 ether);
        vm.expectRevert(Vault.UnauthorizedOwner.selector);
        v.queueResume();
        vm.expectRevert(Vault.UnauthorizedOwner.selector);
        v.queueAddPO(101, 7, 500 ether, expiry, 0);
        vm.stopPrank();
        bytes32 id = v.queueAddVendor(7, vendor);
        vm.expectRevert(Vault.UnauthorizedOwner.selector);
        vm.prank(stranger);
        v.cancel(id);
    }

    function test_EmptyModeStillRejectsOtherChain() public {
        vm.chainId(1);
        vm.expectRevert(Vault.LocalDemoOnly.selector);
        new Vault(address(0), payable(address(0)), 0, 0, 0);
    }

    function test_EmptyConstructorCannotIncludeFunds() public {
        vm.expectRevert(Vault.InvalidSetup.selector);
        new Vault{value: 1 ether}(address(0), payable(address(0)), 0, 0, 0);
    }

    function test_PartialEmptyConfigurationsRejected() public {
        vm.expectRevert(Vault.InvalidSetup.selector);
        new Vault(a, payable(address(0)), 0, 0, 0);
        vm.expectRevert(Vault.InvalidSetup.selector);
        new Vault(address(0), vendor, 0, 0, 0);
        vm.expectRevert(Vault.InvalidSetup.selector);
        new Vault(address(0), payable(address(0)), 1, 0, 0);
        vm.expectRevert(Vault.InvalidSetup.selector);
        new Vault(address(0), payable(address(0)), 0, expiry, 0);
        vm.expectRevert(Vault.InvalidSetup.selector);
        new Vault(address(0), payable(address(0)), 0, 0, 1);
    }

    function test_ClosedInitialPOCannotBeRegisteredAgainOrExtended() public {
        initialize();
        uint64 fixedExpiry = v.poExpiry();
        v.closePO(101);
        vm.expectRevert(Vault.POAlreadyExists.selector);
        v.queueAddPO(101, 7, 500 ether, expiry + 1 days, 0);
        assertEq(v.poExpiry(), fixedExpiry);
        assertTrue(po(101).closed);
    }

    function test_PO101IsOnceOnlyOtherIDsCanRecur() public {
        firstPhase();
        vm.expectRevert(Vault.InvalidPO.selector);
        v.queueAddPO(101, 7, 100 ether, expiry, 30);
        bytes32 id = v.queueAddPO(102, 7, 100 ether, expiry, 30);
        vm.warp(block.timestamp + 120);
        execute(id);
        assertEq(po(102).periodDays, 30);
        assertEq(v.poExpiry(), 0);
        assertEq(v.totalBudget(), 0);
    }

    function test_EmptyInitializedLegacyQueriesAndBudgetAliasesAgree() public {
        initialize();
        assertTrue(pay(7, vendor, 101, 30 ether, bytes32(uint256(1))));
        v.decreasePOBudget(101, 60 ether);
        assertEq(v.remainingBudget(), 30 ether);
        bytes32 id = v.queuePOBudgetIncrease(101, 120 ether);
        assertEq(v.pendingLimitChange(Vault.LimitKind.TotalBudget), id);
        vm.warp(block.timestamp + 120);
        execute(id);
        assertEq(v.totalBudget(), 120 ether);
        assertEq(v.remainingBudget(), 90 ether);
        assertEq(v.totalSpent(), 30 ether);
        assertEq(v.poExpiry(), expiry);
        address payable replacement = payable(address(0xF));
        id = v.queuePayoutChange(7, replacement);
        vm.warp(block.timestamp + 120);
        execute(id);
        assertEq(v.payout(), replacement);
        blocked(Vault.BlockReason.PayoutMismatch, 7, vendor, 101, bytes32(uint256(2)));
        assertTrue(pay(7, replacement, 101, 1 ether, bytes32(uint256(3))));
    }

    function test_InitializedPeriodicBoundaryPreservesHistoryAndNoAccumulation() public {
        initialize();
        uint256 start = po(102).startedAt;
        assertTrue(pay(8, vendor2, 102, 100 ether, bytes32(uint256(1))));
        vm.warp(start + 30 days - 1);
        blocked(Vault.BlockReason.OverBudget, 8, vendor2, 102, bytes32(uint256(2)));
        vm.warp(start + 30 days);
        assertEq(v.poRemaining(102), 100 ether);
        assertEq(po(102).totalPaid, 100 ether);
        assertEq(address(v).balance, 400 ether);
        assertTrue(v.paidInvoices(bytes32(uint256(1))));
        assertTrue(pay(8, vendor2, 102, 20 ether, bytes32(uint256(2))));
        vm.warp(start + 90 days);
        assertEq(v.poRemaining(102), 100 ether);
        assertEq(po(102).totalPaid, 120 ether);
        assertEq(address(v).balance, 380 ether);
    }

    function testFuzz_FreshPO101CompatibilityTracksPayment(uint256 raw) public {
        initialize();
        uint256 amount = bound(raw, 1, 200 ether);
        assertTrue(pay(7, vendor, 101, amount, bytes32(uint256(1))));
        assertEq(v.totalSpent(), amount);
        assertEq(v.remainingBudget(), 500 ether - amount);
        assertEq(v.poRemaining(101), 500 ether - amount);
        assertEq(v.poExpiry(), expiry);
    }
}
