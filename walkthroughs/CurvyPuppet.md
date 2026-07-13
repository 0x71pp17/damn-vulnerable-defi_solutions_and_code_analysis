## Challenge 17 Walkthrough: Curvy Puppet

### Vulnerability

The vulnerability is a **read-only reentrancy on Curve's stETH/ETH pool**. The lending contract prices borrowed LP tokens using Curve's `get_virtual_price()`:

```solidity
function _getLPTokenPrice() private view returns (uint256) {
    return oracle.getPrice(curvePool.coins(0)).value.mulWadDown(curvePool.get_virtual_price());
    //                     ↑ ETH price from oracle            ↑ Curve's virtual price
}
```

`get_virtual_price()` returns the pool invariant `D` divided by the LP token's `totalSupply`. During a `remove_liquidity()` call the Curve pool **burns the LP supply first**, then sends the underlying assets back to the caller. For the stETH/ETH pool the ETH leg is a native transfer, which triggers the caller's `receive()` — and at that instant the pool is in a transient, inconsistent state: `totalSupply` has already been reduced, but the pool's balances (and therefore `D`) have **not** yet been decremented for the assets still in flight.

```
remove_liquidity() execution:
  Step 1: burn LP  → totalSupply drops         ← D not yet updated
  Step 2: send ETH → receive() fires here      ← get_virtual_price() = D / (reduced supply) → INFLATED
  Step 3: balances finally settle              ← get_virtual_price() correct again
```

Any protocol reading `get_virtual_price()` inside that `receive()` window reads an inflated LP price. The lending contract does exactly this whenever `liquidate()` is called, and an inflated LP price makes `getBorrowValue()` (which is denominated in LP tokens) balloon, flipping healthy positions past the liquidation threshold:

```solidity
// liquidate() in CurvyPuppetLending:
uint256 collateralValue = getCollateralValue(collateralAmount) * 100;
uint256 borrowValue     = getBorrowValue(borrowAmount) * 175;   // ← uses _getLPTokenPrice() → inflated in the window
if (collateralValue >= borrowValue) revert HealthyPosition(borrowValue, collateralValue);
```

Alice, Bob, and Charlie each deposited `2,500e18` DVT as collateral and borrowed `1e18` LP. Under normal prices they are heavily overcollateralized. During the reentrancy window their positions flip to liquidatable.

**The exact liquidation threshold.** Plugging the constants in:

- `collateralValue = 2500e18 × DVT_price(10e18) × 100 = 2.5e24`
- `borrowValue = 1e18 × [ETH_price(4000e18) × get_virtual_price()] × 175`

For a position to become liquidatable we need `borrowValue > collateralValue`:

```
4000 × vp × 175 > 2,500,000e18   →   vp > 3.5714e18
```

At the forked block the pool's real virtual price is only **~1.097e18**. **The entire difficulty of the challenge is pushing `get_virtual_price()` from ~1.10 past 3.57 — more than tripling it — inside the reentrancy window.**

### Exploit

