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

## Mainnet Fork Setup

Two challenges require Foundry to fork mainnet state — they use hardcoded addresses of live Uniswap V3, Curve, and Balancer contracts that don't exist in a blank test environment. Without the fork configured, `setUp()` fails before your solution code runs at all.

**Affected challenges:**

| Challenge | Env variable | Block forked |
|-----------|-------------|--------------|
| Puppet V3 (14) | `MAINNET_FORKING_URL` | 15,450,164 (fixed) |
| Curvy Puppet (17) | `MAINNET_RPC_URL` | latest |

Note the two challenges use **different variable names** — both must be set.

**Setup steps:**

1. Get a free mainnet RPC URL from [Alchemy](https://alchemy.com) (recommended) or [Infura](https://infura.io). The same API key URL works for both variables.

2. Copy the sample env file:
```bash
cp .env.sample .env
```

3. Edit `.env` and replace `YOUR_API_KEY_HERE` with your actual URL:
```
MAINNET_FORKING_URL=https://eth-mainnet.g.alchemy.com/v2/your_key
MAINNET_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/your_key
```

4. Load env vars, then run the fork tests:
```bash
source .env
forge test --mp test/puppet-v3/PuppetV3.t.sol -vvvv
forge test --mp test/curvy-puppet/CurvyPuppet.t.sol --fork-url $MAINNET_RPC_URL -vvvv
```

Both `.env` files live in the **project root** alongside `foundry.toml` — not inside the test subfolders. Foundry auto-loads `.env` from the project root when running `forge test`.

```
your-repo/
├── .env.sample          ← committed to git (safe, no real keys)
├── .env                 ← NOT committed (your real keys go here)
├── foundry.toml
├── test/
│   ├── README.md
│   ├── puppet-v3/
│   │   └── PuppetV3.t.sol
│   └── curvy-puppet/
│       └── CurvyPuppet.t.sol
```

> ⚠️ Never commit `.env` to git. Confirm `.env` is listed in `.gitignore` before adding your API key.

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
- **Puppet V3** ⚠️ requires `MAINNET_FORKING_URL` in `.env` — run `source .env` first:
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
- **Curvy Puppet** ⚠️ requires `MAINNET_RPC_URL` in `.env` — run `source .env` first:
```bash
forge test --mp test/curvy-puppet/CurvyPuppet.t.sol --fork-url $MAINNET_RPC_URL
```
- **Withdrawal**:
```bash
forge test --mp test/withdrawal/Withdrawal.t.sol
```
