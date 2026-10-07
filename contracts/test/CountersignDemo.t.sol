// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";
import {CountersignDemo} from "../src/CountersignDemo.sol";

contract RejectingRecipient {
    receive() external payable {
        revert("payment refused");
    }
}

contract ReenteringAgent {
    CountersignDemo public vault;
    bool public reentryBlocked;

    function setVault(CountersignDemo vault_) external {
        vault = vault_;
    }

    receive() external payable {
        try vault.pay(7, address(this), 101, 1 ether, keccak256("nested-invoice")) returns (bool) {
            reentryBlocked = false;
        } catch (bytes memory reason) {
            reentryBlocked = bytes4(reason) == CountersignDemo.ReentrantCall.selector;
        }
    }
}

contract ExecutingRecipient {
    CountersignDemo public vault;
    bytes32 public changeId;
    bool public executionBlocked;

    function configure(CountersignDemo vault_, bytes32 changeId_) external {
        vault = vault_;
        changeId = changeId_;
    }

    receive() external payable {
        try vault.execute(changeId) {
            executionBlocked = false;
        } catch (bytes memory reason) {
            executionBlocked = bytes4(reason) == CountersignDemo.ReentrantCall.selector;
        }
    }
}

contract CountersignDemoTest is Test {
    CountersignDemo internal vault;
    address internal agent;
    address payable internal vendor;
    address internal attacker;
    uint64 internal expiry;
    bytes32 internal constant INVOICE = keccak256("invoice-001");

    function setUp() public {
        agent = makeAddr("agent");
        vendor = payable(makeAddr("vendor"));
        attacker = makeAddr("attacker");
        expiry = uint64(block.timestamp + 30 days);
        // 测试环境凭空创建的虚拟资金，不需要钱包、私钥或真实代币。
        vm.deal(address(this), 2_000 ether);
        vault = new CountersignDemo{value: 500 ether}(agent, vendor, 500 ether, expiry, 500 ether);
    }

    // 用户先看这个测试：500 -> 支付 100 -> 剩余 400 -> 错误地址被拒绝。
    function test_Demo_FirstPaymentThenWrongAddress() public {
        console2.log("Before: budget =", vault.remainingBudget() / 1 ether);
        vm.prank(agent);
        assertTrue(vault.pay(7, vendor, 101, 100 ether, INVOICE));
        assertEq(vendor.balance, 100 ether);
        assertEq(vault.remainingBudget(), 400 ether);
        console2.log("Paid to registered vendor =", vendor.balance / 1 ether);
        console2.log("After payment: budget =", vault.remainingBudget() / 1 ether);

        _expectBlocked(
            CountersignDemo.BlockReason.PayoutMismatch, 7, attacker, 101, 100 ether, keccak256("invoice-002")
        );
        assertEq(attacker.balance, 0);
        assertEq(vault.remainingBudget(), 400 ether);
        console2.log("Wrong address: BLOCKED; attacker received =", attacker.balance);
        console2.log("Budget still =", vault.remainingBudget() / 1 ether);
    }

    function test_PaymentEmitsPaidAndUpdatesAllAccounts() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit CountersignDemo.Paid(7, 101, vendor, 100 ether, INVOICE, agent);
        vm.prank(agent);
        assertTrue(vault.pay(7, vendor, 101, 100 ether, INVOICE));
        assertEq(vault.remainingBudget(), 400 ether);
        assertEq(address(vault).balance, 400 ether);
        assertEq(vendor.balance, 100 ether);
        assertTrue(vault.paidInvoices(INVOICE));
    }

    function test_UnregisteredCallerRevertsWithoutEvents() public {
        vm.recordLogs();
        vm.expectRevert(CountersignDemo.UnauthorizedAgent.selector);
        vm.prank(attacker);
        vault.pay(7, vendor, 101, 100 ether, INVOICE);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0);
        assertEq(vault.remainingBudget(), 500 ether);
        assertEq(address(vault).balance, 500 ether);
        assertFalse(vault.paidInvoices(INVOICE));
    }

    function test_UnknownVendorBlocked() public {
        _expectBlocked(CountersignDemo.BlockReason.UnknownVendor, 8, vendor, 101, 100 ether, INVOICE);
    }

    function test_UnknownPOBlocked() public {
        _expectBlocked(CountersignDemo.BlockReason.UnknownPO, 7, vendor, 102, 100 ether, INVOICE);
    }

    function test_ZeroAmountBlocked() public {
        _expectBlocked(CountersignDemo.BlockReason.InvalidAmount, 7, vendor, 101, 0, INVOICE);
    }

    function test_OverBudgetBlocked() public {
        _expectBlocked(CountersignDemo.BlockReason.OverBudget, 7, vendor, 101, 501 ether, INVOICE);
    }

    function test_SecondPaymentUsesRemainingBudget() public {
        vm.prank(agent);
        assertTrue(vault.pay(7, vendor, 101, 100 ether, INVOICE));
        _expectBlocked(CountersignDemo.BlockReason.OverBudget, 7, vendor, 101, 450 ether, keccak256("invoice-002"));
        assertEq(vendor.balance, 100 ether);
        assertEq(vault.remainingBudget(), 400 ether);
    }

    function test_DuplicateInvoiceBlocked() public {
        vm.prank(agent);
        assertTrue(vault.pay(7, vendor, 101, 100 ether, INVOICE));
        _expectBlocked(CountersignDemo.BlockReason.DuplicateInvoice, 7, vendor, 101, 100 ether, INVOICE);
        assertEq(vendor.balance, 100 ether);
    }

    function test_FullBudgetCanBeSpentExactlyOnce() public {
        vm.prank(agent);
        assertTrue(vault.pay(7, vendor, 101, 500 ether, INVOICE));
        assertEq(vault.remainingBudget(), 0);
        assertEq(address(vault).balance, 0);
        assertEq(vendor.balance, 500 ether);
        _expectBlocked(CountersignDemo.BlockReason.OverBudget, 7, vendor, 101, 1, keccak256("invoice-002"));
    }

    function test_BudgetDoesNotGuaranteeVaultBalance() public {
        vault = new CountersignDemo{value: 50 ether}(agent, vendor, 500 ether, expiry, 500 ether);
        _expectBlocked(CountersignDemo.BlockReason.InsufficientFunds, 7, vendor, 101, 100 ether, INVOICE);
    }

    function test_RejectedInvoiceCanBeRetriedWithCorrectAddress() public {
        _expectBlocked(CountersignDemo.BlockReason.PayoutMismatch, 7, attacker, 101, 100 ether, INVOICE);
        vm.prank(agent);
        assertTrue(vault.pay(7, vendor, 101, 100 ether, INVOICE));
        assertEq(vendor.balance, 100 ether);
    }

    function test_TopUpAddsFundsNotBudget() public {
        (bool ok,) = address(vault).call{value: 50 ether}("");
        assertTrue(ok);
        assertEq(address(vault).balance, 550 ether);
        assertEq(vault.remainingBudget(), 500 ether);
    }

    function test_FailedTransferRollsBackBookkeeping() public {
        RejectingRecipient recipient = new RejectingRecipient();
        vault = new CountersignDemo{value: 500 ether}(agent, payable(address(recipient)), 500 ether, expiry, 500 ether);
        vm.expectRevert(CountersignDemo.TransferFailed.selector);
        vm.prank(agent);
        vault.pay(7, address(recipient), 101, 100 ether, INVOICE);
        assertEq(vault.remainingBudget(), 500 ether);
        assertEq(address(vault).balance, 500 ether);
        assertEq(address(recipient).balance, 0);
        assertFalse(vault.paidInvoices(INVOICE));
    }

    function test_RecipientCannotReenterEvenWhenAlsoAgent() public {
        ReenteringAgent recipient = new ReenteringAgent();
        vault = new CountersignDemo{value: 500 ether}(
            address(recipient), payable(address(recipient)), 500 ether, expiry, 500 ether
        );
        recipient.setVault(vault);
        vm.prank(address(recipient));
        assertTrue(vault.pay(7, address(recipient), 101, 100 ether, INVOICE));
        assertTrue(recipient.reentryBlocked());
        assertEq(address(recipient).balance, 100 ether);
        assertEq(vault.remainingBudget(), 400 ether);
        assertFalse(vault.paidInvoices(keccak256("nested-invoice")));
    }

    function test_DeploymentOnOtherChainsRejected() public {
        vm.chainId(677);
        vm.expectRevert(CountersignDemo.LocalDemoOnly.selector);
        new CountersignDemo(agent, vendor, 500 ether, expiry, 500 ether);
    }

    function test_ZeroAgentRejected() public {
        vm.expectRevert(CountersignDemo.InvalidSetup.selector);
        new CountersignDemo(address(0), vendor, 500 ether, expiry, 500 ether);
    }

    function test_ZeroPayoutRejected() public {
        vm.expectRevert(CountersignDemo.InvalidSetup.selector);
        new CountersignDemo(agent, payable(address(0)), 500 ether, expiry, 500 ether);
    }

    function test_ZeroBudgetRejected() public {
        vm.expectRevert(CountersignDemo.InvalidSetup.selector);
        new CountersignDemo(agent, vendor, 0, expiry, 500 ether);
    }

    function testFuzz_AuthorizedPaymentConservesFunds(uint256 rawAmount) public {
        uint256 amount = bound(rawAmount, 1, 500 ether);
        vm.prank(agent);
        assertTrue(vault.pay(7, vendor, 101, amount, INVOICE));
        assertEq(vendor.balance, amount);
        assertEq(address(vault).balance + vendor.balance, 500 ether);
        assertEq(vault.remainingBudget(), 500 ether - amount);
    }

    function testFuzz_AnyWrongAddressIsBlocked(address wrongAddress) public {
        vm.assume(wrongAddress != vendor);
        _expectBlocked(CountersignDemo.BlockReason.PayoutMismatch, 7, wrongAddress, 101, 100 ether, INVOICE);
    }

    // 第二个演示：AI 不能提交修改；管理员排队后，120 秒到期才能执行。
    function test_Demo_PayoutChangeWaitThenExecute() public {
        address payable newVendor = payable(makeAddr("new-vendor"));
        vm.expectRevert(CountersignDemo.UnauthorizedOwner.selector);
        vm.prank(agent);
        vault.queuePayoutChange(7, newVendor);
        console2.log("Agent cannot queue payout changes: PASS");

        bytes32 changeId = vault.queuePayoutChange(7, newVendor);
        (, uint256 executeAfter,) = vault.payoutChanges(changeId);
        assertEq(vault.payout(), vendor);
        console2.log("Owner queued a change; old payout still active: PASS");

        vm.expectRevert(CountersignDemo.TimelockNotReady.selector);
        vault.execute(changeId);
        console2.log("Early execution rejected: PASS");

        // 仅在测试虚拟机推进时间，不是真的等 120 秒，也不会影响电脑时钟。
        vm.warp(executeAfter);
        vm.prank(attacker);
        vault.execute(changeId);
        assertEq(vault.payout(), newVendor);
        console2.log("After 120 simulated seconds, queued payout applied: PASS");

        _expectBlocked(CountersignDemo.BlockReason.PayoutMismatch, 7, vendor, 101, 100 ether, INVOICE);
        console2.log("Old payout now blocked: PASS");
        vm.prank(agent);
        assertTrue(vault.pay(7, newVendor, 101, 100 ether, INVOICE));
        assertEq(newVendor.balance, 100 ether);
        assertEq(vendor.balance, 0);
        assertEq(vault.remainingBudget(), 400 ether);
        console2.log("New payout received =", newVendor.balance / 1 ether);
        console2.log("Remaining budget =", vault.remainingBudget() / 1 ether);
    }

    function test_OwnerIsDeployerAndSeparateFromAgent() public view {
        assertEq(vault.owner(), address(this));
        assertNotEq(vault.owner(), vault.agent());
    }

    function test_OwnerAsAgentRejected() public {
        vm.expectRevert(CountersignDemo.InvalidSetup.selector);
        new CountersignDemo(address(this), vendor, 500 ether, expiry, 500 ether);
    }

    function test_QueueEmitsExactParametersAndKeepsOldPayout() public {
        address payable newVendor = payable(makeAddr("new-vendor"));
        vm.recordLogs();
        bytes32 changeId = vault.queuePayoutChange(7, newVendor);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(vault));
        assertEq(logs[0].topics[0], keccak256("PayoutChangeQueued(bytes32,uint256,address,address,uint256)"));
        assertEq(logs[0].topics[1], changeId);
        assertEq(logs[0].topics[2], bytes32(uint256(7)));
        (address oldPayout, address queuedPayout, uint256 readyAt) =
            abi.decode(logs[0].data, (address, address, uint256));
        assertEq(oldPayout, vendor);
        assertEq(queuedPayout, newVendor);
        assertEq(readyAt, block.timestamp + 120);
        (address storedPayout, uint256 executeAfter, CountersignDemo.ChangeStatus status) =
            vault.payoutChanges(changeId);
        assertEq(storedPayout, newVendor);
        assertEq(executeAfter, readyAt);
        assertEq(uint8(status), uint8(CountersignDemo.ChangeStatus.Pending));
        assertEq(vault.pendingPayoutChange(), changeId);
        assertEq(vault.payout(), vendor);
    }

    function test_AgentCannotCancelQueuedChange() public {
        bytes32 changeId = vault.queuePayoutChange(7, makeAddr("new-vendor"));
        vm.expectRevert(CountersignDemo.UnauthorizedOwner.selector);
        vm.prank(agent);
        vault.cancel(changeId);
        assertEq(vault.pendingPayoutChange(), changeId);
    }

    function test_OldPayoutStillWorksWhileNewPayoutIsWaiting() public {
        address payable newVendor = payable(makeAddr("new-vendor"));
        vault.queuePayoutChange(7, newVendor);
        _expectBlocked(CountersignDemo.BlockReason.PayoutMismatch, 7, newVendor, 101, 100 ether, INVOICE);
        vm.prank(agent);
        assertTrue(vault.pay(7, vendor, 101, 100 ether, INVOICE));
        assertEq(vendor.balance, 100 ether);
        assertEq(newVendor.balance, 0);
    }

    function test_ExecuteOneSecondBeforeDeadlineRejected() public {
        bytes32 changeId = vault.queuePayoutChange(7, makeAddr("new-vendor"));
        (, uint256 executeAfter,) = vault.payoutChanges(changeId);
        vm.warp(executeAfter - 1);
        vm.expectRevert(CountersignDemo.TimelockNotReady.selector);
        vault.execute(changeId);
        assertEq(vault.payout(), vendor);
        assertEq(vault.pendingPayoutChange(), changeId);
    }

    function test_AnyoneCanExecuteAtDeadlineAndEmitsExactChange() public {
        address payable newVendor = payable(makeAddr("new-vendor"));
        bytes32 changeId = vault.queuePayoutChange(7, newVendor);
        (, uint256 executeAfter,) = vault.payoutChanges(changeId);
        vm.warp(executeAfter);
        assertEq(vault.payout(), vendor); // 到期本身不会自动执行。
        vm.expectEmit(true, false, false, true, address(vault));
        emit CountersignDemo.PayoutChangeExecuted(changeId, vendor, newVendor);
        vm.prank(attacker);
        vault.execute(changeId);
        assertEq(vault.payout(), newVendor);
        assertEq(vault.pendingPayoutChange(), bytes32(0));
        (,, CountersignDemo.ChangeStatus status) = vault.payoutChanges(changeId);
        assertEq(uint8(status), uint8(CountersignDemo.ChangeStatus.Executed));
    }

    function test_ExecutedChangeCannotExecuteOrCancelAgain() public {
        bytes32 changeId = vault.queuePayoutChange(7, makeAddr("new-vendor"));
        (, uint256 executeAfter,) = vault.payoutChanges(changeId);
        vm.warp(executeAfter);
        vault.execute(changeId);
        vm.expectRevert(CountersignDemo.ChangeNotPending.selector);
        vault.execute(changeId);
        vm.expectRevert(CountersignDemo.ChangeNotPending.selector);
        vault.cancel(changeId);
    }

    function test_CancelledChangeEmitsAndCannotExecute() public {
        bytes32 changeId = vault.queuePayoutChange(7, makeAddr("new-vendor"));
        (, uint256 executeAfter,) = vault.payoutChanges(changeId);
        vm.expectEmit(true, false, false, true, address(vault));
        emit CountersignDemo.PayoutChangeCancelled(changeId);
        vault.cancel(changeId);
        assertEq(vault.payout(), vendor);
        assertEq(vault.pendingPayoutChange(), bytes32(0));
        (,, CountersignDemo.ChangeStatus status) = vault.payoutChanges(changeId);
        assertEq(uint8(status), uint8(CountersignDemo.ChangeStatus.Cancelled));
        vm.warp(executeAfter);
        vm.expectRevert(CountersignDemo.ChangeNotPending.selector);
        vault.execute(changeId);
        vm.expectRevert(CountersignDemo.ChangeNotPending.selector);
        vault.cancel(changeId);
    }

    function test_RequeueAfterCancellationRestartsDelayAndUsesNewId() public {
        address newVendor = makeAddr("new-vendor");
        bytes32 firstId = vault.queuePayoutChange(7, newVendor);
        (, uint256 firstDeadline,) = vault.payoutChanges(firstId);
        vm.warp(firstDeadline - 1);
        vault.cancel(firstId);
        bytes32 secondId = vault.queuePayoutChange(7, newVendor);
        (, uint256 secondDeadline,) = vault.payoutChanges(secondId);
        assertNotEq(firstId, secondId);
        assertEq(secondDeadline, block.timestamp + 120);
        vm.warp(firstDeadline);
        vm.expectRevert(CountersignDemo.TimelockNotReady.selector);
        vault.execute(secondId);
    }

    function test_SecondPendingChangeRejectedWithoutOverwritingFirst() public {
        bytes32 firstId = vault.queuePayoutChange(7, makeAddr("first-payout"));
        vm.expectRevert(CountersignDemo.ChangeAlreadyPending.selector);
        vault.queuePayoutChange(7, makeAddr("second-payout"));
        assertEq(vault.pendingPayoutChange(), firstId);
    }

    function test_InvalidPayoutChangesRejected() public {
        vm.expectRevert(CountersignDemo.InvalidPayoutChange.selector);
        vault.queuePayoutChange(8, makeAddr("new-vendor"));
        vm.expectRevert(CountersignDemo.InvalidPayoutChange.selector);
        vault.queuePayoutChange(7, address(0));
        vm.expectRevert(CountersignDemo.InvalidPayoutChange.selector);
        vault.queuePayoutChange(7, vendor);
        assertEq(vault.pendingPayoutChange(), bytes32(0));
    }

    function test_UnknownChangeCannotExecuteOrCancel() public {
        bytes32 unknownId = keccak256("unknown-change");
        vm.expectRevert(CountersignDemo.ChangeNotPending.selector);
        vault.execute(unknownId);
        vm.expectRevert(CountersignDemo.ChangeNotPending.selector);
        vault.cancel(unknownId);
    }

    function test_PayoutChangePreservesBudgetAndPaidInvoiceHistory() public {
        vm.prank(agent);
        assertTrue(vault.pay(7, vendor, 101, 100 ether, INVOICE));
        address payable newVendor = payable(makeAddr("new-vendor"));
        bytes32 changeId = vault.queuePayoutChange(7, newVendor);
        (, uint256 executeAfter,) = vault.payoutChanges(changeId);
        vm.warp(executeAfter);
        vault.execute(changeId);
        assertEq(vault.remainingBudget(), 400 ether);
        assertEq(address(vault).balance, 400 ether);
        assertTrue(vault.paidInvoices(INVOICE));
        _expectBlocked(CountersignDemo.BlockReason.DuplicateInvoice, 7, newVendor, 101, 100 ether, INVOICE);
    }

    function test_RecipientCannotChangePayoutDuringTransfer() public {
        ExecutingRecipient recipient = new ExecutingRecipient();
        vault = new CountersignDemo{value: 500 ether}(agent, payable(address(recipient)), 500 ether, expiry, 500 ether);
        address newVendor = makeAddr("new-vendor");
        bytes32 changeId = vault.queuePayoutChange(7, newVendor);
        recipient.configure(vault, changeId);
        (, uint256 executeAfter,) = vault.payoutChanges(changeId);
        vm.warp(executeAfter);

        vm.expectEmit(true, true, false, true, address(vault));
        emit CountersignDemo.Paid(7, 101, address(recipient), 100 ether, INVOICE, agent);
        vm.prank(agent);
        assertTrue(vault.pay(7, address(recipient), 101, 100 ether, INVOICE));
        assertTrue(recipient.executionBlocked());
        assertEq(vault.payout(), address(recipient));
        assertEq(address(recipient).balance, 100 ether);
        assertEq(vault.pendingPayoutChange(), changeId);
        vault.execute(changeId); // 付款结束后，已到期变更仍然可以正常执行。
        assertEq(vault.payout(), newVendor);
    }

    function testFuzz_NonOwnerCannotQueueChanges(address caller) public {
        vm.assume(caller != vault.owner());
        vm.expectRevert(CountersignDemo.UnauthorizedOwner.selector);
        vm.prank(caller);
        vault.queuePayoutChange(7, makeAddr("new-vendor"));
        assertEq(vault.pendingPayoutChange(), bytes32(0));
    }

    function test_Demo_PauseThenResumeAfterDelay() public {
        assertFalse(vault.paused());
        vault.pause();
        assertTrue(vault.paused());
        console2.log("Owner paused payments immediately: PASS");
        _expectBlocked(CountersignDemo.BlockReason.Paused, 7, vendor, 101, 100 ether, INVOICE);
        assertEq(vendor.balance, 0);
        console2.log("Valid payment blocked while paused; budget still =", vault.remainingBudget() / 1 ether);

        vm.expectRevert(CountersignDemo.UnauthorizedOwner.selector);
        vm.prank(agent);
        vault.queueResume();
        console2.log("Agent cannot queue payment resume: PASS");

        bytes32 changeId = vault.queueResume();
        (uint256 executeAfter,) = vault.resumeChanges(changeId);
        assertTrue(vault.paused());
        vm.expectRevert(CountersignDemo.TimelockNotReady.selector);
        vault.execute(changeId);
        console2.log("Early resume rejected; payments remain paused: PASS");

        vm.warp(executeAfter);
        assertTrue(vault.paused()); // 时间到达后，仍需要发起执行。
        vm.prank(attacker);
        vault.execute(changeId);
        assertFalse(vault.paused());
        console2.log("After 120 simulated seconds, queued resume executed: PASS");

        vm.prank(agent);
        assertTrue(vault.pay(7, vendor, 101, 100 ether, INVOICE));
        assertEq(vendor.balance, 100 ether);
        assertEq(vault.remainingBudget(), 400 ether);
        console2.log("Registered vendor received =", vendor.balance / 1 ether);
        console2.log("Remaining budget =", vault.remainingBudget() / 1 ether);
    }

    function test_PauseImmediatelyEmitsAndPreservesBalances() public {
        assertFalse(vault.paused());
        vm.expectEmit(true, false, false, true, address(vault));
        emit CountersignDemo.Paused(address(this));
        vault.pause();
        assertTrue(vault.paused());
        assertEq(vault.remainingBudget(), 500 ether);
        assertEq(address(vault).balance, 500 ether);
        assertEq(vendor.balance, 0);
        assertFalse(vault.paidInvoices(INVOICE));
    }

    function test_AgentCannotPause() public {
        vm.expectRevert(CountersignDemo.UnauthorizedOwner.selector);
        vm.prank(agent);
        vault.pause();
        assertFalse(vault.paused());
    }

    function test_PausedUnregisteredCallerStillRevertsWithoutBlockedEvents() public {
        vault.pause();
        vm.recordLogs();
        vm.expectRevert(CountersignDemo.UnauthorizedAgent.selector);
        vm.prank(attacker);
        vault.pay(7, vendor, 101, 100 ether, INVOICE);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_RepeatedPauseRejected() public {
        vault.pause();
        vm.expectRevert(CountersignDemo.AlreadyPaused.selector);
        vault.pause();
    }

    function test_ResumeCannotBeQueuedUnlessPaused() public {
        vm.expectRevert(CountersignDemo.NotPaused.selector);
        vault.queueResume();
    }

    function test_ResumeQueueEmitsAndKeepsPaymentsPaused() public {
        vault.pause();
        vm.recordLogs();
        bytes32 changeId = vault.queueResume();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(vault));
        assertEq(logs[0].topics[0], keccak256("ResumeQueued(bytes32,uint256)"));
        assertEq(logs[0].topics[1], changeId);
        assertEq(abi.decode(logs[0].data, (uint256)), block.timestamp + 120);
        (uint256 executeAfter, CountersignDemo.ChangeStatus status) = vault.resumeChanges(changeId);
        assertEq(executeAfter, block.timestamp + 120);
        assertEq(uint8(status), uint8(CountersignDemo.ChangeStatus.Pending));
        assertEq(vault.pendingResumeChange(), changeId);
        assertTrue(vault.paused());
    }

    function test_ResumeOneSecondEarlyRejected() public {
        vault.pause();
        bytes32 changeId = vault.queueResume();
        (uint256 executeAfter,) = vault.resumeChanges(changeId);
        vm.warp(executeAfter - 1);
        vm.expectRevert(CountersignDemo.TimelockNotReady.selector);
        vault.execute(changeId);
        assertTrue(vault.paused());
        assertEq(vault.pendingResumeChange(), changeId);
    }

    function test_ResumeAtDeadlineEmitsAndPreservesPaymentHistory() public {
        vm.prank(agent);
        assertTrue(vault.pay(7, vendor, 101, 100 ether, INVOICE));
        vault.pause();
        bytes32 changeId = vault.queueResume();
        (uint256 executeAfter,) = vault.resumeChanges(changeId);
        vm.warp(executeAfter);
        vm.expectEmit(true, false, false, true, address(vault));
        emit CountersignDemo.ResumeExecuted(changeId);
        vm.prank(attacker);
        vault.execute(changeId);
        assertFalse(vault.paused());
        assertEq(vault.pendingResumeChange(), bytes32(0));
        assertEq(vault.remainingBudget(), 400 ether);
        assertEq(address(vault).balance, 400 ether);
        assertTrue(vault.paidInvoices(INVOICE));
        _expectBlocked(CountersignDemo.BlockReason.DuplicateInvoice, 7, vendor, 101, 100 ether, INVOICE);
    }

    function test_ExecutedResumeCannotExecuteOrCancelAgain() public {
        vault.pause();
        bytes32 changeId = vault.queueResume();
        (uint256 executeAfter,) = vault.resumeChanges(changeId);
        vm.warp(executeAfter);
        vault.execute(changeId);
        vm.expectRevert(CountersignDemo.ChangeNotPending.selector);
        vault.execute(changeId);
        vm.expectRevert(CountersignDemo.ChangeNotPending.selector);
        vault.cancel(changeId);
    }

    function test_CancelledResumeCannotExecuteAndLeavesPaymentsPaused() public {
        vault.pause();
        bytes32 changeId = vault.queueResume();
        (uint256 executeAfter,) = vault.resumeChanges(changeId);
        vm.expectEmit(true, false, false, true, address(vault));
        emit CountersignDemo.ResumeCancelled(changeId);
        vault.cancel(changeId);
        assertTrue(vault.paused());
        assertEq(vault.pendingResumeChange(), bytes32(0));
        (, CountersignDemo.ChangeStatus status) = vault.resumeChanges(changeId);
        assertEq(uint8(status), uint8(CountersignDemo.ChangeStatus.Cancelled));
        vm.warp(executeAfter);
        vm.expectRevert(CountersignDemo.ChangeNotPending.selector);
        vault.execute(changeId);
        vm.expectRevert(CountersignDemo.ChangeNotPending.selector);
        vault.cancel(changeId);
    }

    function test_AgentCannotCancelPendingResume() public {
        vault.pause();
        bytes32 changeId = vault.queueResume();
        vm.expectRevert(CountersignDemo.UnauthorizedOwner.selector);
        vm.prank(agent);
        vault.cancel(changeId);
        assertEq(vault.pendingResumeChange(), changeId);
        assertTrue(vault.paused());
    }

    function test_SecondPendingResumeRejected() public {
        vault.pause();
        bytes32 firstId = vault.queueResume();
        vm.expectRevert(CountersignDemo.ChangeAlreadyPending.selector);
        vault.queueResume();
        assertEq(vault.pendingResumeChange(), firstId);
    }

    function test_RequeueResumeAfterCancellationRestartsFullDelay() public {
        vault.pause();
        bytes32 firstId = vault.queueResume();
        (uint256 firstDeadline,) = vault.resumeChanges(firstId);
        vm.warp(firstDeadline - 1);
        vault.cancel(firstId);
        bytes32 secondId = vault.queueResume();
        (uint256 secondDeadline,) = vault.resumeChanges(secondId);
        assertNotEq(firstId, secondId);
        assertEq(secondDeadline, block.timestamp + 120);
        vm.warp(firstDeadline);
        vm.expectRevert(CountersignDemo.TimelockNotReady.selector);
        vault.execute(secondId);
        assertTrue(vault.paused());
    }

    function test_NewPauseCannotBeUndoneByOldExecutedResume() public {
        vault.pause();
        bytes32 firstId = vault.queueResume();
        (uint256 firstDeadline,) = vault.resumeChanges(firstId);
        vm.warp(firstDeadline);
        vault.execute(firstId);
        vault.pause();
        vm.expectRevert(CountersignDemo.ChangeNotPending.selector);
        vault.execute(firstId);
        assertTrue(vault.paused());
        bytes32 secondId = vault.queueResume();
        (uint256 secondDeadline,) = vault.resumeChanges(secondId);
        assertNotEq(firstId, secondId);
        assertEq(secondDeadline, block.timestamp + 120);
    }

    function test_PayoutChangeCanExecuteWhilePausedWithoutResumingPayments() public {
        address payable newVendor = payable(makeAddr("new-vendor"));
        bytes32 payoutId = vault.queuePayoutChange(7, newVendor);
        vault.pause();
        bytes32 resumeId = vault.queueResume();
        (uint256 executeAfter,) = vault.resumeChanges(resumeId);
        vm.warp(executeAfter);
        vault.execute(payoutId);
        assertEq(vault.payout(), newVendor);
        assertTrue(vault.paused());
        assertEq(vault.pendingResumeChange(), resumeId);
        _expectBlocked(CountersignDemo.BlockReason.Paused, 7, newVendor, 101, 100 ether, INVOICE);
        vault.execute(resumeId);
        assertFalse(vault.paused());
        assertEq(vault.payout(), newVendor);
    }

    function test_ResumeExecutionDoesNotClearPendingPayoutChange() public {
        vault.pause();
        bytes32 resumeId = vault.queueResume();
        bytes32 payoutId = vault.queuePayoutChange(7, makeAddr("new-vendor"));
        (uint256 executeAfter,) = vault.resumeChanges(resumeId);
        vm.warp(executeAfter);
        vault.execute(resumeId);
        assertFalse(vault.paused());
        assertEq(vault.pendingPayoutChange(), payoutId);
        assertEq(vault.payout(), vendor);
        vault.execute(payoutId);
        assertEq(vault.pendingPayoutChange(), bytes32(0));
    }

    function test_CancellingEitherChangeKeepsOtherPendingRecord() public {
        vault.pause();
        bytes32 payoutId = vault.queuePayoutChange(7, makeAddr("new-vendor"));
        bytes32 resumeId = vault.queueResume();
        assertNotEq(payoutId, resumeId);
        vault.cancel(resumeId);
        assertEq(vault.pendingPayoutChange(), payoutId);
        bytes32 secondResumeId = vault.queueResume();
        vault.cancel(payoutId);
        assertEq(vault.pendingResumeChange(), secondResumeId);
        assertTrue(vault.paused());
        assertEq(vault.payout(), vendor);
    }

    function test_FundingWhilePausedDoesNotResumeOrIncreaseBudget() public {
        vault.pause();
        (bool ok,) = address(vault).call{value: 50 ether}("");
        assertTrue(ok);
        assertTrue(vault.paused());
        assertEq(address(vault).balance, 550 ether);
        assertEq(vault.remainingBudget(), 500 ether);
    }

    function testFuzz_PausedPaymentsNeverChangeAccounts(uint256 rawAmount) public {
        uint256 amount = bound(rawAmount, 1, 1_000 ether);
        vault.pause();
        _expectBlocked(CountersignDemo.BlockReason.Paused, 7, vendor, 101, amount, INVOICE);
    }

    function test_Demo_PayBeforeExpiryThenBlockAtAndAfterDeadline() public {
        vm.warp(uint256(expiry) - 1);
        vm.prank(agent);
        assertTrue(vault.pay(7, vendor, 101, 100 ether, INVOICE));
        assertEq(vendor.balance, 100 ether);
        assertEq(vault.remainingBudget(), 400 ether);
        console2.log("One second before deadline: payment succeeded");
        console2.log("Remaining budget =", vault.remainingBudget() / 1 ether);

        bytes32 secondInvoice = keccak256("invoice-002");
        vm.warp(expiry);
        _expectBlocked(CountersignDemo.BlockReason.POExpired, 7, vendor, 101, 100 ether, secondInvoice);
        console2.log("Exactly at deadline: BLOCKED as POExpired; budget still =", vault.remainingBudget() / 1 ether);

        vm.warp(uint256(expiry) + 1);
        _expectBlocked(CountersignDemo.BlockReason.POExpired, 7, vendor, 101, 100 ether, secondInvoice);
        assertEq(vendor.balance, 100 ether);
        assertTrue(vault.paidInvoices(INVOICE));
        assertFalse(vault.paidInvoices(secondInvoice));
        console2.log("After deadline: BLOCKED; vendor total received =", vendor.balance / 1 ether);
        console2.log("Remaining budget still =", vault.remainingBudget() / 1 ether);
    }

    function test_ExpiryIsStoredFromDeploymentInput() public view {
        assertEq(vault.poExpiry(), expiry);
    }

    function test_PaymentOneSecondBeforeExpiryAllowed() public {
        vm.warp(uint256(expiry) - 1);
        vm.prank(agent);
        assertTrue(vault.pay(7, vendor, 101, 100 ether, INVOICE));
        assertEq(vendor.balance, 100 ether);
        assertEq(vault.remainingBudget(), 400 ether);
    }

    function test_PaymentExactlyAtExpiryBlocked() public {
        vm.warp(expiry);
        _expectBlocked(CountersignDemo.BlockReason.POExpired, 7, vendor, 101, 100 ether, INVOICE);
    }

    function test_PaymentAfterExpiryBlocked() public {
        vm.warp(uint256(expiry) + 1);
        _expectBlocked(CountersignDemo.BlockReason.POExpired, 7, vendor, 101, 100 ether, INVOICE);
    }

    function test_ZeroCurrentAndPastExpiryRejectedAtDeployment() public {
        vm.warp(1 days);
        vm.expectRevert(CountersignDemo.InvalidExpiry.selector);
        new CountersignDemo(agent, vendor, 500 ether, 0, 500 ether);
        vm.expectRevert(CountersignDemo.InvalidExpiry.selector);
        new CountersignDemo(agent, vendor, 500 ether, uint64(block.timestamp), 500 ether);
        vm.expectRevert(CountersignDemo.InvalidExpiry.selector);
        new CountersignDemo(agent, vendor, 500 ether, uint64(block.timestamp - 1), 500 ether);
    }

    function test_UnregisteredCallerAfterExpiryCannotCreateBlockedEvents() public {
        vm.warp(expiry);
        vm.recordLogs();
        vm.expectRevert(CountersignDemo.UnauthorizedAgent.selector);
        vm.prank(attacker);
        vault.pay(7, vendor, 101, 100 ether, INVOICE);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(vault.remainingBudget(), 500 ether);
    }

    function test_FundingExpiredVaultDoesNotExtendExpiryOrBudget() public {
        vm.warp(expiry);
        (bool ok,) = address(vault).call{value: 50 ether}("");
        assertTrue(ok);
        assertEq(vault.poExpiry(), expiry);
        assertEq(vault.remainingBudget(), 500 ether);
        assertEq(address(vault).balance, 550 ether);
        _expectBlocked(CountersignDemo.BlockReason.POExpired, 7, vendor, 101, 100 ether, INVOICE);
    }

    function test_PayoutChangeDoesNotExtendExpiredBudget() public {
        address payable newVendor = payable(makeAddr("new-vendor"));
        bytes32 changeId = vault.queuePayoutChange(7, newVendor);
        vm.warp(expiry);
        vault.execute(changeId);
        assertEq(vault.payout(), newVendor);
        assertEq(vault.poExpiry(), expiry);
        _expectBlocked(CountersignDemo.BlockReason.POExpired, 7, newVendor, 101, 100 ether, INVOICE);
        assertEq(newVendor.balance, 0);
    }

    function test_ResumeDoesNotExtendExpiredBudget() public {
        vault.pause();
        bytes32 changeId = vault.queueResume();
        vm.warp(expiry);
        _expectBlocked(CountersignDemo.BlockReason.Paused, 7, vendor, 101, 100 ether, INVOICE);
        vault.execute(changeId);
        assertFalse(vault.paused());
        assertEq(vault.poExpiry(), expiry);
        _expectBlocked(CountersignDemo.BlockReason.POExpired, 7, vendor, 101, 100 ether, INVOICE);
    }

    function testFuzz_PaymentAtOrAfterExpiryNeverChangesAccounts(uint256 rawOffset, uint256 rawAmount) public {
        uint256 offset = bound(rawOffset, 0, 365 days);
        uint256 amount = bound(rawAmount, 1, 500 ether);
        vm.warp(uint256(expiry) + offset);
        _expectBlocked(CountersignDemo.BlockReason.POExpired, 7, vendor, 101, amount, INVOICE);
    }

    function testFuzz_ValidFutureExpiryControlsPaymentBoundary(uint256 rawLifetime) public {
        uint256 lifetime = bound(rawLifetime, 1, 365 days);
        uint64 configuredExpiry = uint64(block.timestamp + lifetime);
        vault = new CountersignDemo{value: 500 ether}(agent, vendor, 500 ether, configuredExpiry, 500 ether);
        vm.warp(uint256(configuredExpiry) - 1);
        vm.prank(agent);
        assertTrue(vault.pay(7, vendor, 101, 100 ether, INVOICE));
        vm.warp(configuredExpiry);
        _expectBlocked(CountersignDemo.BlockReason.POExpired, 7, vendor, 101, 100 ether, keccak256("invoice-002"));
        assertEq(vendor.balance, 100 ether);
        assertEq(vault.remainingBudget(), 400 ether);
    }

    function _expectBlocked(
        CountersignDemo.BlockReason reason,
        uint256 vendorId,
        address payTo,
        uint256 poId,
        uint256 amount,
        bytes32 invoiceHash
    ) internal {
        uint256 budgetBefore = vault.remainingBudget();
        uint256 balanceBefore = address(vault).balance;
        uint256 recipientBefore = payTo.balance;
        bool invoiceBefore = vault.paidInvoices(invoiceHash);
        vm.expectEmit(false, false, false, true, address(vault));
        emit CountersignDemo.Blocked(uint8(reason), vendorId, payTo, poId, amount, invoiceHash, agent);
        vm.prank(agent);
        assertFalse(vault.pay(vendorId, payTo, poId, amount, invoiceHash));
        assertEq(vault.remainingBudget(), budgetBefore);
        assertEq(address(vault).balance, balanceBefore);
        assertEq(payTo.balance, recipientBefore);
        assertEq(vault.paidInvoices(invoiceHash), invoiceBefore);
    }
}
