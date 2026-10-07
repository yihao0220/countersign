// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {CountersignDemo as Vault} from "../src/CountersignDemo.sol";

// Owner 同时是收款合约，验证付款回调不能修改权限或执行到期授权。
contract AgentGovernanceRecipient {
    Vault public vault;
    address public initialAgent;
    bytes32 public pending;
    bool public revokeBlocked;
    bool public queueBlocked;
    bool public executeBlocked;

    function create(address initial) external payable {
        initialAgent = initial;
        vault = new Vault{value: msg.value}(
            initial, payable(address(this)), 500 ether, uint64(block.timestamp + 30 days), 200 ether
        );
        pending = vault.queueAgentAuthorization(address(0xD));
    }

    receive() external payable {
        try vault.revokeAgent(initialAgent) {}
        catch (bytes memory reason) {
            revokeBlocked = bytes4(reason) == Vault.ReentrantCall.selector;
        }
        try vault.queueAgentAuthorization(address(0xE)) returns (bytes32) {}
        catch (bytes memory reason) {
            queueBlocked = bytes4(reason) == Vault.ReentrantCall.selector;
        }
        try vault.execute(pending) {}
        catch (bytes memory reason) {
            executeBlocked = bytes4(reason) == Vault.ReentrantCall.selector;
        }
    }
}

