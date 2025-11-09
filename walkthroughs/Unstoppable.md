## Challenge 1 Walkthrough: Unstoppable 

### Vulnerability
The vulnerability lies in the `flashLoan` function's invariant check:

```solidity
uint256 balanceBefore = totalAssets();
if (convertToShares(totalSupply) != balanceBefore) revert InvalidBalance();
```

- `totalSupply` = total shares minted
- `totalAssets()` = actual DVT balance of vault

These must always match due to `convertToShares()` math.

### Exploit
```solidity
function test_unstoppable() public checkSolvedByPlayer {
    token.transfer(address(vault), 1); 
}
```

By sending **1 DVT directly** to the vault:
- `totalAssets()` increases by 1
- `totalSupply` stays unchanged
- `convertToShares(totalSupply)` ≠ `totalAssets()` → invariant broken

Now every `flashLoan` reverts on `InvalidBalance`.

### Why It Works
The `UnstoppableMonitor` calls `checkFlashLoan`, which fails → emits `FlashLoanStatus(false)` → pauses vault and transfers ownership to deployer, solving the challenge.

This is a **Denial of Service** via accounting imbalance.

