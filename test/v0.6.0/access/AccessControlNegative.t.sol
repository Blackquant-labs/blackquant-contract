// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "../VaultHelper.sol";
import "forge-std/Test.sol";

import {BaseTest} from "../Base.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {State, SyncMode} from "@src/v0.6.0/primitives/Enums.sol";

/// @notice Negative-path coverage for every `!isAllowed(...)` guard that the
/// Nethermind mutation audit (NM-0822) reported as not killed.
/// @dev Each test sets up the *other* allowed-address checks so the revert is
/// definitely attributable to the specific parameter being exercised. If any of
/// these mutants are hard-coded to `false`, the corresponding test must fail.
contract TestAccessControlNegative is BaseTest {
    using Math for uint256;

    uint16 constant ENTRY_FEE_RATE = 200; // 2%
    uint16 constant EXIT_FEE_RATE = 200; // 2%

    function setUp() public {
        setUpVault(0, 0, 0, ENTRY_FEE_RATE, EXIT_FEE_RATE);

        // Fund and whitelist a roster so most branches run in the happy path.
        dealAndApproveAndWhitelist(user1.addr);
        dealAndApproveAndWhitelist(user2.addr);
        dealAndApproveAndWhitelist(user3.addr);
        dealAndApproveAndWhitelist(user4.addr);
    }

    ///////////////////////////////////////////////
    // ## ERC7540Lib._requestDeposit !isAllowed ## //
    ///////////////////////////////////////////////

    /// @notice Kills `!isAllowed(msg.sender)` in ERC7540Lib._requestDeposit.
    /// @dev owner and controller are whitelisted; only msg.sender (the operator) is not.
    function test_requestDeposit_revertsWhen_msgSenderNotAllowed() public {
        // owner = user1 (whitelisted), controller = user2 (whitelisted)
        // operator = user3, but we first unwhitelist it to trigger the msg.sender check
        vm.prank(user1.addr);
        vault.setOperator(user3.addr, true);

        unwhitelist(user3.addr);
        assertFalse(vault.isAllowed(user3.addr));

        vm.prank(user3.addr);
        vm.expectRevert(abi.encodeWithSelector(AddressNotAllowed.selector, user3.addr));
        vault.requestDeposit(1e6, user2.addr, user1.addr);
    }

    ///////////////////////////////////////
    // ## ERC7540Lib._deposit !isAllowed ## //
    ///////////////////////////////////////

    /// @notice Kills `!isAllowed(receiver)` in ERC7540Lib._deposit.
    /// @dev controller has a claimable deposit, msg.sender is an allowed operator,
    /// only receiver is un-whitelisted.
    function test_deposit_revertsWhen_receiverNotAllowed() public {
        uint256 amount = assetBalance(user1.addr);

        // user1 asks for a deposit, gets settled and is ready to claim.
        requestDeposit(amount, user1.addr);
        updateAndSettle(0);

        // user2 is the operator of user1 and is whitelisted; only the receiver is not.
        vm.prank(user1.addr);
        vault.setOperator(user2.addr, true);
        unwhitelist(user3.addr);
        assertFalse(vault.isAllowed(user3.addr));

        vm.prank(user2.addr);
        vm.expectRevert(abi.encodeWithSelector(AddressNotAllowed.selector, user3.addr));
        vault.deposit(amount, user3.addr, user1.addr);
    }

    /// @notice Kills `!isAllowed(msg.sender)` in ERC7540Lib._deposit.
    /// @dev controller and receiver are whitelisted; only msg.sender (operator) is not.
    function test_deposit_revertsWhen_msgSenderNotAllowed() public {
        uint256 amount = assetBalance(user1.addr);

        requestDeposit(amount, user1.addr);
        updateAndSettle(0);

        vm.prank(user1.addr);
        vault.setOperator(user2.addr, true);
        unwhitelist(user2.addr);
        assertFalse(vault.isAllowed(user2.addr));
        assertTrue(vault.isAllowed(user1.addr));

        vm.prank(user2.addr);
        vm.expectRevert(abi.encodeWithSelector(AddressNotAllowed.selector, user2.addr));
        vault.deposit(amount, user1.addr, user1.addr);
    }

    ////////////////////////////////////
    // ## ERC7540Lib._mint !isAllowed ## //
    ////////////////////////////////////

    /// @notice Kills `!isAllowed(receiver)` in ERC7540Lib._mint.
    function test_mint_revertsWhen_receiverNotAllowed() public {
        uint256 amount = assetBalance(user1.addr);

        requestDeposit(amount, user1.addr);
        updateAndSettle(0);

        // user2 is operator of user1 and is whitelisted
        vm.prank(user1.addr);
        vault.setOperator(user2.addr, true);

        unwhitelist(user3.addr);
        assertFalse(vault.isAllowed(user3.addr));

        uint256 maxMint = vault.maxMint(user1.addr);
        assertGt(maxMint, 0, "sanity: controller should have claimable shares");

        vm.prank(user2.addr);
        vm.expectRevert(abi.encodeWithSelector(AddressNotAllowed.selector, user3.addr));
        vault.mint(maxMint, user3.addr, user1.addr);
    }

    /// @notice Kills the `!isSuperOperator(controller, msg.sender)` hard-code-to-true mutant in
    /// ERC7540Lib._mint: the super operator must be able to mint for an *unwhitelisted* controller.
    /// If the bypass branch is never taken, this test fails.
    function test_mint_superOperatorBypassesWhitelistChecks() public {
        uint256 amount = assetBalance(user1.addr);

        requestDeposit(amount, user1.addr);
        updateAndSettle(0);

        // Unwhitelist the controller/receiver: the only way this call can
        // succeed is through the super-operator bypass.
        unwhitelist(user1.addr);
        assertFalse(vault.isAllowed(user1.addr));

        uint256 maxMint = vault.maxMint(user1.addr);
        assertGt(maxMint, 0, "sanity: controller should have claimable shares");

        uint256 sharesBefore = vault.balanceOf(user1.addr);
        vm.prank(superOperator.addr);
        vault.mint(maxMint, user1.addr, user1.addr);
        assertEq(
            vault.balanceOf(user1.addr) - sharesBefore,
            maxMint,
            "super operator mint should succeed and transfer shares to receiver"
        );
    }

    ////////////////////////////////////////
    // ## ERC7540Lib._redeem !isAllowed ## //
    ////////////////////////////////////////

    /// @notice Kills `!isAllowed(controller)` in ERC7540Lib._redeem.
    /// @dev receiver & msg.sender (operator) allowed, controller not.
    function test_redeem_revertsWhen_controllerNotAllowed() public {
        uint256 amount = assetBalance(user1.addr);
        _seedClaimableRedeem(user1.addr, amount);

        // user2 is operator of user1 and whitelisted; only the controller is unwhitelisted.
        vm.prank(user1.addr);
        vault.setOperator(user2.addr, true);
        unwhitelist(user1.addr);
        assertFalse(vault.isAllowed(user1.addr));
        assertTrue(vault.isAllowed(user2.addr));

        uint256 maxRedeem = vault.maxRedeem(user1.addr);
        assertGt(maxRedeem, 0);

        vm.prank(user2.addr);
        vm.expectRevert(abi.encodeWithSelector(AddressNotAllowed.selector, user1.addr));
        vault.redeem(maxRedeem, user2.addr, user1.addr);
    }

    /// @notice Kills `!isAllowed(receiver)` in ERC7540Lib._redeem.
    function test_redeem_revertsWhen_receiverNotAllowed() public {
        uint256 amount = assetBalance(user1.addr);
        _seedClaimableRedeem(user1.addr, amount);

        // controller (user1) and msg.sender (user1) allowed; receiver (user3) not.
        unwhitelist(user3.addr);
        assertFalse(vault.isAllowed(user3.addr));

        uint256 maxRedeem = vault.maxRedeem(user1.addr);
        assertGt(maxRedeem, 0);

        vm.prank(user1.addr);
        vm.expectRevert(abi.encodeWithSelector(AddressNotAllowed.selector, user3.addr));
        vault.redeem(maxRedeem, user3.addr, user1.addr);
    }

    //////////////////////////////////////////
    // ## ERC7540Lib._withdraw !isAllowed ## //
    //////////////////////////////////////////

    /// @notice Kills `!isAllowed(msg.sender)` in ERC7540Lib._withdraw.
    /// @dev controller & receiver allowed, only the operator msg.sender is not.
    function test_withdraw_revertsWhen_msgSenderNotAllowed() public {
        uint256 amount = assetBalance(user1.addr);
        _seedClaimableRedeem(user1.addr, amount);

        vm.prank(user1.addr);
        vault.setOperator(user2.addr, true);
        unwhitelist(user2.addr);
        assertFalse(vault.isAllowed(user2.addr));

        uint256 maxWithdraw = vault.maxWithdraw(user1.addr);
        assertGt(maxWithdraw, 0);

        vm.prank(user2.addr);
        vm.expectRevert(abi.encodeWithSelector(AddressNotAllowed.selector, user2.addr));
        vault.withdraw(maxWithdraw, user1.addr, user1.addr);
    }

    ////////////////////////////////////////////////
    // ## ERC7540Lib.cancelRequestDeposit !isAllowed ## //
    ////////////////////////////////////////////////

    /// @notice Kills `!isAllowed(controller)` in ERC7540Lib.cancelRequestDeposit.
    /// @dev We deposit from an allowed user, then unwhitelist them and try to cancel.
    function test_cancelRequestDeposit_revertsWhen_controllerNotAllowed() public {
        uint256 amount = assetBalance(user1.addr);
        requestDeposit(amount, user1.addr);

        // user1 becomes not allowed before cancellation.
        unwhitelist(user1.addr);
        assertFalse(vault.isAllowed(user1.addr));

        vm.prank(user1.addr);
        vm.expectRevert(abi.encodeWithSelector(AddressNotAllowed.selector, user1.addr));
        vault.cancelRequestDeposit();
    }

    ////////////////////////////////////////
    // ## Vault._withdraw !isAllowed ## //
    ////////////////////////////////////////
    // Vault._withdraw (the internal override) is hit only when the vault is closed
    // and the controller has no claimable redeem request (the synchronous close path).

    /// @notice Kills `!isAllowed(owner)` in Vault._withdraw (closed path).
    function test_closedWithdraw_revertsWhen_ownerNotAllowed() public {
        uint256 amount = assetBalance(user1.addr);
        _seedClosedWithdrawable(user1.addr, amount);

        // unwhitelist the owner AFTER the vault is closed and deposit has settled
        unwhitelist(user1.addr);
        assertFalse(vault.isAllowed(user1.addr));

        vm.prank(user1.addr);
        vm.expectRevert(abi.encodeWithSelector(AddressNotAllowed.selector, user1.addr));
        vault.withdraw(1, user1.addr, user1.addr);
    }

    /// @notice Kills `!isAllowed(receiver)` in Vault._withdraw (closed path).
    function test_closedWithdraw_revertsWhen_receiverNotAllowed() public {
        uint256 amount = assetBalance(user1.addr);
        _seedClosedWithdrawable(user1.addr, amount);

        unwhitelist(user3.addr);
        assertFalse(vault.isAllowed(user3.addr));

        vm.prank(user1.addr);
        vm.expectRevert(abi.encodeWithSelector(AddressNotAllowed.selector, user3.addr));
        vault.withdraw(1, user3.addr, user1.addr);
    }

    /// @notice Kills `!isAllowed(msg.sender)` in Vault._withdraw (closed path).
    /// @dev The closed path routes through `_withdraw(msg.sender, receiver, owner, ...)`.
    /// When the operator (msg.sender) is not allowed, the check on msg.sender must revert.
    function test_closedWithdraw_revertsWhen_msgSenderNotAllowed() public {
        uint256 amount = assetBalance(user1.addr);
        _seedClosedWithdrawable(user1.addr, amount);

        vm.prank(user1.addr);
        vault.setOperator(user2.addr, true);

        unwhitelist(user2.addr);
        assertFalse(vault.isAllowed(user2.addr));

        vm.prank(user2.addr);
        vm.expectRevert(abi.encodeWithSelector(AddressNotAllowed.selector, user2.addr));
        vault.withdraw(1, user1.addr, user1.addr);
    }

    //////////////////////////////////
    // ## Vault.syncDeposit checks ## //
    //////////////////////////////////

    /// @notice Kills `!isAllowed(msg.sender)` in Vault.syncDeposit.
    /// @dev Sets up the sync-deposit flow, then unwhitelists the caller before
    /// calling syncDeposit. receiver is allowed.
    function test_syncDeposit_revertsWhen_msgSenderNotAllowed() public {
        _enableSyncDeposit();

        unwhitelist(user1.addr);
        assertFalse(vault.isAllowed(user1.addr));
        assertTrue(vault.isAllowed(user2.addr));

        vm.prank(user1.addr);
        vm.expectRevert(abi.encodeWithSelector(AddressNotAllowed.selector, user1.addr));
        vault.syncDeposit(1e6, user2.addr, address(0));
    }

    //////////////////////////////////
    // ## Vault.syncRedeem checks ## //
    //////////////////////////////////

    /// @notice Kills `!isAllowed(msg.sender)` in Vault.syncRedeem.
    function test_syncRedeem_revertsWhen_msgSenderNotAllowed() public {
        _enableSyncDeposit();
        _enableSyncRedeem();

        // user1 acquires shares via sync deposit
        uint256 balance = assetBalance(user1.addr);
        vm.prank(user1.addr);
        vault.syncDeposit(balance, user1.addr, address(0));

        unwhitelist(user1.addr);
        assertFalse(vault.isAllowed(user1.addr));

        vm.prank(user1.addr);
        vm.expectRevert(abi.encodeWithSelector(AddressNotAllowed.selector, user1.addr));
        vault.syncRedeem(1, user2.addr, 0);
    }

    /// @notice Kills `!isAllowed(receiver)` in Vault.syncRedeem.
    function test_syncRedeem_revertsWhen_receiverNotAllowed() public {
        _enableSyncDeposit();
        _enableSyncRedeem();

        uint256 balance = assetBalance(user1.addr);
        vm.prank(user1.addr);
        vault.syncDeposit(balance, user1.addr, address(0));

        unwhitelist(user2.addr);
        assertFalse(vault.isAllowed(user2.addr));

        vm.prank(user1.addr);
        vm.expectRevert(abi.encodeWithSelector(AddressNotAllowed.selector, user2.addr));
        vault.syncRedeem(1, user2.addr, 0);
    }

    ///////////////////////
    // ## Test helpers ## //
    ///////////////////////

    /// @dev Seed a claimable redeem request: user deposits, settles, claims shares,
    /// then requests and settles a redeem. After this, `maxRedeem(user) > 0`.
    function _seedClaimableRedeem(
        address user,
        uint256 amount
    ) internal {
        requestDeposit(amount, user);
        updateAndSettle(0);
        deposit(amount, user);

        // Read the balance BEFORE vm.prank: otherwise the argument evaluation
        // consumes the prank, leaving requestRedeem called from the test contract.
        uint256 shares = vault.balanceOf(user);
        vm.prank(user);
        vault.requestRedeem(shares, user, user);
        updateAndSettleRedeem(amount);
        vm.warp(block.timestamp + 1);
    }

    /// @dev Drive the vault into the closed-with-balance state so that
    /// `state == Closed && claimableRedeemRequest == 0`. This exercises the
    /// synchronous close path through Vault.withdraw / Vault._withdraw.
    function _seedClosedWithdrawable(
        address user,
        uint256 amount
    ) internal {
        requestDeposit(amount, user);
        updateAndSettle(0);
        deposit(amount, user);

        // Initiate closing then close; leaves user holding shares without a claimable redeem.
        vm.prank(vault.owner());
        vault.initiateClosing();
        updateAndClose(amount);
    }

    /// @dev Enable the synchronous deposit flow: set a lifespan, settle, warp.
    function _enableSyncDeposit() internal {
        vm.prank(vault.safe());
        vault.updateTotalAssetsLifespan(1000);
        updateAndSettle(0);
        vm.warp(block.timestamp + 1);
    }

    /// @dev Enable the synchronous redeem flow (must be called after _enableSyncDeposit).
    function _enableSyncRedeem() internal {
        vm.prank(vault.safe());
        vault.setSyncMode(SyncMode.Both);
    }
}
