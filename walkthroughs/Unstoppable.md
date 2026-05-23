## Challenge 1 Walkthrough: Unstoppable

### Vulnerability

The vulnerability lies in the `flashLoan` function's invariant check:

```solidity
function flashLoan(IERC3156FlashBorrower receiver, address _token, uint256 amount, bytes calldata data)
    external
    returns (bool)
{
    if (amount == 0) revert InvalidAmount(0);
    if (address(asset) != _token) revert UnsupportedCurrency();
    uint256 balanceBefore = totalAssets();
    if (convertToShares(totalSupply) != balanceBefore) revert InvalidBalance(); // ← broken by direct transfer
    ...
}
```

- `totalSupply` — total shares minted via `deposit()`
- `totalAssets()` — actual DVT balance held by the vault (`asset.balanceOf(address(this))`)

Under normal operation these stay in sync: every token entering the vault goes through `deposit()`, which mints proportional shares. A direct ERC-20 transfer bypasses `deposit()` entirely, so the vault's token balance increases without any shares being minted — permanently breaking the invariant.

### Exploit

```solidity
function test_unstoppable() public checkSolvedByPlayer {
    token.transfer(address(vault), 1);
}
```

Sending **1 DVT directly** to the vault:
- `totalAssets()` increases by 1
- `totalSupply` stays unchanged
- `convertToShares(totalSupply) != totalAssets()` → invariant permanently broken

Every subsequent `flashLoan` call reverts on `InvalidBalance`.

### Why It Works

`UnstoppableMonitor.checkFlashLoan()` attempts a flash loan to verify the vault is live. Once the invariant is broken, that call fails, triggering the `catch` block which emits `FlashLoanStatus(false)`, calls `vault.setPause(true)`, then `vault.transferOwnership(owner)` — satisfying the challenge win condition.

The invariant assumes all token inflows go through `deposit()`. There is no way to enforce this on a standard ERC-20: `transfer()` and `transferFrom()` are permissionless by design. A correct implementation would derive `balanceBefore` from share accounting alone, never from raw `balanceOf`.

This is a **Denial of Service via ERC4626 accounting imbalance** — one token transfer, permanent effect, no recovery possible without a contract upgrade.
