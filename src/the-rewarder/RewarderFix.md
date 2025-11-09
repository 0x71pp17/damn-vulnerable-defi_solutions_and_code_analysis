To fix the vulnerability in `TheRewarderDistributor`, the `claimRewards` function must **check and update the claimed status for each individual claim before transferring rewards**, not after.

### Root Cause
The current code only calls `_setClaimed` when switching tokens or at the end of the loop, allowing the same claim to be replayed multiple times within one transaction.

### Fix
Move the `_setClaimed` check **inside** the loop and apply it **per claim**, ensuring state is updated before any transfer.

```solidity
function claimRewards(Claim[] memory inputClaims, IERC20[] memory inputTokens) external {
    Claim memory inputClaim;
    IERC20 token;
    uint256 bitsSet;
    uint256 amount;

    for (uint256 i = 0; i < inputClaims.length; i++) {
        inputClaim = inputClaims[i];

        uint256 wordPosition = inputClaim.batchNumber / 256;
        uint256 bitPosition = inputClaim.batchNumber % 256;

        if (token != inputTokens[inputClaim.tokenIndex]) {
            if (address(token) != address(0)) {
                if (!_setClaimed(token, amount, wordPosition, bitsSet)) revert AlreadyClaimed();
            }
            token = inputTokens[inputClaim.tokenIndex];
            bitsSet = 0;
            amount = 0;
        }

        // Set bit and accumulate amount for current claim
        bitsSet |= 1 << bitPosition;
        amount += inputClaim.amount;

        // Verify Merkle proof
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, inputClaim.amount));
        bytes32 root = distributions[token].roots[inputClaim.batchNumber];
        if (!MerkleProof.verify(inputClaim.proof, root, leaf)) revert InvalidProof();

        // ✅ Critical fix: Mark this specific claim as used immediately
        if (!_setClaimed(token, inputClaim.amount, wordPosition, 1 << bitPosition)) {
            revert AlreadyClaimed();
        }

        // Transfer reward
        inputTokens[inputClaim.tokenIndex].transfer(msg.sender, inputClaim.amount);
    }

    // Optional: Final cleanup for last token group (if needed)
    if (address(token) != address(0)) {
        if (!_setClaimed(token, amount, wordPosition, bitsSet)) revert AlreadyClaimed();
    }
}
```

### Why This Works
- Each claim is **individually validated and marked** before transfer.
- Prevents replay of the same claim within a batch.
- Follows the **Check-Effect-Interact** pattern.
