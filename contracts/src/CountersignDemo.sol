// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @title CountersignDemo
/// @notice 本地教学版本：可管理的 Agent、供应商登记、多采购单与共享每日上限。
/// @dev 仅允许 chain ID 31337。地址变更、恢复、提额和 Agent 授权需要时间锁，不用于正式金库。
contract CountersignDemo {
    uint256 public constant VENDOR_ID = 7;
    uint256 public constant PO_ID = 101;
    uint256 public constant DELAY = 120;

    // 第一步：保存规则。Owner 是创建合约的地址，与 Agent 分开。
    address public immutable owner;
    // 保留初始 Agent 的查询入口；空模式为零，当前权限以 authorizedAgents 为准。
    address public immutable agent;
    mapping(address => bool) public authorizedAgents;
    // Legacy getters describe vendor 7 / PO 101 only. Other POs keep independent budgets.
    address payable public payout;

    struct Vendor {
        address payable payout;
        bool exists;
        bool active;
    }
    mapping(uint256 => Vendor) public vendors;
    uint256[] public vendorIds;

    struct PurchaseOrder {
        uint256 vendorId;
        uint256 cap;
        uint256 spent;
        uint256 totalPaid;
        uint64 expiry;
        uint32 periodDays;
        uint64 startedAt;
        uint256 period;
        bool closed;
        bool exists;
    }
    mapping(uint256 => PurchaseOrder) public purchaseOrders;
    uint256[] public poIds;
    uint256 public totalPaid;

    struct VendorChange {
        uint256 vendorId;
        address payable payout;
        uint256 executeAfter;
        ChangeStatus status;
    }
    mapping(bytes32 => VendorChange) public vendorChanges;
    mapping(uint256 => bytes32) public pendingVendorChange;

    struct POChange {
        uint256 poId;
        uint256 vendorId;
        uint256 cap;
        uint64 expiry;
        uint32 periodDays;
        uint256 executeAfter;
        ChangeStatus status;
    }
    mapping(bytes32 => POChange) public poChanges;
    mapping(uint256 => bytes32) public pendingPOChange;

    struct POBudgetChange {
        uint256 poId;
        uint256 newCap;
        uint256 executeAfter;
        ChangeStatus status;
    }
    // PO-101 keeps its legacy LimitChange record; other POs use these records.
    mapping(bytes32 => POBudgetChange) public poBudgetChanges;
    mapping(uint256 => bytes32) private pendingOtherPOBudgetChange;

    struct WithdrawalChange {
        uint256 amount;
        uint256 executeAfter;
        ChangeStatus status;
    }
    mapping(bytes32 => WithdrawalChange) public withdrawalChanges;
    bytes32 public pendingWithdrawal;
    mapping(bytes32 => uint256) public payoutChangeVendor;
    mapping(uint256 => bytes32) public pendingVendorPayoutChange;

    uint256 public remainingBudget;
    uint256 public totalBudget;
    uint256 public totalSpent;
    uint256 public dailyLimit;
    mapping(uint256 => uint256) public spentByDay;

    enum LimitKind {
        TotalBudget,
        DailyLimit
    }

    struct LimitChange {
        LimitKind kind;
        uint256 newLimit;
        uint256 executeAfter;
        ChangeStatus status;
    }
    mapping(bytes32 => LimitChange) public limitChanges;
    mapping(LimitKind => bytes32) public pendingLimitChange;
    // Set once when PO-101 is created (in the constructor or through its delayed registration).
    uint64 public poExpiry;
    mapping(bytes32 => bool) public paidInvoices;
    bool public paused;
    bool private entered;

    // 第二个小任务：记录地址变更及其状态。演示版同时只允许一项待执行变更。
    enum ChangeStatus {
        None,
        Pending,
        Executed,
        Cancelled
    }

    struct PayoutChange {
        address payable newPayout;
        uint256 executeAfter;
        ChangeStatus status;
    }

    mapping(bytes32 => PayoutChange) public payoutChanges;
    bytes32 public pendingPayoutChange;

    // 恢复付款使用独立记录，避免与待执行的地址修改相互覆盖。
    struct ResumeChange {
        uint256 executeAfter;
        ChangeStatus status;
    }

    mapping(bytes32 => ResumeChange) public resumeChanges;
    bytes32 public pendingResumeChange;

    struct AgentAuthorization {
        address account;
        uint256 executeAfter;
        ChangeStatus status;
    }

    mapping(bytes32 => AgentAuthorization) public agentAuthorizations;
    mapping(address => bytes32) public pendingAgentAuthorization;
    uint256 private changeNonce;

    // 演示版编号，不是团队正式接口的最终编号。
    enum BlockReason {
        None,
        UnknownVendor,
        PayoutMismatch,
        UnknownPO,
        InvalidAmount,
        OverBudget,
        DuplicateInvoice,
        InsufficientFunds,
        Paused,
        POExpired,
        DailyLimitExceeded,
        VendorInactive,
        POVendorMismatch,
        POClosed
    }

    error InvalidVendor();
    error VendorAlreadyExists();
    error InvalidPO();
    error POAlreadyExists();
    error InvalidWithdrawal();
    event VendorQueued(bytes32 indexed changeId, uint256 indexed vendorId, address payout, uint256 executeAfter);
    event VendorAdded(bytes32 indexed changeId, uint256 indexed vendorId, address payout);
    event VendorChangeCancelled(bytes32 indexed changeId, uint256 indexed vendorId);
    event VendorDeactivated(uint256 indexed vendorId);
    event POQueued(
        bytes32 indexed changeId,
        uint256 indexed poId,
        uint256 vendorId,
        uint256 cap,
        uint64 expiry,
        uint32 periodDays,
        uint256 executeAfter
    );
    event POAdded(bytes32 indexed changeId, uint256 indexed poId, uint256 vendorId);
    event POChangeCancelled(bytes32 indexed changeId, uint256 indexed poId);
    event POClosed(uint256 indexed poId);
    event POBudgetChangeQueued(bytes32 indexed changeId, uint256 indexed poId, uint256 newCap, uint256 executeAfter);
    event POBudgetChanged(uint256 indexed poId, uint256 oldCap, uint256 newCap);
    event POBudgetChangeExecuted(bytes32 indexed changeId, uint256 indexed poId);
    event POBudgetChangeCancelled(bytes32 indexed changeId, uint256 indexed poId);
    event WithdrawalQueued(bytes32 indexed changeId, uint256 amount, uint256 executeAfter);
    event WithdrawalExecuted(bytes32 indexed changeId, address indexed payTo, uint256 amount);
    event WithdrawalCancelled(bytes32 indexed changeId);

    error LocalDemoOnly();
    error InvalidSetup();
    error InvalidExpiry();
    error UnauthorizedAgent();
    error UnauthorizedOwner();
    error ReentrantCall();
    error TransferFailed();
    error InvalidPayoutChange();
    error ChangeAlreadyPending();
    error ChangeNotPending();
    error TimelockNotReady();
    error AlreadyPaused();
    error NotPaused();
    error InvalidLimitChange();
    error InvalidAgentAuthorization();
    error AgentNotAuthorized();
    event AgentAuthorizationQueued(bytes32 indexed changeId, address indexed account, uint256 executeAfter);
    event AgentAuthorizationExecuted(bytes32 indexed changeId, address indexed account);
    event AgentAuthorizationCancelled(bytes32 indexed changeId, address indexed account);
    event AgentRevoked(address indexed account);
    event LimitChangeQueued(bytes32 indexed changeId, LimitKind indexed kind, uint256 newLimit, uint256 executeAfter);
    event LimitChanged(LimitKind indexed kind, uint256 oldLimit, uint256 newLimit);
    event LimitChangeExecuted(bytes32 indexed changeId);
    event LimitChangeCancelled(bytes32 indexed changeId);

    event Paused(address indexed account);
    event ResumeQueued(bytes32 indexed changeId, uint256 executeAfter);
    event ResumeExecuted(bytes32 indexed changeId);
    event ResumeCancelled(bytes32 indexed changeId);

    event PayoutChangeQueued(
        bytes32 indexed changeId, uint256 indexed vendorId, address oldPayout, address newPayout, uint256 executeAfter
    );
    event PayoutChangeExecuted(bytes32 indexed changeId, address oldPayout, address newPayout);
    event PayoutChangeCancelled(bytes32 indexed changeId);

    event Paid(
        uint256 indexed vendorId,
        uint256 indexed poId,
        address payTo,
        uint256 amount,
        bytes32 invoiceHash,
        address agent
    );

    event Blocked(
        uint8 reason, uint256 vendorId, address payTo, uint256 poId, uint256 amount, bytes32 invoiceHash, address agent
    );

    /// @notice 五参数全零且不附资金时创建暂停的空金库；其他合法配置保留原预置演示。
    /// @param agent_ 初始授权的 Agent；空模式为零，后续由 Owner 管理权限。
    /// @param payout_ 供应商的初始收款地址。
    /// @param budget_ 预算，以本地原生币的最小单位计数。
    /// @param expiry_ 预算截止时间，Unix 秒数；到达该时刻即过期，创建后固定。
    /// @param dailyLimit_ 每个 UTC 日历日的付款上限；零表示不允许付款。
    constructor(address agent_, address payable payout_, uint256 budget_, uint64 expiry_, uint256 dailyLimit_) payable {
        if (block.chainid != 31337) revert LocalDemoOnly();
        owner = msg.sender;
        agent = agent_;
        if (agent_ == address(0) && payout_ == address(0) && budget_ == 0 && expiry_ == 0 && dailyLimit_ == 0) {
            if (msg.value != 0) revert InvalidSetup();
            paused = true;
            return;
        }
        if (agent_ == address(0) || agent_ == msg.sender || payout_ == address(0) || budget_ == 0) {
            revert InvalidSetup();
        }
        if (expiry_ <= block.timestamp) revert InvalidExpiry();
        authorizedAgents[agent_] = true;
        payout = payout_;
        remainingBudget = budget_;
        totalBudget = budget_;
        dailyLimit = dailyLimit_;
        poExpiry = expiry_;
        vendors[VENDOR_ID] = Vendor(payout_, true, true);
        vendorIds.push(VENDOR_ID);
        purchaseOrders[PO_ID] =
            PurchaseOrder(VENDOR_ID, budget_, 0, 0, expiry_, 0, uint64(block.timestamp), 0, false, true);
        poIds.push(PO_ID);
    }

    /// @notice UTC 日历日；跨天不改变总预算和截止时间。
    function spentToday() public view returns (uint256) {
        return spentByDay[block.timestamp / 1 days];
    }

    /// @notice 新增或重新授权都需要完整等待；每个地址最多一项待执行申请。
    function queueAgentAuthorization(address account) external onlyOwner nonReentrant returns (bytes32 changeId) {
        if (account == address(0) || account == owner || authorizedAgents[account]) {
            revert InvalidAgentAuthorization();
        }
        if (pendingAgentAuthorization[account] != bytes32(0)) revert ChangeAlreadyPending();

        changeNonce += 1;
        changeId = keccak256(abi.encode(address(this), block.chainid, changeNonce, "agent", account));
        uint256 executeAfter = block.timestamp + DELAY;
        agentAuthorizations[changeId] = AgentAuthorization(account, executeAfter, ChangeStatus.Pending);
        pendingAgentAuthorization[account] = changeId;
        emit AgentAuthorizationQueued(changeId, account, executeAfter);
    }

    /// @notice 立即撤销权限或待执行授权；不暂停其他 Agent，不重置账目。
    function revokeAgent(address account) external onlyOwner nonReentrant {
        bytes32 pending = pendingAgentAuthorization[account];
        if (!authorizedAgents[account] && pending == bytes32(0)) revert AgentNotAuthorized();
        if (pending != bytes32(0)) _cancelAgentAuthorization(pending);
        authorizedAgents[account] = false;
        emit AgentRevoked(account);
    }

    function _executeAgentAuthorization(bytes32 changeId) private {
        AgentAuthorization storage change = agentAuthorizations[changeId];
        if (change.status != ChangeStatus.Pending) revert ChangeNotPending();
        if (block.timestamp < change.executeAfter) revert TimelockNotReady();

        change.status = ChangeStatus.Executed;
        pendingAgentAuthorization[change.account] = bytes32(0);
        authorizedAgents[change.account] = true;
        emit AgentAuthorizationExecuted(changeId, change.account);
    }

    function _cancelAgentAuthorization(bytes32 changeId) private {
        AgentAuthorization storage change = agentAuthorizations[changeId];
        if (change.status != ChangeStatus.Pending) revert ChangeNotPending();

        change.status = ChangeStatus.Cancelled;
        pendingAgentAuthorization[change.account] = bytes32(0);
        emit AgentAuthorizationCancelled(changeId, change.account);
    }

    /// @notice 仅 Owner 可立即降低额度，包括降为零；取消同类旧提额申请。
    function decreaseLimit(LimitKind kind, uint256 newLimit) external onlyOwner nonReentrant {
        _decreaseLimit(kind, newLimit);
    }

    function _decreaseLimit(LimitKind kind, uint256 newLimit) private {
        if (kind == LimitKind.TotalBudget) _requireOpenPO(PO_ID);
        if (newLimit >= _limit(kind) || (kind == LimitKind.TotalBudget && newLimit < totalSpent)) {
            revert InvalidLimitChange();
        }
        bytes32 pending = pendingLimitChange[kind];
        if (pending != bytes32(0)) _cancelLimit(pending);
        _setLimit(kind, newLimit);
    }

    function queueLimitIncrease(LimitKind kind, uint256 newLimit)
        external
        onlyOwner
        nonReentrant
        returns (bytes32 changeId)
    {
        return _queueLimitIncrease(kind, newLimit);
    }

    function _queueLimitIncrease(LimitKind kind, uint256 newLimit) private returns (bytes32 changeId) {
        if (kind == LimitKind.TotalBudget) _requireOpenPO(PO_ID);
        if (newLimit <= _limit(kind)) revert InvalidLimitChange();
        if (pendingLimitChange[kind] != bytes32(0)) revert ChangeAlreadyPending();
        changeNonce += 1;
        changeId = keccak256(abi.encode(address(this), block.chainid, changeNonce, "limit", kind, newLimit));
        uint256 executeAfter = block.timestamp + DELAY;
        limitChanges[changeId] = LimitChange(kind, newLimit, executeAfter, ChangeStatus.Pending);
        pendingLimitChange[kind] = changeId;
        emit LimitChangeQueued(changeId, kind, newLimit, executeAfter);
        if (kind == LimitKind.TotalBudget) emit POBudgetChangeQueued(changeId, PO_ID, newLimit, executeAfter);
    }

    function _limit(LimitKind kind) private view returns (uint256) {
        return kind == LimitKind.TotalBudget ? totalBudget : dailyLimit;
    }

    function _setLimit(LimitKind kind, uint256 newLimit) private {
        uint256 oldLimit = _limit(kind);
        if (kind == LimitKind.TotalBudget) {
            _requireOpenPO(PO_ID);
            totalBudget = newLimit;
            remainingBudget = newLimit - totalSpent;
            purchaseOrders[PO_ID].cap = newLimit;
            emit POBudgetChanged(PO_ID, oldLimit, newLimit);
        } else {
            dailyLimit = newLimit;
        }
        emit LimitChanged(kind, oldLimit, newLimit);
    }

    function _executeLimit(bytes32 changeId) private {
        LimitChange storage change = limitChanges[changeId];
        if (change.status != ChangeStatus.Pending) revert ChangeNotPending();
        if (block.timestamp < change.executeAfter) revert TimelockNotReady();
        change.status = ChangeStatus.Executed;
        pendingLimitChange[change.kind] = bytes32(0);
        _setLimit(change.kind, change.newLimit);
        emit LimitChangeExecuted(changeId);
        if (change.kind == LimitKind.TotalBudget) emit POBudgetChangeExecuted(changeId, PO_ID);
    }

    function _cancelLimit(bytes32 changeId) private {
        LimitChange storage change = limitChanges[changeId];
        if (change.status != ChangeStatus.Pending) revert ChangeNotPending();
        change.status = ChangeStatus.Cancelled;
        pendingLimitChange[change.kind] = bytes32(0);
        emit LimitChangeCancelled(changeId);
        if (change.kind == LimitKind.TotalBudget) emit POBudgetChangeCancelled(changeId, PO_ID);
    }

    /// @notice PO-101 shares the legacy pending record; no second approval can bypass it.
    function pendingPOBudgetChange(uint256 poId) public view returns (bytes32) {
        return poId == PO_ID ? pendingLimitChange[LimitKind.TotalBudget] : pendingOtherPOBudgetChange[poId];
    }

    function _requireOpenPO(uint256 poId) private view {
        PurchaseOrder storage po = purchaseOrders[poId];
        if (!po.exists || po.closed) revert InvalidPO();
    }

    /// @notice Lower immediately, retaining historical spending and cancelling this PO's pending raise.
    function decreasePOBudget(uint256 poId, uint256 newCap) external onlyOwner nonReentrant {
        if (poId == PO_ID) {
            _decreaseLimit(LimitKind.TotalBudget, newCap);
            return;
        }
        _requireOpenPO(poId);
        PurchaseOrder storage po = purchaseOrders[poId];
        uint256 spent = _period(po) == po.period ? po.spent : 0;
        if (newCap >= po.cap || newCap < spent) revert InvalidLimitChange();
        bytes32 pending = pendingPOBudgetChange(poId);
        if (pending != bytes32(0)) _cancelPOBudget(pending);
        _setPOBudget(poId, newCap);
    }

    function queuePOBudgetIncrease(uint256 poId, uint256 newCap)
        external
        onlyOwner
        nonReentrant
        returns (bytes32 changeId)
    {
        if (poId == PO_ID) return _queueLimitIncrease(LimitKind.TotalBudget, newCap);
        _requireOpenPO(poId);
        if (newCap <= purchaseOrders[poId].cap) revert InvalidLimitChange();
        if (pendingPOBudgetChange(poId) != bytes32(0)) revert ChangeAlreadyPending();
        changeId = keccak256(abi.encode(address(this), block.chainid, ++changeNonce, "po-budget", poId, newCap));
        uint256 eta = block.timestamp + DELAY;
        poBudgetChanges[changeId] = POBudgetChange(poId, newCap, eta, ChangeStatus.Pending);
        pendingOtherPOBudgetChange[poId] = changeId;
        emit POBudgetChangeQueued(changeId, poId, newCap, eta);
    }

    function _setPOBudget(uint256 poId, uint256 newCap) private {
        uint256 oldCap = purchaseOrders[poId].cap;
        purchaseOrders[poId].cap = newCap;
        emit POBudgetChanged(poId, oldCap, newCap);
    }

    function _executePOBudget(bytes32 changeId) private {
        POBudgetChange storage change = poBudgetChanges[changeId];
        if (change.status != ChangeStatus.Pending) revert ChangeNotPending();
        if (block.timestamp < change.executeAfter) revert TimelockNotReady();
        _requireOpenPO(change.poId);
        change.status = ChangeStatus.Executed;
        pendingOtherPOBudgetChange[change.poId] = bytes32(0);
        _setPOBudget(change.poId, change.newCap);
        emit POBudgetChangeExecuted(changeId, change.poId);
    }

    function _cancelPOBudget(bytes32 changeId) private {
        POBudgetChange storage change = poBudgetChanges[changeId];
        if (change.status != ChangeStatus.Pending) revert ChangeNotPending();
        change.status = ChangeStatus.Cancelled;
        pendingOtherPOBudgetChange[change.poId] = bytes32(0);
        emit POBudgetChangeCancelled(changeId, change.poId);
    }

    // 可补充本地测试资金。充值只增加余额，不增加付款额度。
    receive() external payable {}

    modifier onlyAgent() {
        if (!authorizedAgents[msg.sender]) revert UnauthorizedAgent();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert UnauthorizedOwner();
        _;
    }

    modifier nonReentrant() {
        if (entered) revert ReentrantCall();
        entered = true;
        _;
        entered = false;
    }

    /// @notice 管理员可以立即暂停付款；管理和取消变更仍可进行。
    function pause() external onlyOwner nonReentrant {
        if (paused) revert AlreadyPaused();
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice 管理员申请恢复付款；等待期间仍保持暂停。
    function queueResume() external onlyOwner nonReentrant returns (bytes32 changeId) {
        if (!paused) revert NotPaused();
        if (pendingResumeChange != bytes32(0)) revert ChangeAlreadyPending();

        changeNonce += 1;
        changeId = keccak256(abi.encode(address(this), block.chainid, changeNonce, "resume"));
        uint256 executeAfter = block.timestamp + DELAY;
        resumeChanges[changeId] = ResumeChange(executeAfter, ChangeStatus.Pending);
        pendingResumeChange = changeId;
        emit ResumeQueued(changeId, executeAfter);
    }

    /// @notice 管理员提交新地址；此时 payout 仍然保留原地址。
    function queuePayoutChange(uint256 vendorId, address newPayout)
        external
        onlyOwner
        nonReentrant
        returns (bytes32 changeId)
    {
        Vendor storage vendor = vendors[vendorId];
        if (!vendor.exists || !vendor.active || newPayout == address(0) || newPayout == vendor.payout) {
            revert InvalidPayoutChange();
        }
        if (pendingVendorPayoutChange[vendorId] != bytes32(0)) revert ChangeAlreadyPending();

        // 每次提交使用不同编号；取消后重新提交，必须重新等待完整的 120 秒。
        changeNonce += 1;
        changeId = keccak256(abi.encode(address(this), block.chainid, changeNonce, vendorId, newPayout));
        uint256 executeAfter = block.timestamp + DELAY;
        payoutChanges[changeId] = PayoutChange(payable(newPayout), executeAfter, ChangeStatus.Pending);
        payoutChangeVendor[changeId] = vendorId;
        pendingVendorPayoutChange[vendorId] = changeId;
        if (vendorId == VENDOR_ID) pendingPayoutChange = changeId;
        emit PayoutChangeQueued(changeId, vendorId, vendor.payout, newPayout, executeAfter);
    }

    /// @notice 谁都能执行管理员已排队且到期的确定变更，包括 Agent 授权。
    function execute(bytes32 changeId) external nonReentrant {
        PayoutChange storage change = payoutChanges[changeId];
        if (change.status != ChangeStatus.Pending) {
            if (resumeChanges[changeId].status == ChangeStatus.Pending) _executeResume(changeId);
            else if (limitChanges[changeId].status == ChangeStatus.Pending) _executeLimit(changeId);
            else if (agentAuthorizations[changeId].status == ChangeStatus.Pending) _executeAgentAuthorization(changeId);
            else if (vendorChanges[changeId].status == ChangeStatus.Pending) _executeVendor(changeId);
            else if (poChanges[changeId].status == ChangeStatus.Pending) _executePO(changeId);
            else if (poBudgetChanges[changeId].status == ChangeStatus.Pending) _executePOBudget(changeId);
            else _executeWithdrawal(changeId);
            return;
        }
        if (block.timestamp < change.executeAfter) revert TimelockNotReady();

        uint256 vendorId = payoutChangeVendor[changeId];
        Vendor storage vendor = vendors[vendorId];
        if (!vendor.active) revert InvalidVendor();
        address oldPayout = vendor.payout;
        change.status = ChangeStatus.Executed;
        pendingVendorPayoutChange[vendorId] = bytes32(0);
        vendor.payout = change.newPayout;
        if (vendorId == VENDOR_ID) {
            pendingPayoutChange = bytes32(0);
            payout = change.newPayout;
        }
        emit PayoutChangeExecuted(changeId, oldPayout, vendor.payout);
    }

    /// @notice 管理员取消尚未执行的变更；保留记录，防止它以后被执行。
    function cancel(bytes32 changeId) external onlyOwner nonReentrant {
        PayoutChange storage change = payoutChanges[changeId];
        if (change.status != ChangeStatus.Pending) {
            if (resumeChanges[changeId].status == ChangeStatus.Pending) _cancelResume(changeId);
            else if (limitChanges[changeId].status == ChangeStatus.Pending) _cancelLimit(changeId);
            else if (agentAuthorizations[changeId].status == ChangeStatus.Pending) _cancelAgentAuthorization(changeId);
            else if (vendorChanges[changeId].status == ChangeStatus.Pending) _cancelVendor(changeId);
            else if (poChanges[changeId].status == ChangeStatus.Pending) _cancelPO(changeId);
            else if (poBudgetChanges[changeId].status == ChangeStatus.Pending) _cancelPOBudget(changeId);
            else _cancelWithdrawal(changeId);
            return;
        }

        _cancelPayout(changeId);
    }

    function _executeResume(bytes32 changeId) private {
        ResumeChange storage change = resumeChanges[changeId];
        if (change.status != ChangeStatus.Pending) revert ChangeNotPending();
        if (block.timestamp < change.executeAfter) revert TimelockNotReady();
        if (!paused) revert NotPaused();

        change.status = ChangeStatus.Executed;
        pendingResumeChange = bytes32(0);
        paused = false;
        emit ResumeExecuted(changeId);
    }

    function _cancelResume(bytes32 changeId) private {
        ResumeChange storage change = resumeChanges[changeId];
        if (change.status != ChangeStatus.Pending) revert ChangeNotPending();

        change.status = ChangeStatus.Cancelled;
        pendingResumeChange = bytes32(0);
        emit ResumeCancelled(changeId);
    }

    function vendorCount() external view returns (uint256) {
        return vendorIds.length;
    }

    function poCount() external view returns (uint256) {
        return poIds.length;
    }

    function queueAddVendor(uint256 vendorId, address newPayout)
        external
        onlyOwner
        nonReentrant
        returns (bytes32 changeId)
    {
        if (vendorId == 0 || newPayout == address(0)) revert InvalidVendor();
        if (vendors[vendorId].exists) revert VendorAlreadyExists();
        if (pendingVendorChange[vendorId] != bytes32(0)) revert ChangeAlreadyPending();
        changeId = keccak256(abi.encode(address(this), block.chainid, ++changeNonce, "vendor", vendorId, newPayout));
        uint256 eta = block.timestamp + DELAY;
        vendorChanges[changeId] = VendorChange(vendorId, payable(newPayout), eta, ChangeStatus.Pending);
        pendingVendorChange[vendorId] = changeId;
        emit VendorQueued(changeId, vendorId, newPayout, eta);
    }

    function _executeVendor(bytes32 changeId) private {
        VendorChange storage change = vendorChanges[changeId];
        if (block.timestamp < change.executeAfter) revert TimelockNotReady();
        if (vendors[change.vendorId].exists) revert VendorAlreadyExists();
        change.status = ChangeStatus.Executed;
        pendingVendorChange[change.vendorId] = bytes32(0);
        vendors[change.vendorId] = Vendor(change.payout, true, true);
        if (change.vendorId == VENDOR_ID) payout = change.payout;
        vendorIds.push(change.vendorId);
        emit VendorAdded(changeId, change.vendorId, change.payout);
    }

    function _cancelVendor(bytes32 changeId) private {
        VendorChange storage change = vendorChanges[changeId];
        change.status = ChangeStatus.Cancelled;
        pendingVendorChange[change.vendorId] = bytes32(0);
        emit VendorChangeCancelled(changeId, change.vendorId);
    }

    function _cancelPayout(bytes32 changeId) private {
        PayoutChange storage change = payoutChanges[changeId];
        change.status = ChangeStatus.Cancelled;
        uint256 vendorId = payoutChangeVendor[changeId];
        pendingVendorPayoutChange[vendorId] = bytes32(0);
        if (vendorId == VENDOR_ID) pendingPayoutChange = bytes32(0);
        emit PayoutChangeCancelled(changeId);
    }

    // IDs are never reused. Deactivation cannot be undone by re-registering the same ID.
    function deactivateVendor(uint256 vendorId) external onlyOwner nonReentrant {
        Vendor storage vendor = vendors[vendorId];
        if (!vendor.exists || !vendor.active) revert InvalidVendor();
        vendor.active = false;
        bytes32 pending = pendingVendorPayoutChange[vendorId];
        if (pending != bytes32(0)) _cancelPayout(pending);
        emit VendorDeactivated(vendorId);
    }

    function queueAddPO(uint256 poId, uint256 vendorId, uint256 cap, uint64 expiry, uint32 periodDays)
        external
        onlyOwner
        nonReentrant
        returns (bytes32 changeId)
    {
        if (poId == 0 || cap == 0 || expiry <= block.timestamp + DELAY) revert InvalidPO();
        if (!vendors[vendorId].exists || !vendors[vendorId].active) revert InvalidVendor();
        if (purchaseOrders[poId].exists) revert POAlreadyExists();
        // PO-101 retains the legacy lifetime-budget accounting; recurring POs use other IDs.
        if (poId == PO_ID && periodDays != 0) revert InvalidPO();
        if (pendingPOChange[poId] != bytes32(0)) revert ChangeAlreadyPending();
        changeId = keccak256(
            abi.encode(address(this), block.chainid, ++changeNonce, "po", poId, vendorId, cap, expiry, periodDays)
        );
        uint256 eta = block.timestamp + DELAY;
        poChanges[changeId] = POChange(poId, vendorId, cap, expiry, periodDays, eta, ChangeStatus.Pending);
        pendingPOChange[poId] = changeId;
        emit POQueued(changeId, poId, vendorId, cap, expiry, periodDays, eta);
    }

    function _executePO(bytes32 changeId) private {
        POChange storage change = poChanges[changeId];
        if (block.timestamp < change.executeAfter) revert TimelockNotReady();
        if (!vendors[change.vendorId].active) revert InvalidVendor();
        if (block.timestamp >= change.expiry) revert InvalidPO();
        if (purchaseOrders[change.poId].exists) revert POAlreadyExists();
        change.status = ChangeStatus.Executed;
        pendingPOChange[change.poId] = bytes32(0);
        purchaseOrders[change.poId] = PurchaseOrder(
            change.vendorId, change.cap, 0, 0, change.expiry, change.periodDays, uint64(block.timestamp), 0, false, true
        );
        poIds.push(change.poId);
        if (change.poId == PO_ID) {
            totalBudget = change.cap;
            remainingBudget = change.cap;
            poExpiry = change.expiry;
        }
        emit POAdded(changeId, change.poId, change.vendorId);
    }

    function _cancelPO(bytes32 changeId) private {
        POChange storage change = poChanges[changeId];
        change.status = ChangeStatus.Cancelled;
        pendingPOChange[change.poId] = bytes32(0);
        emit POChangeCancelled(changeId, change.poId);
    }

    function closePO(uint256 poId) external onlyOwner nonReentrant {
        PurchaseOrder storage po = purchaseOrders[poId];
        if (!po.exists || po.closed) revert InvalidPO();
        po.closed = true;
        bytes32 pending = pendingPOBudgetChange(poId);
        if (pending != bytes32(0)) {
            if (poId == PO_ID) _cancelLimit(pending);
            else _cancelPOBudget(pending);
        }
        emit POClosed(poId);
    }

    function _period(PurchaseOrder storage po) private view returns (uint256) {
        return po.periodDays == 0 ? 0 : (block.timestamp - po.startedAt) / (uint256(po.periodDays) * 1 days);
    }

    // Periods start at execution. Unused allowance expires; it never accumulates across periods.
    function poRemaining(uint256 poId) public view returns (uint256) {
        PurchaseOrder storage po = purchaseOrders[poId];
        if (!po.exists || po.closed || block.timestamp >= po.expiry) return 0;
        uint256 spent = _period(po) == po.period ? po.spent : 0;
        return spent >= po.cap ? 0 : po.cap - spent;
    }

    function queueWithdraw(uint256 amount) external onlyOwner nonReentrant returns (bytes32 changeId) {
        if (amount == 0 || amount > address(this).balance) revert InvalidWithdrawal();
        if (pendingWithdrawal != bytes32(0)) revert ChangeAlreadyPending();
        changeId = keccak256(abi.encode(address(this), block.chainid, ++changeNonce, "withdraw", amount));
        uint256 eta = block.timestamp + DELAY;
        withdrawalChanges[changeId] = WithdrawalChange(amount, eta, ChangeStatus.Pending);
        pendingWithdrawal = changeId;
        emit WithdrawalQueued(changeId, amount, eta);
    }

    function _executeWithdrawal(bytes32 changeId) private {
        WithdrawalChange storage change = withdrawalChanges[changeId];
        if (change.status != ChangeStatus.Pending) revert ChangeNotPending();
        if (block.timestamp < change.executeAfter) revert TimelockNotReady();
        if (change.amount > address(this).balance) revert InvalidWithdrawal();
        change.status = ChangeStatus.Executed;
        pendingWithdrawal = bytes32(0);
        (bool success,) = payable(owner).call{value: change.amount}("");
        if (!success) revert TransferFailed();
        emit WithdrawalExecuted(changeId, owner, change.amount);
    }

    function _cancelWithdrawal(bytes32 changeId) private {
        WithdrawalChange storage change = withdrawalChanges[changeId];
        if (change.status != ChangeStatus.Pending) revert ChangeNotPending();
        change.status = ChangeStatus.Cancelled;
        pendingWithdrawal = bytes32(0);
        emit WithdrawalCancelled(changeId);
    }

    /// @notice 返回 true 表示已付款；false 表示拒付且已记录 Blocked。
    /// @dev invoiceHash 是调用者提供的标识，不能证明账单真实。
    function pay(uint256 vendorId, address payTo, uint256 poId, uint256 amount, bytes32 invoiceHash)
        external
        onlyAgent
        nonReentrant
        returns (bool paid)
    {
        // 第二步：拿本次请求与合约里保存的规则比较。
        BlockReason reason = _check(vendorId, payTo, poId, amount, invoiceHash);
        if (reason != BlockReason.None) {
            emit Blocked(uint8(reason), vendorId, payTo, poId, amount, invoiceHash, msg.sender);
            return false;
        }

        // 第三步：先更新账目，再进行外部转账，防止付款流程被重复进入。
        PurchaseOrder storage po = purchaseOrders[poId];
        uint256 period = _period(po);
        if (period != po.period) {
            po.period = period;
            po.spent = 0;
        }
        po.spent += amount;
        po.totalPaid += amount;
        totalPaid += amount;
        if (poId == PO_ID) {
            remainingBudget -= amount;
            totalSpent += amount;
        }
        spentByDay[block.timestamp / 1 days] += amount;
        paidInvoices[invoiceHash] = true;

        // Always transfer to the registered address for this vendor.
        address payable registeredPayout = vendors[vendorId].payout;
        (bool success,) = registeredPayout.call{value: amount}("");
        if (!success) revert TransferFailed(); // 转账失败时，前面的账目修改也一起回滚。

        // 第四步：留下供后端和页面读取的付款记录。
        emit Paid(vendorId, poId, registeredPayout, amount, invoiceHash, msg.sender);
        return true;
    }

    function _check(uint256 vendorId, address payTo, uint256 poId, uint256 amount, bytes32 invoiceHash)
        private
        view
        returns (BlockReason)
    {
        if (paused) return BlockReason.Paused;
        Vendor storage vendor = vendors[vendorId];
        if (!vendor.exists) return BlockReason.UnknownVendor;
        if (!vendor.active) return BlockReason.VendorInactive;
        if (payTo != vendor.payout) return BlockReason.PayoutMismatch;
        PurchaseOrder storage po = purchaseOrders[poId];
        if (!po.exists) return BlockReason.UnknownPO;
        if (po.vendorId != vendorId) return BlockReason.POVendorMismatch;
        if (po.closed) return BlockReason.POClosed;
        if (block.timestamp >= po.expiry) return BlockReason.POExpired;
        if (amount == 0) return BlockReason.InvalidAmount;
        if (amount > poRemaining(poId)) return BlockReason.OverBudget;
        if (paidInvoices[invoiceHash]) return BlockReason.DuplicateInvoice;
        if (amount > address(this).balance) return BlockReason.InsufficientFunds;
        uint256 spent = spentToday();
        // 上限可降至已付金额以下；先比较，避免减法下溢。
        if (spent >= dailyLimit || amount > dailyLimit - spent) return BlockReason.DailyLimitExceeded;
        return BlockReason.None;
    }
}
