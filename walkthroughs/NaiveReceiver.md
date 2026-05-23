## Challenge 2 Walkthrough: Naive Receiver

### Vulnerability

The `NaiveReceiverPool` has **two critical vulnerabilities** that combine into a single complete drain.

#### Primary: Unauthorized Flash Loans

```solidity
function flashLoan(address receiver, address token, uint256 amount, bytes calldata data)
    external returns (bool)
```

- No authorization check — **any caller** can initiate flash loans on behalf of any receiver
- Fixed 1 WETH fee charged regardless of loan amount, even `amount = 0`
- `FlashLoanReceiver.onFlashLoan()` pays fees unconditionally without validating the initiator

#### Secondary: `_msgSender()` Calldata Spoofing

```solidity
function _msgSender() internal view override returns (address) {
    if (msg.sender == trustedForwarder && msg.data.length >= 20) {
        return address(bytes20(msg.data[msg.data.length - 20:]));
    } else {
        return super._msgSender();
    }
}
```

When called through the trusted `BasicForwarder`, `_msgSender()` returns the **last 20 bytes of calldata** as the sender — with no validation that this address is legitimate or authorized. Any caller can append any address to calldata and impersonate it, including the `deployer` who holds sufficient deposits to withdraw all pool funds.

#### Combined Attack Vector

These two vulnerabilities chain together:
1. Drain the receiver via 10 × zero-amount flash loans (10 × 1 WETH fee = 10 WETH)
2. Drain the pool by spoofing `_msgSender()` as `deployer` to call `withdraw(1010 WETH, recovery)`
3. Both steps batched into **one transaction** via `multicall`, satisfying the `nonce ≤ 2` constraint

### Exploit

The solution runs in a single meta-transaction — `forwarder.execute()` counts as one player transaction, satisfying the nonce requirement. The 7-part structure is fully documented inside `test_naiveReceiver()` in the test file. The high-level sequence:

```
[Player signs request]
       │
       └─> forwarder.execute(request, signature)
                 │
                 └─> pool.multicall(callDatas)
                           ├─ flashLoan(receiver, weth, 0, "") × 10
                           │    └─> receiver.onFlashLoan() → pays 1 WETH fee each
                           └─> withdraw(1010e18, recovery)
                                    └─> _msgSender() reads last 20 bytes
                                        → returns deployer → access granted
                                        → 1010 WETH sent to recovery
```

**Part 1 — Drain receiver (10 flash loans):**
```solidity
for (uint i = 0; i < 10; i++) {
    callDatas[i] = abi.encodeCall(pool.flashLoan, (receiver, address(weth), 0, ""));
}
```
Zero tokens borrowed, but each loan charges the receiver 1 WETH. 10 calls = receiver fully drained.

**Part 2 — Spoof deployer identity on withdrawal:**
```solidity
callDatas[10] = abi.encodePacked(
    abi.encodeCall(pool.withdraw, (WETH_IN_POOL + WETH_IN_RECEIVER, payable(recovery))),
    bytes32(uint256(uint160(deployer))) // appended: _msgSender() reads this as the caller
);
```
The deployer address appended to the end of the calldata causes `_msgSender()` to return `deployer`, bypassing `withdraw()`'s access control.

**Parts 3–7 — Wrap and sign as a meta-transaction:**

The 11 encoded calls are bundled into `multicall`, wrapped in a `BasicForwarder.Request` struct, hashed via EIP-712, signed with `playerPk`, and executed via `forwarder.execute()`. The forwarder verifies the signature, forwards the call to the pool, and the pool processes all 11 operations atomically as a single transaction.

### Why It Works

| Mechanism | Consequence |
|-----------|-------------|
| `flashLoan` has no initiator check | Anyone can drain `FlashLoanReceiver` via repeated fee charges |
| Fee charged even on 0-amount loans | 10 zero-cost calls = full 10 WETH drain |
| `_msgSender()` trusts calldata tail | Appending any address impersonates it as the caller |
| `multicall` batches all 11 ops | One external transaction — player nonce increases by 1 only |
| `BasicForwarder` relays the call | Pool sees forwarder as `msg.sender`, reads spoofed deployer from calldata |

### 🎯 Result: All `_isSolved()` Checks Pass

| Check | Passed Because |
|-------|----------------|
| `vm.getNonce(player) ≤ 2` | Only **1 transaction** used (`forwarder.execute`) |
| `weth.balanceOf(receiver) == 0` | 10 flash loans × 1 WETH fee = **10 WETH drained** |
| `weth.balanceOf(pool) == 0` | `withdraw(1010 WETH, recovery)` removes all funds |
| `weth.balanceOf(recovery) == 1010e18` | Full amount transferred in single multicall |

This is an **unauthorized flash loan + meta-transaction caller spoofing** attack — two separate access control failures chained into a complete drain in one transaction.
