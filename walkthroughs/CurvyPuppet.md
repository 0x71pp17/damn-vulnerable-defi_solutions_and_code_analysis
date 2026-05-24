## Challenge 17 Walkthrough: Curvy Puppet

### Vulnerability

The vulnerability is a **read-only reentrancy on Curve's stETH/ETH pool**. The lending contract prices LP tokens using `get_virtual_price()`:

```solidity
function _getLPTokenPrice() private view returns (uint256) {
    return oracle.getPrice(curvePool.coins(0)).value.mulWadDown(curvePool.get_virtual_price());
    //                     ↑ ETH price from oracle            ↑ Curve's virtual price
}
```

`get_virtual_price()` reflects the value of the Curve pool's invariant divided by total LP supply. During a `remove_liquidity()` call, Curve sends ETH to the caller **before** updating its internal balances. At this exact moment `get_virtual_price()` returns a stale value — still reflecting the pre-removal state with more ETH in the pool than actually exists.

```
remove_liquidity() execution:
  Step 1: Curve sends ETH to caller  ← get_virtual_price() is stale here
  Step 2: Curve updates balances     ← get_virtual_price() is correct here
```

Any protocol that calls `get_virtual_price()` from within a `receive()` or fallback triggered by step 1 reads an inflated LP price. The lending contract does exactly this — and an inflated LP price means `getBorrowValue()` returns a larger number than the real debt, making healthy positions appear to exceed the liquidation threshold:

```solidity
// liquidate() in CurvyPuppetLending:
uint256 collateralValue = getCollateralValue(collateralAmount) * 100;
uint256 borrowValue     = getBorrowValue(borrowAmount) * 175;
//                        ↑ uses _getLPTokenPrice() → inflated during reentrancy window
if (collateralValue >= borrowValue) revert HealthyPosition(...);
// With inflated LP price: borrowValue spikes → condition flips → liquidation proceeds
```

Alice, Bob, and Charlie each deposited 2,500 DVT collateral and borrowed 1 LP token. They are heavily overcollateralized under normal prices (`collateralValue / borrowValue > 3`). During the reentrancy window their positions flip to liquidatable.

### Exploit

The player has access to treasury-approved funds: 200 WETH and 6.5 LP tokens. The LP tokens are used to repay the debt during liquidation; the WETH is used to enter and exit Curve to create the reentrancy window.

**Full attack flow:**

```
1. transferFrom treasury → player: 200 WETH + 6.5 LP tokens
2. Unwrap WETH → ETH
3. Add ETH to Curve stETH/ETH pool → receive LP tokens
4. Call remove_liquidity() on Curve
      │
      ├─ Curve sends ETH to player.receive()   ← REENTRANCY WINDOW OPENS
      │       │
      │       ├─ get_virtual_price() is stale/inflated
      │       ├─ liquidate(alice)  → repay 1 LP, seize 2500 DVT
      │       ├─ liquidate(bob)    → repay 1 LP, seize 2500 DVT
      │       └─ liquidate(charlie)→ repay 1 LP, seize 2500 DVT
      │
      └─ Curve updates balances    ← window closes
5. Wrap remaining ETH → WETH
6. Transfer 7500 DVT + remaining WETH + remaining LP → treasury
```

The Permit2 approvals for LP tokens (needed by `lending.liquidate()` which calls `_pullAssets`) must be set before entering the reentrancy window since they can't be set inside `receive()`.

**Key setUp details that shape the solution:**

- `setUp()` forks mainnet at block `20190356` using `MAINNET_FORKING_URL`
- Treasury approves the player for both WETH and LP tokens in setUp — player must `transferFrom` to access them
- Each user position: `2500e18` DVT collateral, `1e18` LP borrow
- `_isSolved()` requires treasury receives exactly `USER_INITIAL_COLLATERAL_BALANCE * 3` = 7500 DVT, treasury still holds WETH and LP tokens, player holds nothing

### Why It Works

Read-only reentrancy is particularly subtle because no state is written during the reentrant call — the attacker only reads a value. Standard reentrancy guards on `liquidate()` don't prevent it because the guard only protects against reentrant writes to the same contract. The exploit reads `get_virtual_price()` from an external contract (Curve) that is mid-execution with inconsistent state.

The fix is to check the Curve pool's lock status before reading `get_virtual_price()` — Curve pools expose a `is_killed` or reentrancy lock that indicates when the pool is mid-execution. Alternatively, the lending contract can use a Chainlink oracle for LP pricing instead of reading from the pool directly.

This vulnerability class affected multiple real DeFi protocols in 2022–2023, including exploits on Mango Markets and various Curve LP oracle integrations. It was formally documented by ChainSecurity in their analysis of read-only reentrancy risks in Curve-integrated protocols.

> **Note:** This challenge requires `MAINNET_FORKING_URL` set in `.env`. The setup forks mainnet at block 20,190,356 to use the live Curve stETH/ETH pool at `0xDC24316b9AE028F1497c275EB9192a3Ea0f67022`.

This is a **read-only reentrancy on Curve `get_virtual_price()`** — no flash loan needed, treasury funds provide the entry capital, three positions liquidated in a single reentrancy window.
