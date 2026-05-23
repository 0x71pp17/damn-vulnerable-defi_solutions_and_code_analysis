# Testing with `Foundry`

This folder contains Foundry test files for all 18 Damn Vulnerable DeFi v4 challenges. Each subfolder corresponds to one challenge and contains a `.t.sol` file with the solution integrated.

## Setup

From the project root, initialize Foundry if you haven't already:

```bash
forge init --force .
```

This sets up the necessary directory structure (`src`, `test`, `lib`, `script`) and `foundry.toml` even though the directory is not empty.

Compile and run all tests:

```bash
forge build
forge test
```

`forge test` compiles and tests in one step — it automatically recompiles any changed source files before running.

> **Mainnet fork required:** Puppet V3 and Curvy Puppet fork mainnet state. Before running those tests, rename `.env.sample` to `.env` and add a valid `MAINNET_RPC_URL`.

## Filtering Tests

To run a specific challenge, use `--match-path` (short alias `-mp`):

```bash
forge test --match-path 'test/unstoppable/Unstoppable.t.sol'
```

Filter by contract or test function name:

```bash
forge test --match-contract Unstoppable
forge test --match-test test_unstoppable
```

Short aliases: `-mp` for `--match-path`, `-c` for `--match-contract`, `-m` for `--match-test`.

## Per-Challenge Commands

- **Unstoppable**:
```bash
forge test --mp test/unstoppable/Unstoppable.t.sol
```
- **Naive Receiver**:
```bash
forge test --mp test/naive-receiver/NaiveReceiver.t.sol
```
- **Truster**:
```bash
forge test --mp test/truster/Truster.t.sol
```
- **Side Entrance**:
```bash
forge test --mp test/side-entrance/SideEntrance.t.sol
```
- **The Rewarder**:
```bash
forge test --mp test/the-rewarder/TheRewarder.t.sol
```
- **Selfie**:
```bash
forge test --mp test/selfie/Selfie.t.sol
```
- **Compromised**:
```bash
forge test --mp test/compromised/Compromised.t.sol
```
- **Puppet**:
```bash
forge test --mp test/puppet/Puppet.t.sol
```
- **Puppet V2**:
```bash
forge test --mp test/puppet-v2/PuppetV2.t.sol
```
- **Free Rider**:
```bash
forge test --mp test/free-rider/FreeRider.t.sol
```
- **Backdoor**:
```bash
forge test --mp test/backdoor/Backdoor.t.sol
```
- **Climber**:
```bash
forge test --mp test/climber/Climber.t.sol
```
- **Wallet Mining**:
```bash
forge test --mp test/wallet-mining/WalletMining.t.sol
```
- **Puppet V3** ⚠️ requires `MAINNET_RPC_URL`:
```bash
forge test --mp test/puppet-v3/PuppetV3.t.sol
```
- **ABI Smuggling**:
```bash
forge test --mp test/abi-smuggling/ABISmuggling.t.sol
```
- **Shards**:
```bash
forge test --mp test/shards/Shards.t.sol
```
- **Curvy Puppet** ⚠️ requires `MAINNET_RPC_URL`:
```bash
forge test --mp test/curvy-puppet/CurvyPuppet.t.sol
```
- **Withdrawal**:
```bash
forge test --mp test/withdrawal/Withdrawal.t.sol
```
