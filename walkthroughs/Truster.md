

The solution works by exploiting the **unrestricted `functionCall`** in the `flashLoan` function, which allows the caller to force the pool to execute **any function on any contract**. Here's why it succeeds:

1. **No Validation on Target or Data**: The `flashLoan` function accepts a `target` address and arbitrary `data`, then executes `target.functionCall(data)` without verifying what function is being called or whether it's safe. This means an attacker can make the pool call the `approve` function on its own token.

2. **Approve via Flash Loan**: The attacker deploys an exploit contract that, during the flash loan, passes the token contract as `target` and calldata for `approve(address(this), amount)` as `data`. Since the call originates from the pool, the `approve` function grants the exploit contract permission to spend the pool's tokens.

3. **Zero-Amount Loan Bypasses Repayment Check**: The attacker requests a loan of `0` tokens. This means the pool’s balance before and after the loan is unchanged, so the `token.balanceOf(address(this)) < balanceBefore` check passes, even though no repayment occurs.

4. **Immediate Drain via `transferFrom`**: After approval is granted, the exploit contract uses `transferFrom` to pull all tokens from the pool to the recovery address—all within the same transaction.

The entire attack happens in **one transaction** because the exploit logic is in the constructor of the deployed contract, fulfilling the challenge requirement.

