
### 🔍 How It Works
- **`new SideEntranceExploit(pool, recovery)`**: Deploys the attacker contract, storing the pool and recovery address.
- **`exploit.attack(ETHER_IN_POOL)`**: Triggers the flash loan.
- **`execute()`**: Called by the pool during flash loan, deposits borrowed ETH into the pool, creating a balance for the exploit contract.
- **`pool.withdraw()`**: Withdraws the deposited ETH.
- **`payable(recovery).transfer(...)`**: Sends all ETH to the recovery account.

The exploit works because the pool only checks that its balance doesn’t decrease — but doesn’t prevent borrowed ETH from being “repaid” via deposit, which credits the attacker’s balance.

