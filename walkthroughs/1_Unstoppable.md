## Challenge 1: Unstoppable

### Vulnerability
The `UnstoppableVault` contract has a logic flaw in the `flashLoan` function where it checks `totalAssets() != totalSupply + amount` which can be broken by directly transferring tokens to the vault.

### Exploit Code
```solidity
// In Unstoppable.t.sol - test_unstoppable() function
function test_unstoppable() public checkSolvedByPlayer {
    // Transfer tokens directly to vault to break the totalAssets calculation
    token.transfer(address(vault), 1);
}
```

### Why it works
- The vault checks if `totalAssets() == totalSupply + amount`
- `totalAssets()` returns `token.balanceOf(address(this))`
- Direct token transfer increases balance but doesn't mint shares
- This breaks the invariant and prevents future flash loans

### Fix
```solidity
// Remove the faulty check or use proper accounting
// Instead of: if (totalAssets() != totalSupply + amount) revert InvalidBalance();
// Use internal accounting that tracks actual deposited amounts
```
