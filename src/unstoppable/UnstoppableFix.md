
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


### Fix

To fix the vulnerability in `UnstoppableVault`, the contract must **prevent external manipulation of its accounting invariant**.

### Root Cause
The `flashLoan` function assumes:
```solidity
convertToShares(totalSupply) == totalAssets()
```
But `totalAssets()` returns `asset.balanceOf(address(this))`, which can be increased by direct token transfers, breaking the invariant.

### Fix: Use an Internal Asset Counter
Replace reliance on `balanceOf` with an internal counter:

```solidity
uint256 private _internalAssetCount; // Track assets internally
```

Override `totalAssets()` to use it:
```solidity
function totalAssets() public view override nonReadReentrant returns (uint256) {
    return _internalAssetCount;
}   
```

Sync the counter in `deposit` and `withdraw`:
```solidity
function deposit(uint256 assets, address receiver) public override returns (uint256) {
    uint256 shares = super.deposit(assets, receiver);
    _internalAssetCount += assets;
    return shares;
}

function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
    uint256 shares = super.withdraw(assets, receiver, owner);
    _internalAssetCount -= assets;
    return shares;
}
```

### Why It Works
- `_internalAssetCount` is only modified via protocol-controlled functions.
- Direct token transfers no longer affect accounting.
- The `flashLoan` check remains unchanged but now uses secure state, ensuring the invariant holds and preventing DoS via imbalance.


### Contract Updates

The fix modifies the contract as follows:

1. **Add state variable** at the top (after `feeRecipient`):
```solidity
uint256 private _internalAssetCount;
```

2. **Override `deposit` and `withdraw`** (before `flashLoan`):
```solidity
function deposit(uint256 assets, address receiver) public override returns (uint256) {
    uint256 shares = super.deposit(assets, receiver);
    _internalAssetCount += assets;
    return shares;
}

function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
    uint256 shares = super.withdraw(assets, receiver, owner);
    _internalAssetCount -= assets;
    return shares;
}
```

3. **Update `totalAssets()`** to return `_internalAssetCount`:
```solidity
function totalAssets() public view override nonReadReentrant returns (uint256) {
    return _internalAssetCount;
}
```

These changes ensure accounting integrity by decoupling `totalAssets()` from external token transfers.
