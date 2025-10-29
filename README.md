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

Here, solutions will be integrated into the associated `.sol` file in [`test`](https://github.com/0x71pp17/damn-vulnerable-defi/tree/master/test) folder associated with each vulnerable code challenge.

Walkthroughs will be included also within this repo, in an added [`walkthroughs`](https://github.com/0x71pp17/damn-vulnerable-defi/tree/master/walkthroughs) folder. Links will follow below.


## v4 Challenges

Damn Vulnerable DeFi v4 includes a series of challenges designed to teach security vulnerabilities in decentralized finance (DeFi) applications. The new version has migrated to [Foundry](https://getfoundry.sh), updated dependencies, and modernized existing challenges, with some previous solutions potentially no longer working All challenges now require depositing funds into designated recovery accounts

The challenges in Damn Vulnerable DeFi v4 include:

- **Unstoppable**: Exploit a flash loan invariant by disrupting the balance check through a direct token transfer to the vault
- **Naive Receiver**: Drain funds from a receiver by exploiting unguarded flash loan callbacks and using meta-transactions to perform multiple operations in one transaction
- **Truster**: Exploit arbitrary delegate calls in a flash loan to approve and transfer all tokens from the pool
- **Side Entrance**: Abuse a non-standard balance check in a flash loan by depositing borrowed funds back into the pool to fake repayment
- **The Rewarder**: Exploit a timing vulnerability in a reward distribution mechanism using a flash loan to manipulate reward calculations
- **Selfie**: Gain governance control by manipulating token balances via a flash loan to pass a malicious proposal
- **Compromised**: Recover private keys from leaked hash prefixes to steal funds
- **Puppet, Puppet V2, Puppet V3**: Manipulate pricing or collateralization in lending protocols through oracle or liquidity manipulation
- **Free Rider**: Use a Uniswap flash swap to buy NFTs, claim a bounty, and repay the loan in one transaction
- **Backdoor**: Exploit a wallet factory's setup function to execute malicious code during wallet creation and drain tokens
- **Climber**: Chain multiple actions through a proxy upgrade mechanism to drain funds
- **Wallet Mining**: Exploit predictable wallet address generation to claim rewards
- **ABI Smuggling**: Bypass security checks using dynamic bytecode loading
- **Shards**: Exploit improper handling of ERC1155 tokens in a multi-token vault
- **Curvy Puppet**: Manipulate Curve AMM pricing to exploit a lending protocol
- **Withdrawal**: Exploit a bridge mechanism between L1 and L2 by manipulating withdrawal proofs or balances

Four brand new challenges introduced in v4 are `Curvy Puppet, Shards, Withdrawal, and The Rewarder` (which was completely reworked) These challenges incorporate advanced features such as multicalls, meta-transactions, permit2, Merkle proofs, and ERC1155

The challenges cover critical DeFi vulnerabilities like:

Flash loan manipulation
Price oracle attacks
Governance token voting attacks
Reentrancy exploits
Access control failures
NFT marketplace bugs 


## Walkthroughs

Damn Vulnerable DeFi v4 walkthroughs here cover the classic challenges (1-10) and the new v4 challenges. 

The walkthroughs include for each challenge:

- **Vulnerability explanation** - What the security flaw is
- **Complete exploit code** - Exact Solidity code to add to test files
- **Why it works** - Technical explanation of the attack vector



> Click link in challenge name to go direct to each challenge walkthrough
>
> `Unlinked` challenge names indicate pending walkthrough; comming soon to add walkthrough content and remaining links... stay tuned

### Classic Challenges (Updated for v4)
1. [**Unstoppable**](https://github.com/0x71pp17/damn-vulnerable-defi/blob/master/walkthroughs/Unstoppable.md) - Flash loan denial of service
2. [**Naive Receiver**](https://github.com/0x71pp17/damn-vulnerable-defi/blob/master/walkthroughs/NaiveReceiver.md) - Unauthorized flash loan exploitation 
3. [**Truster**](https://github.com/0x71pp17/damn-vulnerable-defi_solutions_and_code_analysis/blob/master/walkthroughs/Truster.md) - Arbitrary external call abuse
4. [**Side Entrance**](https://github.com/0x71pp17/damn-vulnerable-defi_solutions_and_code_analysis/blob/master/walkthroughs/SideEntrance.md) - Flash loan reentrancy via deposit
5. **The Rewarder** - Reward distribution manipulation (completely reworked in v4)
6. **Selfie** - Governance attack via flash loan voting
7. **Compromised** - Oracle manipulation with leaked private keys
8. **Puppet** - Uniswap v1 price manipulation
9. **Puppet v2** - Uniswap v2 price manipulation
10. **Free Rider** - NFT marketplace payment flaw exploitation

### New V4 Challenges
11. **Curvy Puppet** - Curve AMM price manipulation attack
12. **Shards** - Fractional NFT system exploitation
13. **Withdrawal** - Bridge withdrawal mechanism attack
14. **The Rewarder (New)** - Advanced token distribution vulnerabilities

---

## Testing with Foundry

After cloning the repo, navigate into the project directory and run `forge init --force .` to initialize it as a Foundry project. This command sets up the necessary Foundry directory structure (`src`, `test`, `lib`, `script`) and configuration file (`foundry.toml`) even though the directory is not empty. Once initialized, you can compile the contracts with `forge build` and run tests with `forge test`.

> The `forge test` command **both compiles and tests** the project by default. It automatically runs the compilation step if the project hasn't been compiled yet or if any source files have changed since the last compilation. While `forge build` is used specifically for compiling the project, running `forge test` will trigger a build as its first step before executing the tests.



### Foundry Tests

To run Foundry tests on specific files or folders, use the `--match-path` flag with a glob pattern.

```bash
forge test --match-path 'test/specific_folder/*'
forge test --match-path 'test/MyTest.t.sol'
```

You can also filter by contract or test name using `--match-contract` or `--match-test`.

---

In Foundry, **single-dash (`-`)** flags are short aliases for **double-dash (`--`)** long flags.

For `--match-path`, the correct short alias is **`-mp`** (two characters after the single dash). So, you can use either:

```bash
forge test --match-path 'test/MyTest.t.sol'
```

or its equivalent short form:

```bash
forge test -mp 'test/MyTest.t.sol'
```

Other common examples are `-c` for `--match-contract` and `-m` for `--match-test`.

---

### Foundry Testing in Damn-Vulnerable-DeFi

This list provides **specific Foundry CLI commands** to run tests for individual Damn-Vulnerable-DeFi challenges. Each command uses the `--match-path` (`-mp`) flag to target a single test file by its path within the `test/` directory.

To use them, navigate to your Foundry project root and run the command for the challenge you want to test. For example, `forge test --mp test/unstoppable/Unstoppable.t.sol` compiles the project and executes only the tests defined in that specific file, which is useful for focusing on one challenge at a time.



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
- **Puppet, Puppet V2, Puppet V3**:  
```bash
forge test --mp test/puppet/Puppet.t.sol
```
```bash
forge test --mp test/puppet-v2/PuppetV2.t.sol
```
```bash
forge test --mp test/puppet-v3/PuppetV3.t.sol
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
