# Damn Vulnerable DeFi

[#damn-vulnerable-defi](#damn-vulnerable-defi)

Damn Vulnerable DeFi is *the* smart contract security playground for developers, security researchers and educators.

Perhaps the most sophisticated vulnerable set of Solidity smart contracts ever witnessed, it features flashloans, price oracles, governance, NFTs, DEXs, lending pools, smart contract wallets, timelocks, vaults, meta-transactions, token distributions, upgradeability and more.

Use Damn Vulnerable DeFi to:

- Sharpen your auditing and bug-hunting skills.
- Learn how to detect, test and fix flaws in realistic scenarios to become a security-minded developer.
- Benchmark smart contract security tooling.
- Create educational content on smart contract security with articles, tutorials, talks, courses, workshops, trainings, CTFs, etc.

## Disclaimer

[#disclaimer](#disclaimer)

All code, practices and patterns in this public repository fork, and original, are **DAMN VULNERABLE** and for educational purposes only.

**DO NOT USE IN PRODUCTION**.

---

## Forked v4

[#forked-v4](#forked-v4)

This repo is forked from [Damn Vulnerable Defi v4](https://github.com/theredguild/damn-vulnerable-defi).

**Working solutions** are integrated into the associated `.sol` file in the [`test`](https://github.com/0x71pp17/damn-vulnerable-defi_solutions_and_code_analysis/tree/master/test) folder of each challenge. **Walkthroughs** explaining each solution are in the [`walkthroughs`](https://github.com/0x71pp17/damn-vulnerable-defi_solutions_and_code_analysis/tree/master/walkthroughs) folder — links below.

## Challenges & Walkthroughs

[#challenges--walkthroughs](#challenges--walkthroughs)

Damn Vulnerable DeFi v4 includes 18 challenges covering flash loan manipulation, price oracle attacks, governance exploits, reentrancy, access control failures, and NFT marketplace bugs. v4 brought a full migration from Hardhat to Foundry, updated all contracts to Solidity 0.8.25, and upgraded all dependencies (e.g., OpenZeppelin Contracts v5, solmate, solady, murky, Permit2). All challenges now require depositing rescued funds into designated recovery accounts.

**New challenges in v4.0.0:** Withdrawal, Curvy Puppet, and Shards.  
**Significantly reworked in v4.0.0:** The Rewarder (completely new Merkle-proof-based distribution mechanic) and Unstoppable (new monitor contract with pausing).  
**Updated in v4.1.0:** Wallet Mining (new CREATEX-based deployment mechanic and Safe Singleton Factory integration).

Solutions and walkthroughs in this repo cover all 18 challenges available in the forked repository as of its last update (March 2025).

Each walkthrough includes:

- **Vulnerability explanation** — What the security flaw is and the vulnerable code
- **Complete exploit code** — Exact Solidity solution integrated into the test file
- **Why it works** — Technical explanation of the attack vector and mitigation

> Click a challenge name to go directly to its walkthrough.

| #  | Challenge                                                                                                                                    | Vulnerability                                                    |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------- |
| 1  | [**Unstoppable**](https://github.com/0x71pp17/damn-vulnerable-defi_solutions_and_code_analysis/blob/master/walkthroughs/Unstoppable.md)      | Flash loan denial of service                                     |
| 2  | [**Naive Receiver**](https://github.com/0x71pp17/damn-vulnerable-defi_solutions_and_code_analysis/blob/master/walkthroughs/NaiveReceiver.md) | Unauthorized flash loan + meta-transaction caller spoofing       |
| 3  | [**Truster**](https://github.com/0x71pp17/damn-vulnerable-defi_solutions_and_code_analysis/blob/master/walkthroughs/Truster.md)              | Arbitrary external call in flash loan                            |
| 4  | [**Side Entrance**](https://github.com/0x71pp17/damn-vulnerable-defi_solutions_and_code_analysis/blob/master/walkthroughs/SideEntrance.md)   | Flash loan reentrancy via deposit                                |
| 5  | [**The Rewarder**](https://github.com/0x71pp17/damn-vulnerable-defi_solutions_and_code_analysis/blob/master/walkthroughs/Rewarder.md)        | Intra-transaction replay via delayed state write *(reworked v4)* |
| 6  | [**Selfie**](https://github.com/0x71pp17/damn-vulnerable-defi_solutions_and_code_analysis/blob/master/walkthroughs/Selfie.md)                | Flash loan governance attack                                     |
| 7  | [**Compromised**](https://github.com/0x71pp17/damn-vulnerable-defi_solutions_and_code_analysis/blob/master/walkthroughs/Compromised.md)      | Oracle manipulation via leaked private keys                      |
| 8  | [**Puppet**](https://github.com/0x71pp17/damn-vulnerable-defi_solutions_and_code_analysis/blob/master/walkthroughs/Puppet.md)                | Uniswap v1 spot price oracle manipulation                        |
| 9  | [**Puppet V2**](https://github.com/0x71pp17/damn-vulnerable-defi_solutions_and_code_analysis/blob/master/walkthroughs/PuppetV2.md)           | Uniswap v2 spot price oracle manipulation                        |
| 10 | [**Free Rider**](https://github.com/0x71pp17/damn-vulnerable-defi_solutions_and_code_analysis/blob/master/walkthroughs/FreeRider.md)         | NFT marketplace payment flaw + flash swap                        |
| 11 | [**Backdoor**](https://github.com/0x71pp17/damn-vulnerable-defi_solutions_and_code_analysis/blob/master/walkthroughs/Backdoor.md)            | Gnosis Safe setup callback exploit                               |
| 12 | [**Climber**](https://github.com/0x71pp17/damn-vulnerable-defi_solutions_and_code_analysis/blob/master/walkthroughs/Climber.md)              | Timelock access control + proxy upgrade chain                    |
| 13 | [**Wallet Mining**](https://github.com/0x71pp17/damn-vulnerable-defi_solutions_and_code_analysis/blob/master/walkthroughs/WalletMining.md)   | Predictable CREATE2 address exploitation *(updated v4.1)*        |
| 14 | [**Puppet V3**](https://github.com/0x71pp17/damn-vulnerable-defi_solutions_and_code_analysis/blob/master/walkthroughs/PuppetV3.md)           | Uniswap v3 TWAP oracle manipulation                              |
| 15 | [**ABI Smuggling**](https://github.com/0x71pp17/damn-vulnerable-defi_solutions_and_code_analysis/blob/master/walkthroughs/ABISmuggling.md)   | Calldata authorization bypass                                    |
| 16 | [**Shards**](https://github.com/0x71pp17/damn-vulnerable-defi_solutions_and_code_analysis/blob/master/walkthroughs/Shards.md)                | Fractional NFT rounding exploit *(new v4)*                       |
| 17 | [**Curvy Puppet**](https://github.com/0x71pp17/damn-vulnerable-defi_solutions_and_code_analysis/blob/master/walkthroughs/CurvyPuppet.md)     | Curve read-only reentrancy + lending liquidation *(new v4)*      |
| 18 | [**Withdrawal**](https://github.com/0x71pp17/damn-vulnerable-defi_solutions_and_code_analysis/blob/master/walkthroughs/Withdrawal.md)        | Bridge withdrawal without Merkle proof validation *(new v4)*     |

---

> For Foundry setup and per-challenge test commands, see [`test/README.md`](https://github.com/0x71pp17/damn-vulnerable-defi_solutions_and_code_analysis/blob/master/test/README.md).