contract AgentsTest is Test {
    Vault internal v;
    address internal a = address(0xA);
    address internal b = address(0xB);
    address payable internal vendor = payable(address(0xC));
    uint64 internal expiry;
    uint256 internal nonce;

    function setUp() public {
        vm.warp(10 days + 1 hours);
        vm.deal(address(this), 1000 ether);
        expiry = uint64(block.timestamp + 30 days);
        v = new Vault{value: 500 ether}(a, vendor, 500 ether, expiry, 200 ether);
    }

    function pay(address caller, uint256 amount) internal returns (bool) {
        bytes32 invoice = bytes32(++nonce);
        vm.prank(caller);
        return v.pay(7, vendor, 101, amount, invoice);
    }

    function authorize(address account) internal returns (bytes32 id) {
        id = v.queueAgentAuthorization(account);
        vm.warp(block.timestamp + 120);
        v.execute(id);
    }

    function test_Demo_RevokeAgentThenAuthorizeNewAgent() public {
        assertTrue(pay(a, 100 ether));
        console2.log("Initial Agent paid 100; remaining budget = 400");
        v.revokeAgent(a);
        vm.expectRevert(Vault.UnauthorizedAgent.selector);
        pay(a, 1 ether);
        assertEq(v.remainingBudget(), 400 ether);
        console2.log("Owner revoked initial Agent immediately; old Agent payment REJECTED");
        bytes32 id = v.queueAgentAuthorization(b);
        vm.expectRevert(Vault.UnauthorizedAgent.selector);
        pay(b, 1 ether);
        vm.expectRevert(Vault.TimelockNotReady.selector);
        v.execute(id);
        console2.log("New Agent waiting; payment and early execution REJECTED");
        vm.warp(block.timestamp + 120);
        vm.prank(address(0xF));
        v.execute(id);
        assertTrue(pay(b, 100 ether));
        assertEq(v.remainingBudget(), 300 ether);
        assertEq(v.spentToday(), 200 ether);
        assertEq(v.totalSpent(), 200 ether);
        assertFalse(pay(b, 1 ether));
        console2.log("After 120 simulated seconds: new Agent paid 100; remaining budget = 300");
        console2.log("Shared daily spend = 200; another 1 BLOCKED by daily limit");
    }

    function test_InitialAgentAuthorizedAndOwnerSeparate() public view {
        assertTrue(v.authorizedAgents(a));
        assertFalse(v.authorizedAgents(address(this)));
        assertEq(v.agent(), a);
        assertFalse(v.authorizedAgents(b));
    }

    function test_QueueEventsAndStoredExactParameters() public {
        bytes32 expected = keccak256(abi.encode(address(v), block.chainid, uint256(1), "agent", b));
        vm.expectEmit(true, true, false, true, address(v));
        emit Vault.AgentAuthorizationQueued(expected, b, block.timestamp + 120);
        assertEq(v.queueAgentAuthorization(b), expected);
        (address account, uint256 due, Vault.ChangeStatus status) = v.agentAuthorizations(expected);
        assertEq(account, b);
        assertEq(due, block.timestamp + 120);
        assertEq(uint256(status), uint256(Vault.ChangeStatus.Pending));
        assertEq(v.pendingAgentAuthorization(b), expected);
        assertFalse(v.authorizedAgents(b));
        assertTrue(v.authorizedAgents(a));
    }

    function test_InvalidAgentAddressesAndActiveAgentRejected() public {
        vm.expectRevert(Vault.InvalidAgentAuthorization.selector);
        v.queueAgentAuthorization(address(0));
        vm.expectRevert(Vault.InvalidAgentAuthorization.selector);
        v.queueAgentAuthorization(address(this));
        vm.expectRevert(Vault.InvalidAgentAuthorization.selector);
        v.queueAgentAuthorization(a);
        vm.expectRevert(Vault.AgentNotAuthorized.selector);
        v.revokeAgent(b);
    }

    function test_SecondPendingSameAddressRejectedWithoutOverwriting() public {
        bytes32 id = v.queueAgentAuthorization(b);
        vm.expectRevert(Vault.ChangeAlreadyPending.selector);
        v.queueAgentAuthorization(b);
        assertEq(v.pendingAgentAuthorization(b), id);
    }

    function test_AnyoneCanExecuteAtExactDueTime() public {
        bytes32 id = v.queueAgentAuthorization(b);
        uint256 due = block.timestamp + 120;
        vm.warp(due - 1);
        vm.expectRevert(Vault.TimelockNotReady.selector);
        v.execute(id);
        assertFalse(v.authorizedAgents(b));
        vm.warp(due);
        vm.expectEmit(true, true, false, true, address(v));
        emit Vault.AgentAuthorizationExecuted(id, b);
        vm.prank(address(0xF));
        v.execute(id);
        assertTrue(v.authorizedAgents(b));
        assertEq(v.pendingAgentAuthorization(b), bytes32(0));
        (,, Vault.ChangeStatus status) = v.agentAuthorizations(id);
        assertEq(uint256(status), uint256(Vault.ChangeStatus.Executed));
    }

    function test_RevocationImmediatelyBlocksWithoutLogsOrAccountChanges() public {
        assertTrue(pay(a, 100 ether));
        vm.expectEmit(true, false, false, true, address(v));
        emit Vault.AgentRevoked(a);
        v.revokeAgent(a);
        vm.recordLogs();
        vm.expectRevert(Vault.UnauthorizedAgent.selector);
        pay(a, 1 ether);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(v.totalSpent(), 100 ether);
        assertEq(v.spentToday(), 100 ether);
        assertEq(v.remainingBudget(), 400 ether);
        assertEq(address(v).balance, 400 ether);
        assertEq(vendor.balance, 100 ether);
        assertFalse(v.paidInvoices(bytes32(uint256(2))));
        assertEq(v.agent(), a); // 初始地址查询不等于当前权限。
    }

    function test_CancelEmitsAndPreventsFutureExecution() public {
        bytes32 id = v.queueAgentAuthorization(b);
        vm.expectEmit(true, true, false, true, address(v));
        emit Vault.AgentAuthorizationCancelled(id, b);
        v.cancel(id);
        assertEq(v.pendingAgentAuthorization(b), bytes32(0));
        vm.warp(block.timestamp + 120);
        vm.expectRevert(Vault.ChangeNotPending.selector);
        v.execute(id);
        vm.expectRevert(Vault.ChangeNotPending.selector);
        v.cancel(id);
        assertFalse(v.authorizedAgents(b));
    }

    function test_RevokeCancelsPendingGrantAtDeadline() public {
        bytes32 id = v.queueAgentAuthorization(b);
        vm.warp(block.timestamp + 120);
        vm.expectEmit(true, true, false, true, address(v));
        emit Vault.AgentAuthorizationCancelled(id, b);
        vm.expectEmit(true, false, false, true, address(v));
        emit Vault.AgentRevoked(b);
        v.revokeAgent(b);
        vm.expectRevert(Vault.ChangeNotPending.selector);
        v.execute(id);
        assertFalse(v.authorizedAgents(b));
        assertEq(v.pendingAgentAuthorization(b), bytes32(0));
    }

    function test_ExecutedGrantCannotRestoreRevokedAgent() public {
        bytes32 id = authorize(b);
        v.revokeAgent(b);
        vm.expectRevert(Vault.ChangeNotPending.selector);
        v.execute(id);
        vm.expectRevert(Vault.ChangeNotPending.selector);
        v.cancel(id);
        vm.expectRevert(Vault.AgentNotAuthorized.selector);
        v.revokeAgent(b);
        assertFalse(v.authorizedAgents(b));
    }

    function test_ReauthorizationNeedsNewFullDelayAndKeepsInvoiceHistory() public {
        assertTrue(pay(a, 100 ether));
        v.revokeAgent(a);
        bytes32 first = v.queueAgentAuthorization(a);
        vm.warp(block.timestamp + 119);
        v.cancel(first);
        bytes32 fresh = v.queueAgentAuthorization(a);
        assertTrue(fresh != first);
        vm.warp(block.timestamp + 119);
        vm.expectRevert(Vault.TimelockNotReady.selector);
        v.execute(fresh);
        vm.warp(block.timestamp + 1);
        v.execute(fresh);
        vm.expectRevert(Vault.ChangeNotPending.selector);
        v.execute(first);
        vm.prank(a);
        assertFalse(v.pay(7, vendor, 101, 100 ether, bytes32(uint256(1))));
        assertEq(v.remainingBudget(), 400 ether);
        assertEq(v.spentToday(), 100 ether);
    }

    function test_MultipleAgentsShareDailyLimitAndRevokingOneLeavesOtherWorking() public {
        authorize(b);
        assertTrue(pay(a, 150 ether));
        assertTrue(pay(b, 50 ether));
        assertFalse(pay(a, 1));
        assertFalse(pay(b, 1));
        v.revokeAgent(a);
        assertFalse(v.paused());
        vm.warp(11 days);
        assertTrue(pay(b, 100 ether));
        assertEq(v.remainingBudget(), 200 ether);
        vm.expectRevert(Vault.UnauthorizedAgent.selector);
        pay(a, 1);
    }

    function test_MultipleAgentsShareTotalBudgetAcrossDays() public {
        authorize(b);
        assertTrue(pay(a, 200 ether));
        vm.warp(11 days);
        assertTrue(pay(b, 200 ether));
        vm.warp(12 days);
        assertTrue(pay(a, 100 ether));
        vm.expectEmit(false, false, false, true, address(v));
        emit Vault.Blocked(uint8(Vault.BlockReason.OverBudget), 7, vendor, 101, 1, bytes32(uint256(4)), b);
        assertFalse(pay(b, 1));
        assertEq(v.totalSpent(), 500 ether);
        assertEq(v.remainingBudget(), 0);
    }

    function test_DuplicateInvoiceAndPaidEventUseActualCallingAgent() public {
        authorize(b);
        assertTrue(pay(a, 50 ether));
        vm.expectEmit(false, false, false, true, address(v));
        emit Vault.Blocked(uint8(Vault.BlockReason.DuplicateInvoice), 7, vendor, 101, 50 ether, bytes32(uint256(1)), b);
        vm.prank(b);
        assertFalse(v.pay(7, vendor, 101, 50 ether, bytes32(uint256(1))));
        vm.expectEmit(true, true, false, true, address(v));
        emit Vault.Paid(7, 101, vendor, 50 ether, bytes32(uint256(2)), b);
        assertTrue(pay(b, 50 ether));
        assertEq(v.remainingBudget(), 400 ether);
    }

    function test_SeparateAgentGrantsAndOtherOperationsDoNotOverwrite() public {
        address c = address(0xD);
        v.pause();
        bytes32 bId = v.queueAgentAuthorization(b);
        bytes32 cId = v.queueAgentAuthorization(c);
        bytes32 totalId = v.queueLimitIncrease(Vault.LimitKind.TotalBudget, 800 ether);
        bytes32 dailyId = v.queueLimitIncrease(Vault.LimitKind.DailyLimit, 300 ether);
        bytes32 payoutId = v.queuePayoutChange(7, address(0xE));
        bytes32 resumeId = v.queueResume();
        v.cancel(bId);
        assertEq(v.pendingAgentAuthorization(c), cId);
        vm.warp(block.timestamp + 120);
        v.execute(cId);
        v.execute(totalId);
        v.execute(dailyId);
        v.execute(payoutId);
        assertTrue(v.paused());
        v.execute(resumeId);
        assertFalse(v.paused());
        assertTrue(v.authorizedAgents(c));
        assertFalse(v.authorizedAgents(b));
        assertEq(v.totalBudget(), 800 ether);
        assertEq(v.dailyLimit(), 300 ether);
        assertEq(v.payout(), address(0xE));
    }

    function test_AuthorizingWhilePausedDoesNotResumePayments() public {
        v.pause();
        authorize(b);
        assertTrue(v.paused());
        assertFalse(pay(b, 100 ether));
        v.revokeAgent(a);
        assertTrue(v.paused());
        assertEq(v.remainingBudget(), 500 ether);
        assertEq(v.spentToday(), 0);
    }

    function test_NewAgentCannotExtendExpiredBudget() public {
        bytes32 id = v.queueAgentAuthorization(b);
        vm.warp(expiry);
        v.execute(id);
        vm.expectEmit(false, false, false, true, address(v));
        emit Vault.Blocked(uint8(Vault.BlockReason.POExpired), 7, vendor, 101, 100 ether, bytes32(uint256(1)), b);
        assertFalse(pay(b, 100 ether));
        assertEq(v.poExpiry(), expiry);
        assertEq(v.totalSpent(), 0);
        assertEq(v.spentToday(), 0);
    }

    function testFuzz_NonOwnerCannotManageAgents(address caller) public {
        vm.assume(caller != address(this));
        bytes32 id = v.queueAgentAuthorization(b);
        vm.startPrank(caller);
        vm.expectRevert(Vault.UnauthorizedOwner.selector);
        v.queueAgentAuthorization(address(0xD));
        vm.expectRevert(Vault.UnauthorizedOwner.selector);
        v.revokeAgent(a);
        vm.expectRevert(Vault.UnauthorizedOwner.selector);
        v.cancel(id);
        vm.stopPrank();
        assertTrue(v.authorizedAgents(a));
        assertEq(v.pendingAgentAuthorization(b), id);
    }

    function testFuzz_RevokedAgentAlwaysUnauthorized(uint256 amount, uint256 timeAdvance) public {
        v.revokeAgent(a);
        vm.warp(block.timestamp + bound(timeAdvance, 0, 40 days));
        vm.recordLogs();
        vm.expectRevert(Vault.UnauthorizedAgent.selector);
        pay(a, amount);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(v.remainingBudget(), 500 ether);
        assertEq(v.totalSpent(), 0);
        assertEq(v.spentToday(), 0);
    }

    function testFuzz_SharedAccountingAfterChangingAgents(uint256 first, uint256 second) public {
        uint256 x = bound(first, 1, 199 ether);
        uint256 y = bound(second, 1, 200 ether - x);
        assertTrue(pay(a, x));
        v.revokeAgent(a);
        authorize(b);
        assertTrue(pay(b, y));
        assertEq(v.totalSpent(), x + y);
        assertEq(v.spentToday(), x + y);
        assertEq(v.remainingBudget(), 500 ether - x - y);
        assertEq(vendor.balance, x + y);
        assertEq(v.poExpiry(), expiry);
    }

    function test_OwnerRecipientCannotMutateAgentPermissionsDuringTransfer() public {
        AgentGovernanceRecipient recipient = new AgentGovernanceRecipient();
        recipient.create{value: 500 ether}(a);
        Vault target = recipient.vault();
        vm.warp(block.timestamp + 120);
        vm.prank(a);
        assertTrue(target.pay(7, address(recipient), 101, 100 ether, bytes32(uint256(1))));
        assertTrue(recipient.revokeBlocked());
        assertTrue(recipient.queueBlocked());
        assertTrue(recipient.executeBlocked());
        assertTrue(target.authorizedAgents(a));
        assertFalse(target.authorizedAgents(address(0xD)));
        assertEq(target.pendingAgentAuthorization(address(0xD)), recipient.pending());
        target.execute(recipient.pending());
        assertTrue(target.authorizedAgents(address(0xD)));
    }
}
