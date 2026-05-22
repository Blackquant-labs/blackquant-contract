// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "./VaultHelper.sol";
import "forge-std/Test.sol";

import {BaseTest} from "./Base.sol";
import {GuardrailsLib} from "@src/v0.6.0/libraries/GuardrailsLib.sol";
import {State, SyncMode} from "@src/v0.6.0/primitives/Enums.sol";
import {HaircutTaken} from "@src/v0.6.0/primitives/Events.sol";
import {Guardrails, Rates} from "@src/v0.6.0/primitives/Struct.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Targeted coverage for the Vault-v0.6.0 state-branch mutants
/// flagged by NM-0822 that are not killed by the existing suite.
contract TestVaultBranches is BaseTest {
    using Math for uint256;

    //////////////////////////////////////
    // ## claimSharesOnBehalf (claimable == 0) ## //
    //////////////////////////////////////

    /// @notice Kills `if (claimable > 0)` → `if (true)` mutant in
    /// Vault.claimSharesOnBehalf. A controller with no claimable shares
    /// must be skipped (no _deposit call). If the guard is bypassed,
    /// _deposit would run and either revert or emit a Deposit event
    /// for 0 assets — neither of which happens on the correct path.
    function test_claimSharesOnBehalf_skipsControllerWithZeroClaimable() public {
        enableWhitelist = false;
        setUpVault(0, 0, 0);

        // user1 has nothing to claim: no requestDeposit, no settle.
        address[] memory controllers = new address[](1);
        controllers[0] = user1.addr;

        vm.recordLogs();
        vm.prank(vault.safe());
        vault.claimSharesOnBehalf(controllers);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // No Deposit event must be emitted.
        bytes32 depositTopic = keccak256("Deposit(address,address,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == depositTopic) {
                assertTrue(false, "no Deposit event should be emitted when claimable == 0");
            }
        }

        // And user1 holds no shares.
        assertEq(vault.balanceOf(user1.addr), 0, "user1 must not receive any shares");
    }

    //////////////////////////
    // ## maxDeposit paused ## //
    //////////////////////////

    /// @notice Kills `paused()` → false mutant in Vault.maxDeposit.
    /// When the vault is paused, maxDeposit must return 0 regardless of
    /// claimable state.
    function test_maxDeposit_returnsZeroWhenPaused() public {
        enableWhitelist = false;
        setUpVault(0, 0, 0);

        // Seed a claimable deposit so the non-paused path would return > 0.
        dealAndApprove(user1.addr);
        uint256 amount = assetBalance(user1.addr);
        requestDeposit(amount, user1.addr);
        updateAndSettle(0);
        vm.warp(block.timestamp + 1);

        assertGt(vault.maxDeposit(user1.addr), 0, "sanity: maxDeposit must be > 0 while unpaused");

        vm.prank(vault.owner());
        vault.pause();

        assertEq(vault.maxDeposit(user1.addr), 0, "maxDeposit must return 0 when paused");
    }

    //////////////////////////////////////////////
    // ## maxRedeem (closed + shares==0 branch) ## //
    //////////////////////////////////////////////

    /// @notice Kills `shares == 0 && state == Closed` → false mutant in
    /// Vault.maxRedeem. When the vault is closed and the controller has
    /// no claimable redeem, maxRedeem must return the controller's share
    /// balance (so they can withdraw synchronously). If the branch is
    /// mutated away, it returns 0 instead.
    function test_maxRedeem_closedVaultReturnsShareBalance() public {
        enableWhitelist = false;
        setUpVault(0, 0, 0);

        dealAndApprove(user1.addr);
        uint256 amount = assetBalance(user1.addr);
        requestDeposit(amount, user1.addr);
        updateAndSettle(0);
        deposit(amount, user1.addr);

        uint256 sharesBalance = vault.balanceOf(user1.addr);
        assertGt(sharesBalance, 0, "sanity: user1 must hold shares before closing");

        // Initiate + close vault without any pending redeem request.
        vm.prank(vault.owner());
        vault.initiateClosing();
        updateAndClose(amount);

        assertEq(uint8(vault.state()), uint8(State.Closed), "sanity: vault must be Closed");
        assertEq(vault.claimableRedeemRequest(0, user1.addr), 0, "sanity: no claimable redeem");
        assertEq(
            vault.maxRedeem(user1.addr),
            sharesBalance,
            "maxRedeem must return the full share balance when closed with no claimable redeem"
        );
    }

    ///////////////////////////////////////
    // ## previewSyncDeposit paused/invalid ## //
    ///////////////////////////////////////

    /// @notice Kills `paused() || !isSyncDepositAllowed()` → false mutant
    /// in previewSyncDeposit. Split into two sub-scenarios so either
    /// clause can be independently mutated and still kill the test.
    function test_previewSyncDeposit_returnsZeroWhenPaused() public {
        _enableSyncDeposit();

        // Unpaused and sync-allowed: non-zero.
        assertGt(vault.previewSyncDeposit(1e6), 0, "sanity: preview must be > 0 before pause");

        vm.prank(vault.owner());
        vault.pause();

        assertEq(vault.previewSyncDeposit(1e6), 0, "previewSyncDeposit must return 0 when paused");
    }

    function test_previewSyncDeposit_returnsZeroWhenTotalAssetsInvalid() public {
        _enableSyncDeposit();

        assertGt(vault.previewSyncDeposit(1e6), 0, "sanity: preview must be > 0 while valid");

        // Expire totalAssets → isSyncDepositAllowed becomes false.
        vm.prank(vault.safe());
        vault.expireTotalAssets();

        assertEq(
            vault.previewSyncDeposit(1e6), 0, "previewSyncDeposit must return 0 when isSyncDepositAllowed is false"
        );
    }

    /////////////////////////////////////////////////
    // ## securityCouncilUpdateTotalAssets reverts ## //
    /////////////////////////////////////////////////

    /// @notice Kills `state == Closed` → false mutant: must revert with Closed.
    function test_securityCouncilUpdateTotalAssets_revertsWhenClosed() public {
        enableWhitelist = false;
        setUpVault(0, 0, 0);

        vm.prank(vault.owner());
        vault.initiateClosing();
        updateAndClose(0);

        vm.prank(vault.securityCouncil());
        vm.expectRevert(Closed.selector);
        vault.securityCouncilUpdateTotalAssets(123);
    }

    /// @notice Kills `isTotalAssetsValid()` → false mutant: must revert with
    /// ValuationUpdateNotAllowed when totalAssets is still valid (unexpired).
    function test_securityCouncilUpdateTotalAssets_revertsWhenValid() public {
        enableWhitelist = false;
        setUpVault(0, 0, 0);

        // Set a lifespan so totalAssets becomes "valid" after a settle.
        vm.prank(vault.safe());
        vault.updateTotalAssetsLifespan(1000);
        updateAndSettle(0);
        vm.warp(block.timestamp + 1);

        assertTrue(vault.isTotalAssetsValid(), "sanity: totalAssets must be valid");

        vm.prank(vault.securityCouncil());
        vm.expectRevert(ValuationUpdateNotAllowed.selector);
        vault.securityCouncilUpdateTotalAssets(123);
    }

    ///////////////////////////////////
    // ## syncRedeem haircut event ## //
    ///////////////////////////////////

    /// @notice Kills `haircutShares > 0` → false and `0 > haircutShares`
    /// mutants in Vault.syncRedeem. Sets a non-zero haircut rate and
    /// asserts the HaircutTaken event fires with haircutShares > 0.
    function test_syncRedeem_emitsHaircutTakenWhenPositive() public {
        enableWhitelist = false;
        setUpVault(0, 0, 0, 0, 0);

        // Enable sync redeem, then update the haircut rate via updateRates.
        vm.prank(vault.safe());
        vault.updateTotalAssetsLifespan(1000);

        dealAndApprove(user1.addr);
        uint256 amount = assetBalance(user1.addr);
        requestDeposit(amount, user1.addr);
        updateAndSettle(0);
        deposit(amount, user1.addr);
        vm.warp(block.timestamp + 1);

        vm.prank(vault.safe());
        vault.setSyncMode(SyncMode.Both);

        Rates memory rates = Rates({
            managementRate: 0,
            performanceRate: 0,
            entryRate: 0,
            exitRate: 0,
            haircutRate: 500 // 5%
        });
        updateRates(rates);

        uint256 sharesToRedeem = vault.balanceOf(user1.addr) / 2;

        // Expect the HaircutTaken event to be emitted. Since haircutShares depends
        // on share amount and the exact value is deterministic, we capture via
        // recordLogs and assert presence.
        vm.recordLogs();
        vm.prank(user1.addr);
        vault.syncRedeem(sharesToRedeem, user1.addr, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 haircutTopic = keccak256("HaircutTaken(address,uint256,uint16)");
        bool found = false;
        uint256 emittedHaircutShares;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == haircutTopic) {
                found = true;
                // abi-decode non-indexed data: (uint256 haircutShares, uint16 rate)
                (emittedHaircutShares,) = abi.decode(logs[i].data, (uint256, uint16));
                break;
            }
        }
        assertTrue(found, "HaircutTaken event must be emitted when haircutShares > 0");
        assertGt(emittedHaircutShares, 0, "haircutShares in event must be > 0");
    }

    //////////////////////////////////
    // ## withdraw exit-fee effect ## //
    //////////////////////////////////

    /// @notice Kills the `takeFees(exitFeeShares, ...)` → `assert(true)` mutant
    /// in Vault.withdraw (closed sync path). When the vault is closed with a
    /// non-zero exit fee and a user withdraws, the fee receiver's share balance
    /// must increase by the expected exit-fee amount. If takeFees is a no-op,
    /// the fee receiver balance stays at 0.
    function test_withdraw_closedPathMintsExitFeeSharesToReceiver() public {
        enableWhitelist = false;
        // 2% exit fee.
        setUpVault(0, 0, 0, 0, 200);

        dealAndApprove(user1.addr);
        uint256 amount = assetBalance(user1.addr);
        requestDeposit(amount, user1.addr);
        updateAndSettle(0);
        deposit(amount, user1.addr);

        // Close the vault without any pending redeem request so the
        // synchronous close path in withdraw is taken.
        vm.prank(vault.owner());
        vault.initiateClosing();
        updateAndClose(amount);

        uint256 feeReceiverSharesBefore = vault.balanceOf(vault.feeReceiver());

        // Withdraw half the user's assets.
        uint256 withdrawAmount = amount / 2;
        vm.prank(user1.addr);
        vault.withdraw(withdrawAmount, user1.addr, user1.addr);

        uint256 feeReceiverSharesAfter = vault.balanceOf(vault.feeReceiver());
        assertGt(
            feeReceiverSharesAfter,
            feeReceiverSharesBefore,
            "feeReceiver must have been minted exit-fee shares by takeFees"
        );
    }

    ///////////////////////////////////////////////
    // ## GuardrailsLib.isCompliant arithmetic ## //
    ///////////////////////////////////////////////

    /// @notice Kills arithmetic mutations in the INCREASE formula:
    ///   variation = (nextPps - currentPps) * scaleToOneYear * SCALE / currentPps
    ///
    /// Setup (simplest possible):
    ///   currentPps = 1e18, nextPps = 2e18, timePast = ONE_YEAR
    ///   → scaleToOneYear = 1
    ///   → variation = (2e18 - 1e18) * 1 * 1e18 / 1e18 = 1e18  (100% per year)
    ///
    /// Guardrails: upperRate = lowerRate = 1e18 (both must be exactly 100%).
    /// Any mutation that changes the variation from exactly 1e18 will fail
    /// either the upper or lower bound.
    ///
    /// Kills: - → % (variation=0, fails lower), - → * (huge, fails upper),
    ///        / → - (huge, fails upper), / → * (huge, fails upper).
    function test_isCompliant_increaseExactVariation_fullYear() public view {
        Guardrails memory g = Guardrails({upperRate: 1e18, lowerRate: int256(1e18)});

        //   currentPps = 1e18  →  nextPps = 2e18  →  100% increase over ONE_YEAR
        bool result = GuardrailsLib.isCompliant(1e18, 2e18, GuardrailsLib.ONE_YEAR, g);
        assertTrue(result, "100% increase over 1 year must be compliant with [100%, 100%] bounds");

        // Sanity: a slightly different nextPps MUST fail (proves the bounds are tight).
        bool tooHigh = GuardrailsLib.isCompliant(1e18, 2e18 + 1e15, GuardrailsLib.ONE_YEAR, g);
        assertFalse(tooHigh, "100.1% increase must violate the 100% upper bound");
    }

    /// @notice Same formula but with timePast = ONE_YEAR / 2 → scaleToOneYear = 2.
    /// This kills the * → ** mutation on scaleToOneYear:
    ///   correct:  0.5e18 *  2 = 1e18
    ///   mutated:  0.5e18 ** 2 = 0.25e36  (fails upper bound)
    ///
    /// Setup:
    ///   currentPps = 1e18, nextPps = 1.5e18, timePast = ONE_YEAR / 2
    ///   → scaleToOneYear = 2
    ///   → variation = 0.5e18 * 2 * 1e18 / 1e18 = 1e18
    function test_isCompliant_increaseExactVariation_halfYear() public view {
        Guardrails memory g = Guardrails({upperRate: 1e18, lowerRate: int256(1e18)});

        //   50% in 6 months → 100% annualized
        bool result = GuardrailsLib.isCompliant(1e18, 1.5e18, GuardrailsLib.ONE_YEAR / 2, g);
        assertTrue(result, "50% increase over half-year (100% annualized) must be compliant");
    }

    /// @notice Kills arithmetic mutations in the DECREASE formula:
    ///   variation = (currentPps - nextPps) * scaleToOneYear * SCALE / currentPps
    ///
    /// Setup:
    ///   currentPps = 2e18, nextPps = 1e18, timePast = ONE_YEAR
    ///   → variation = (2e18 - 1e18) * 1 * 1e18 / 2e18 = 0.5e18  (50% per year)
    ///
    /// Guardrails: lowerRate = -0.5e18 (allow exactly 50% decrease).
    /// check: variation <= uint256(-lowerRate) → 0.5e18 <= 0.5e18 → true
    ///
    /// Kills: - → * (variation = 2e36, exceeds threshold → false),
    ///        / → - (huge → false), / → * (huge → false).
    function test_isCompliant_decreaseExactVariation_fullYear() public view {
        Guardrails memory g = Guardrails({upperRate: 0, lowerRate: -int256(0.5e18)});

        //   currentPps = 2e18 → nextPps = 1e18 → 50% decrease over ONE_YEAR
        bool result = GuardrailsLib.isCompliant(2e18, 1e18, GuardrailsLib.ONE_YEAR, g);
        assertTrue(result, "50% decrease over 1 year must be compliant with -50% lower bound");

        // Sanity: a slightly bigger decrease MUST fail.
        bool tooLow = GuardrailsLib.isCompliant(2e18, 1e18 - 1e15, GuardrailsLib.ONE_YEAR, g);
        assertFalse(tooLow, "50.1% decrease must violate the -50% lower bound");
    }

    //////////////////////////////////////////////////
    // ## updateNewTotalAssets nextPps arithmetic ## //
    //////////////////////////////////////////////////

    /// @notice Kills arithmetic mutants in Vault.updateNewTotalAssets's nextPps formula:
    ///   nextPps = oneShare.mulDiv(_newTotalAssets + 1, totalSupply() + 10 ** decimalsOffset, Floor)
    ///
    /// Strategy: set guardrails so tight that only the exact correct nextPps passes.
    /// If `+1 → *1` or `10** → 10%` mutate the formula, nextPps changes and the
    /// guardrails reject it with GuardrailsViolation.
    function test_updateNewTotalAssets_nextPpsMatchesGuardrails() public {
        enableWhitelist = false;
        setUpVault(0, 0, 0);

        // Seed user1 so the vault has a non-trivial totalSupply.
        dealAndApprove(user1.addr);
        uint256 amount = assetBalance(user1.addr);
        requestDeposit(amount, user1.addr);
        updateAndSettle(0);
        deposit(amount, user1.addr);

        // Settle again (same nav) so lastFeeTime is set and guardrails are checked.
        dealAndApprove(user1.addr);
        requestDeposit(1, user1.addr);
        updateAndSettle(amount);
        vm.warp(block.timestamp + 1);

        // Activate guardrails with bounds that allow exactly 0% variation.
        vm.prank(vault.securityCouncil());
        vault.updateActivated(true);
        vm.prank(vault.securityCouncil());
        vault.updateGuardrails(Guardrails({upperRate: 0, lowerRate: 0}));

        // updateNewTotalAssets with the SAME totalAssets → nextPps ≈ currentPps → 0% change → pass.
        uint256 currentTotalAssets = vault.totalAssets();
        vm.prank(vault.valuationManager());
        vault.updateNewTotalAssets(currentTotalAssets); // must not revert

        // Double the assets → nextPps ≈ 2x → must violate 0% guardrails.
        vm.warp(block.timestamp + 1 days);
        vm.prank(vault.safe());
        vault.expireTotalAssets();
        vm.prank(vault.valuationManager());
        vm.expectRevert(GuardrailsViolation.selector);
        vault.updateNewTotalAssets(currentTotalAssets * 2);
    }

    ///////////////////////
    // ## Test helpers ## //
    ///////////////////////

    function _enableSyncDeposit() internal {
        enableWhitelist = false;
        setUpVault(0, 0, 0);
        dealAndApprove(user1.addr);

        vm.prank(vault.safe());
        vault.updateTotalAssetsLifespan(1000);
        updateAndSettle(0);
        vm.warp(block.timestamp + 1);
    }
}
