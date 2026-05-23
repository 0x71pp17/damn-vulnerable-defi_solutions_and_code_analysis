# Damn Vulnerable DeFi

Damn Vulnerable DeFi is _the_ smart contract security playground for developers, security researchers and educators.

Perhaps the most sophisticated vulnerable set of Solidity smart contracts ever witnessed, it features flashloans, price oracles, governance, NFTs, DEXs, lending pools, smart contract wallets, timelocks, vaults, meta-transactions, token distributions, upgradeability and more.

Use Damn Vulnerable DeFi to:

- Sharpen your auditing and bug-hunting skills.
- Learn how to detect, test and fix flaws in realistic scenarios to become a security-minded developer.
- Benchmark smart contract security tooling.
- Create educational content on smart contract security with articles, tutorials, talks, courses, workshops, trainings, CTFs, etc.

## Disclaimer

All code, practices and patterns in this public repository fork, and original, are DAMN VULNERABLE and for educational purposes only.

DO NOT USE IN PRODUCTION.

---

## Forked v4

This repo is forked from [Damn Vulnerable Defi v4](https://github.com/theredguild/damn-vulnerable-defi).

**Working solutions** are integrated into the associated `.sol` file in the [`test`](https://github.com/0x71pp17/damn-vulnerable-defi_solutions_and_code_analysis/tree/master/test) folder of each challenge. **Walkthroughs** explaining each solution are in the [`walkthroughs`](https://github.com/0x71pp17/damn-vulnerable-defi_solutions_and_code_analysis/tree/master/walkthroughs) folder — links below.


## Challenges & Walkthroughs

Damn Vulnerable DeFi v4 includes 18 challenges covering flash loan manipulation, price oracle attacks, governance exploits, reentrancy, access control failures, and NFT marketplace bugs. The v4 version migrated to [Foundry](https://getfoundry.sh), updated all dependencies (e.g., OpenZeppelin Contracts v5), and added advanced features including multicalls, meta-transactions, permit2, Merkle proofs, and ERC1155. All challenges require depositing funds into designated recovery accounts.

Solutions and walkthroughs in this repo cover all 18 challenges available in the forked repository as of its last update (March 2025).

Each walkthrough includes:
- **Vulnerability explanation** — What the security flaw is and the vulnerable code
- **Complete exploit code** — Exact Solidity solution integrated into the test file
- **Why it works** — Technical explanation of the attack vector and mitigation

> Click a linked challenge name to go directly to its walkthrough.  
> `Unlinked` challenge names indicate a pending walkthrough — coming soon.

| # | Challenge | Vulnerability | Walkthrough |
|---|-----------|---------------|-------------|
| 1 | [**Unstoppable**](https://github.com/0x71pp17/damn-vulnerable-defi_solutions_and_code_analysis/blob/master/walkthroughs/Unstoppable.md) | Flash loan denial of service | ✅ |
| 2 | [**Naive Receiver**](https://github.com/0x71pp17/damn-vulnerable-defi_solutions_and_code_analysis/blob/master/walkthroughs/NaiveReceiver.md) | Unauthorized flash loan + meta-transaction caller spoofing | ✅ |
| 3 | [**Truster**](https://github.com/0x71pp17/damn-vulnerable-defi_solutions_and_code_analysis/blob/master/walkthroughs/Truster.md) | Arbitrary external call in flash loan | ✅ |
| 4 | [**Side Entrance**](https://github.com/0x71pp17/damn-vulnerable-defi_solutions_and_code_analysis/blob/master/walkthroughs/SideEntrance.md) | Flash loan reentrancy via deposit | ✅ |
| 5 | [**The Rewarder**](https://github.com/0x71pp17/damn-vulnerable-defi_solutions_and_code_analysis/blob/master/walkthroughs/Rewarder.md) | Intra-transaction replay via delayed state write | ✅ |
| 6 | [**Selfie**](https://github.com/0x71pp17/damn-vulnerable-defi_solutions_and_code_analysis/blob/master/walkthroughs/Selfie.md) | Flash loan governance attack | ✅ |
| 7 | [**Compromised**](https://github.com/0x71pp17/damn-vulnerable-defi_solutions_and_code_analysis/blob/master/walkthroughs/Compromised.md) | Oracle manipulation via leaked private keys | ✅ |
| 8 | **Puppet** | Uniswap v1 spot price oracle manipulation | Unlinked |
| 9 | **Puppet V2** | Uniswap v2 price oracle manipulation | Unlinked |
| 10 | **Free Rider** | NFT marketplace payment flaw + flash swap | Unlinked |
| 11 | **Backdoor** | Gnosis Safe setup callback exploit | Unlinked |
| 12 | **Climber** | Timelock access control + proxy upgrade chain | Unlinked |
| 13 | **Wallet Mining** | Predictable CREATE2 address exploitation | Unlinked |
| 14 | **Puppet V3** | Uniswap v3 TWAP oracle manipulation | Unlinked |
| 15 | **ABI Smuggling** | Calldata authorization bypass | Unlinked |
| 16 | **Shards** | Fractional NFT rounding exploit | Unlinked |
| 17 | **Curvy Puppet** | Curve read-only reentrancy + lending liquidation | Unlinked |
| 18 | **Withdrawal** | Bridge withdrawal without Merkle proof validation | Unlinked |

---

## Testing with Foundry

After cloning the repo, navigate into the project directory and run `forge init --force .` to initialize it as a Foundry project. This command sets up the necessary Foundry directory structure (`src`, `test`, `lib`, `script`) and configuration file (`foundry.toml`) even though the directory is not empty. Once initialized, compile with `forge build` and run tests with `forge test`.

> `forge test` **both compiles and tests** the project. It automatically runs compilation if source files have changed since the last build.

> **Note:** Challenges that fork mainnet state (Puppet V3, Curvy Puppet) require a valid `MAINNET_RPC_URL`. Rename `.env.sample` to `.env` and add your RPC URL before running those tests.

### Foundry Tests

To run tests on a specific file or folder, use the `--match-path` flag:

```bash
forge test --match-path 'test/specific_folder/*'
forge test --match-path 'test/MyTest.t.sol'
```

Filter by contract or test name with `--match-contract` or `--match-test`.

In Foundry, single-dash short aliases exist for common flags: `-mp` for `--match-path`, `-c` for `--match-contract`, `-m` for `--match-test`.

### Per-Challenge Test Commands

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
- **Puppet V3**:
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
- **Curvy Puppet**:
```bash
forge test --mp test/curvy-puppet/CurvyPuppet.t.sol
```
- **Withdrawal**:
```bash
forge test --mp test/withdrawal/Withdrawal.t.sol
```