The naive read-only-reentrancy approach (dump the treasury's 200 WETH into the pool, then `remove_liquidity`) **does not work here** — 200 WETH against a pool holding ~34,500 ETH + ~35,500 stETH barely moves the virtual price (it rises to ~1.10). The 200 WETH is really only enough to cover the round-trip fee. To triple `get_virtual_price()` you need to imbalance the pool with **hundreds of thousands** of tokens, which means flash loans — and, critically, an **imbalanced** deposit dominated by stETH.

**Capital sourcing (measured at block 20,190,356):**

| Source | Asset | Amount used | Available |
|--------|-------|-------------|-----------|
| Balancer Vault | WETH | 37,000 | ~37,991 (0% fee) |
| Aave V2 | stETH | 170,000 | ~173,429 |
| Aave V3 | WETH | 60,000 | ~83,000 |

The three flash loans are **nested**: Balancer's callback opens Aave V2, whose callback opens Aave V3, whose callback runs the manipulation. Each unwinds and repays as the stack returns.

**Full attack flow:**

```
0. Player transferFrom treasury → attacker: 200 WETH + 6.5 LP
   (treasury approved the PLAYER, not the attacker — so the player does the transferFrom)

1. Balancer.flashLoan(37,000 WETH)
     └─ 2. AaveV2.flashLoan(170,000 stETH)
              └─ 3. AaveV3.flashLoanSimple(60,000 WETH)
                       └─ _manipulate():
                          a. Unwrap all WETH → ETH (~97k ETH on hand)
                          b. Set Permit2 approval (LP → lending) BEFORE the window
                          c. add_liquidity([~97k ETH, 170k stETH])   ← heavily stETH-imbalanced
                          d. remove_liquidity(most of our LP)
                                │
                                ├─ Curve burns LP, sends ETH → receive() fires
                                │      get_virtual_price() ≈ 3.63e18  (> 3.57 threshold ✓)
                                │      ├─ liquidate(alice)   → repay 1 LP, seize 2500 DVT
                                │      ├─ liquidate(bob)     → repay 1 LP, seize 2500 DVT
                                │      └─ liquidate(charlie) → repay 1 LP, seize 2500 DVT
                                └─ balances settle, window closes
                          e. Re-wrap ETH → WETH; repay Aave V3 (+premium)
                       └─ repay Aave V2 stETH (top up via ETH→stETH swap if short)
     └─ cover any WETH shortfall by swapping leftover stETH → ETH → WETH; repay Balancer

4. Return to treasury: 7,500 seized DVT + leftover WETH + retained LP
```

**The stETH imbalance is the key lever.** A balanced deposit (ETH only, or ETH+stETH in the pool's natural ratio) tops out around `vp ≈ 1.5`. Depositing an stETH-dominant imbalance (asset ratio > ~3.26) is what drives the transient `D`/supply ratio high enough during removal — empirically reaching `vp ≈ 3.63`, comfortably past the `3.5714` threshold.

**Details that shape the solution:**

- **Allowance ownership.** `setUp()` has the treasury approve the **player** for its WETH and LP. The attack contract is a separate address, so the player must perform the `transferFrom` (sending the funds *into* the attacker), rather than the attacker pulling them in its constructor.
- **A re-entrancy guard flag.** `receive()` fires on *any* incoming ETH, including the harmless `WETH.withdraw()` unwrap (which forwards only a 2,300-gas stipend and would revert `OutOfGas` if it tried to liquidate). A `bool liquidating` set only around `remove_liquidity()` gates the liquidation logic so it runs exclusively in the real window.
- **Permit2 before the window.** `liquidate()` → `_pullAssets()` pulls the LP repayment via `permit2.transferFrom`, so the Permit2 approval must be set *before* entering `receive()` — it can't be set mid-reentrancy.
- **Retain LP + cover the shortfall.** The imbalanced add/remove round-trip loses a few hundred WETH to Curve fees, and `_isSolved()` requires the treasury to end with WETH **and** LP. The solution keeps `10e18` LP unremoved (3e18 is consumed repaying the three borrows during liquidation; the rest returns to the treasury) and converts leftover stETH → WETH to top up the Balancer repayment.
- **Success conditions.** `_isSolved()` requires: all three positions closed; treasury ends with WETH > 0, LP > 0, and exactly `7,500` DVT (`USER_INITIAL_COLLATERAL_BALANCE * 3`); and the player holds no DVT, stETH, WETH, or LP.

### Why It Works

Read-only reentrancy is subtle because the reentrant call writes **no state** — the attacker only *reads* `get_virtual_price()`. A standard `nonReentrant` guard on `liquidate()` doesn't help, because the inconsistent state lives in a *different* contract (Curve), which is mid-execution. The lending contract trustingly reads a live pool price at the worst possible moment.

Two things had to line up for the exploit:

1. **The reentrancy window** exists because Curve's stETH/ETH pool sends native ETH (triggering `receive()`) after burning LP supply but before settling balances.
2. **Enough capital, imbalanced enough**, to move `get_virtual_price()` across the `3.5714` liquidation threshold — impossible with the treasury's 200 WETH, achievable with ~267k tokens of flash-loaned liquidity weighted heavily toward stETH.

The fix on the protocol side is to never read `get_virtual_price()` (or any pool spot value) while the pool may be mid-call. Curve pools expose a reentrancy lock; the canonical mitigation is to call the pool's `remove_liquidity(0, [0,0])` (or check the lock) to force-revert if the pool is locked, *before* reading the virtual price. Better still, price LP tokens from an independent oracle (e.g. Chainlink) rather than the pool itself.

This vulnerability class hit multiple real protocols in 2022–2023 — it was formally documented by ChainSecurity ("Heartbreaks & Curve LP Oracles"), whose research also describes the `remove_liquidity_imbalance` amplification and the exact `D`/supply inconsistency this challenge reproduces.

> **Requires** `MAINNET_FORKING_URL` in `.env`. `setUp()` forks mainnet at block **20,190,356** to use the live Curve stETH/ETH pool (`0xDC24316b9AE028F1497c275EB9192a3Ea0f67022`), Balancer Vault, and the Aave V2/V3 pools. Run without `--fork-url` — the test forks internally via `vm.createSelectFork(vm.envString("MAINNET_FORKING_URL"), 20190356)`. An archive-capable RPC (e.g. Alchemy) is needed for historical state at that block.

> **Tuning caveat.** The flash-loan amounts (37k WETH / 170k stETH / 60k WETH), the `500 ether` ETH reserve, and the `10e18` retained LP are **fitted to block 20,190,356's exact pool state**. They pass reliably at that pinned block but are empirically tuned rather than derived in closed form — if the fork block changed, the pool balances would differ and these would need re-tuning.

This is a **read-only reentrancy on Curve `get_virtual_price()`**, amplified by a **triple flash loan (Balancer + Aave V2 + Aave V3)** and a **stETH-imbalanced Curve deposit** to more than triple the virtual price inside a single reentrancy window, liquidating all three positions.
