// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {CountersignDemo as Vault} from "../src/CountersignDemo.sol";

contract GovernanceTimelockTest is Test {
    Vault internal v;
    address internal agent = address(0xA);
    address payable internal vendor = payable(address(0xB));
    address internal stranger = address(0xC);
    address payable internal vendor2 = payable(address(0xD));
    address internal newAgent = address(0xE);
    address payable internal newPayout = payable(address(0xF));

    function setUp() public {
        vm.warp(10 days + 1 hours);
        vm.deal(address(this), 1000 ether);
        v = new Vault{value: 500 ether}(agent, vendor, 500 ether, uint64(block.timestamp + 30 days), 200 ether);
        bytes32 id = v.queueAddPO(102, 7, 100 ether, uint64(block.timestamp + 20 days), 0);
        vm.warp(block.timestamp + 120);
        v.execute(id);
        v.pause();
    }

    receive() external payable {}

    // These are the nine distinct delayed actions; both PO-101 API names share action 4.
    function queue(uint256 action, bool useNewPO101API) internal returns (bytes32) {
        if (action == 0) return v.queueAddVendor(8, vendor2);
        if (action == 1) return v.queueAddPO(103, 7, 50 ether, uint64(block.timestamp + 20 days), 0);
        if (action == 2) return v.queuePayoutChange(7, newPayout);
        if (action == 3) return v.queueResume();
        if (action == 4) {
            return useNewPO101API
                ? v.queuePOBudgetIncrease(101, 600 ether)
                : v.queueLimitIncrease(Vault.LimitKind.TotalBudget, 600 ether);
        }
        if (action == 5) return v.queueLimitIncrease(Vault.LimitKind.DailyLimit, 300 ether);
        if (action == 6) return v.queueAgentAuthorization(newAgent);
        if (action == 7) return v.queueWithdraw(10 ether);
        return v.queuePOBudgetIncrease(102, 150 ether);
    }

    function queueAll(bool useNewPO101API) internal returns (bytes32[9] memory ids) {
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = queue(i, useNewPO101API);
        }
    }

    function metadata(uint256 action, bytes32 id) internal view returns (uint256 eta, Vault.ChangeStatus status) {
        if (action == 0) (,, eta, status) = v.vendorChanges(id);
        else if (action == 1) (,,,,, eta, status) = v.poChanges(id);
        else if (action == 2) (, eta, status) = v.payoutChanges(id);
        else if (action == 3) (eta, status) = v.resumeChanges(id);
        else if (action == 4 || action == 5) (,, eta, status) = v.limitChanges(id);
        else if (action == 6) (, eta, status) = v.agentAuthorizations(id);
        else if (action == 7) (, eta, status) = v.withdrawalChanges(id);
        else (,, eta, status) = v.poBudgetChanges(id);
    }

    function po(uint256 poId) internal view returns (Vault.PurchaseOrder memory) {
        (bool ok, bytes memory data) = address(v).staticcall(abi.encodeWithSignature("purchaseOrders(uint256)", poId));
        require(ok, "PO query failed");
        return abi.decode(data, (Vault.PurchaseOrder));
    }

    function assertUnchanged() internal view {
        (address payout, bool exists, bool active) = v.vendors(8);
        assertEq(payout, address(0));
        assertFalse(exists || active);
        assertEq(v.vendorCount(), 1);
        assertEq(v.poCount(), 2);
        assertFalse(po(103).exists);
        assertEq(v.payout(), vendor);
        assertEq(v.totalBudget(), 500 ether);
        assertEq(v.dailyLimit(), 200 ether);
        assertEq(po(102).cap, 100 ether);
        assertFalse(v.authorizedAgents(newAgent));
        assertTrue(v.authorizedAgents(agent));
        assertTrue(v.paused());
        assertEq(address(v).balance, 500 ether);
        assertEq(v.totalPaid(), 0);
        assertEq(v.spentToday(), 0);
    }

    function assertNoPending() internal view {
        assertEq(v.pendingVendorChange(8), bytes32(0));
        assertEq(v.pendingPOChange(103), bytes32(0));
        assertEq(v.pendingVendorPayoutChange(7), bytes32(0));
        assertEq(v.pendingResumeChange(), bytes32(0));
        assertEq(v.pendingPOBudgetChange(101), bytes32(0));
        assertEq(v.pendingLimitChange(Vault.LimitKind.DailyLimit), bytes32(0));
        assertEq(v.pendingAgentAuthorization(newAgent), bytes32(0));
        assertEq(v.pendingWithdrawal(), bytes32(0));
        assertEq(v.pendingPOBudgetChange(102), bytes32(0));
    }

    function assertExecuted() internal view {
        (address payout, bool exists, bool active) = v.vendors(8);
        assertEq(payout, vendor2);
        assertTrue(exists && active);
        assertEq(v.vendorCount(), 2);
        assertEq(v.poCount(), 3);
        assertTrue(po(103).exists);
        assertEq(po(103).vendorId, 7);
        assertEq(po(103).cap, 50 ether);
        assertEq(v.payout(), newPayout);
        assertEq(v.totalBudget(), 600 ether);
        assertEq(v.dailyLimit(), 300 ether);
        assertEq(po(102).cap, 150 ether);
        assertTrue(v.authorizedAgents(newAgent));
        assertFalse(v.paused());
        assertEq(address(v).balance, 490 ether);
        assertEq(v.totalPaid(), 0);
        assertEq(v.spentToday(), 0);
        assertNoPending();
    }

    function executeAll(bytes32[9] memory ids) internal {
        vm.startPrank(stranger);
        for (uint256 i; i < ids.length; ++i) {
            v.execute(ids[i]);
        }
        vm.stopPrank();
    }

    function test_Demo_AllGovernanceChangesNeedTimelock() public {
        uint256 start = block.timestamp;
        uint256 ownerBalance = address(this).balance;
        bytes32[9] memory ids = queueAll(true);
        assertUnchanged();
        console2.log("Queued 9 delayed actions: vendor, PO, payout, resume, 2 limits, Agent, withdrawal, PO budget");
        console2.log("Queueing changes no active rules; initial constructor settings are separate");
        vm.warp(start + 119);
        for (uint256 i; i < ids.length; ++i) {
            vm.expectRevert(Vault.TimelockNotReady.selector);
            v.execute(ids[i]);
            (uint256 eta, Vault.ChangeStatus status) = metadata(i, ids[i]);
            assertEq(eta, start + 120);
            assertEq(uint8(status), uint8(Vault.ChangeStatus.Pending));
        }
        assertUnchanged();
        console2.log("At 119s: all 9 executions rejected; active rules and funds unchanged");
        vm.warp(start + 120);
        assertUnchanged();
        console2.log("At 120s: nothing executes automatically; a transaction is required");
        executeAll(ids);
        assertExecuted();
        assertEq(address(this).balance - ownerBalance, 10 ether);
        for (uint256 i; i < ids.length; ++i) {
            (, Vault.ChangeStatus status) = metadata(i, ids[i]);
            assertEq(uint8(status), uint8(Vault.ChangeStatus.Executed));
            vm.expectRevert(Vault.ChangeNotPending.selector);
            v.execute(ids[i]);
        }
        console2.log("Anyone can execute the exact Owner-approved content after delay; all 9 executed once");
        console2.log("Withdrawal = 10 to Owner; vault = 490; payment accounting remains zero");
        // New and old PO-101 entry points cannot provide a second pending approval.
        bytes32 cancelled = v.queuePOBudgetIncrease(102, 180 ether);
        v.cancel(cancelled);
        vm.warp(block.timestamp + 120);
        vm.expectRevert(Vault.ChangeNotPending.selector);
        v.execute(cancelled);
        assertEq(po(102).cap, 150 ether);
        console2.log("Cancelled PO raise: cannot execute later; budget remains 150");
    }

    function test_AllCancelledActionsCannotExecuteOrBeCancelledAgain() public {
        bytes32[9] memory ids = queueAll(false);
        for (uint256 i; i < ids.length; ++i) {
            v.cancel(ids[i]);
        }
        vm.warp(block.timestamp + 120);
        for (uint256 i; i < ids.length; ++i) {
            (, Vault.ChangeStatus status) = metadata(i, ids[i]);
            assertEq(uint8(status), uint8(Vault.ChangeStatus.Cancelled));
            vm.expectRevert(Vault.ChangeNotPending.selector);
            v.execute(ids[i]);
            vm.expectRevert(Vault.ChangeNotPending.selector);
            v.cancel(ids[i]);
        }
        assertUnchanged();
        assertNoPending();
    }

    function test_CancellingOneActionDoesNotCancelOtherTypes() public {
        bytes32[9] memory ids = queueAll(true);
        v.cancel(ids[0]);
        vm.warp(block.timestamp + 120);
        vm.expectRevert(Vault.ChangeNotPending.selector);
        v.execute(ids[0]);
        for (uint256 i = 1; i < ids.length; ++i) {
            vm.prank(stranger);
            v.execute(ids[i]);
        }
        assertEq(v.vendorCount(), 1);
        assertTrue(po(103).exists);
        assertEq(po(102).cap, 150 ether);
        assertEq(v.totalBudget(), 600 ether);
        assertEq(v.dailyLimit(), 300 ether);
        assertEq(v.payout(), newPayout);
        assertTrue(v.authorizedAgents(newAgent));
        assertFalse(v.paused());
        assertEq(address(v).balance, 490 ether);
        assertNoPending();
    }

    function test_AllRetriedActionsRestartDelayIncludingPO101Alias() public {
        uint256 start = block.timestamp;
        bytes32[9] memory old = queueAll(true);
        for (uint256 i; i < old.length; ++i) {
            v.cancel(old[i]);
        }
        vm.warp(start + 119);
        bytes32[9] memory fresh = queueAll(false);
        vm.warp(start + 120);
        for (uint256 i; i < old.length; ++i) {
            assertTrue(fresh[i] != old[i]);
            vm.expectRevert(Vault.ChangeNotPending.selector);
            v.execute(old[i]);
            vm.expectRevert(Vault.TimelockNotReady.selector);
            v.execute(fresh[i]);
            (uint256 eta,) = metadata(i, fresh[i]);
            assertEq(eta, start + 239);
        }
        assertUnchanged();
        vm.warp(start + 239);
        executeAll(fresh);
        assertExecuted();
    }

    function test_NonOwnerCannotQueueOrCancelAnyType() public {
        bytes32[9] memory ids = queueAll(false);
        vm.startPrank(stranger);
        for (uint256 i; i < ids.length; ++i) {
            vm.expectRevert(Vault.UnauthorizedOwner.selector);
            queue(i, false);
            vm.expectRevert(Vault.UnauthorizedOwner.selector);
            v.cancel(ids[i]);
        }
        vm.expectRevert(Vault.UnauthorizedOwner.selector);
        v.queuePOBudgetIncrease(101, 700 ether);
        vm.stopPrank();
        assertUnchanged();
    }

    function test_PendingVendorCannotGetPOBeforeRegistrationExecutes() public {
        bytes32 id = v.queueAddVendor(8, vendor2);
        vm.warp(block.timestamp + 120);
        vm.expectRevert(Vault.InvalidVendor.selector);
        v.queueAddPO(103, 8, 50 ether, uint64(block.timestamp + 20 days), 0);
        v.execute(id);
        bytes32 poId = v.queueAddPO(103, 8, 50 ether, uint64(block.timestamp + 20 days), 0);
        vm.expectRevert(Vault.TimelockNotReady.selector);
        v.execute(poId);
        vm.warp(block.timestamp + 120);
        v.execute(poId);
        assertEq(po(103).vendorId, 8);
    }

    function test_ImmediateRestrictionsCancelTheirPendingIncreases() public {
        bytes32[9] memory ids = queueAll(true);
        v.decreasePOBudget(101, 400 ether);
        v.decreaseLimit(Vault.LimitKind.DailyLimit, 100 ether);
        v.decreasePOBudget(102, 50 ether);
        v.revokeAgent(newAgent);
        v.revokeAgent(agent);
        v.deactivateVendor(7);
        v.closePO(102);
        assertTrue(v.paused());
        assertEq(v.totalBudget(), 400 ether);
        assertEq(v.dailyLimit(), 100 ether);
        assertEq(po(102).cap, 50 ether);
        assertTrue(po(102).closed);
        vm.expectRevert(Vault.UnauthorizedAgent.selector);
        vm.prank(agent);
        v.pay(7, vendor, 101, 1 ether, keccak256("revoked"));
        vm.warp(block.timestamp + 120);
        uint256[5] memory cancelled = [uint256(2), 4, 5, 6, 8];
        for (uint256 i; i < cancelled.length; ++i) {
            vm.expectRevert(Vault.ChangeNotPending.selector);
            v.execute(ids[cancelled[i]]);
        }
        vm.expectRevert(Vault.InvalidVendor.selector);
        v.execute(ids[1]);
        v.cancel(ids[1]);
        v.cancel(ids[3]);
        v.execute(ids[0]);
        v.execute(ids[7]);
        assertTrue(v.paused());
        assertEq(v.totalBudget(), 400 ether);
        assertEq(v.dailyLimit(), 100 ether);
        assertFalse(v.authorizedAgents(newAgent));
        assertNoPending();
    }

    function testFuzz_EveryActionRejectsExecutionBeforeItsDeadline(uint8 action, uint64 secondsElapsed) public {
        action = uint8(bound(action, 0, 8));
        secondsElapsed = uint64(bound(secondsElapsed, 0, 119));
        uint256 start = block.timestamp;
        bytes32[9] memory ids = queueAll(true);
        vm.warp(start + secondsElapsed);
        vm.expectRevert(Vault.TimelockNotReady.selector);
        vm.prank(stranger);
        v.execute(ids[action]);
        (, Vault.ChangeStatus status) = metadata(action, ids[action]);
        assertEq(uint8(status), uint8(Vault.ChangeStatus.Pending));
        assertUnchanged();
    }
}
