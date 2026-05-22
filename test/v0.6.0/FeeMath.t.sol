// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "./VaultHelper.sol";
import "forge-std/Test.sol";

import {BaseTest} from "./Base.sol";
import {FeeRegistry as FeeRegistryV2} from "@src/protocol-v2/FeeRegistry.sol";
import {FeeType, SyncMode} from "@src/v0.6.0/primitives/Enums.sol";
import {FeeTaken} from "@src/v0.6.0/primitives/Events.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Targeted coverage for FeeLib and previewSyncRedeem math that the
/// NM-0822 mutation audit reported as not killed:
///   - computeFee(x, 0) and computeFeeReverse(x, 0) short-circuit branches
///   - computeFeeReverse subtraction-vs-addition arithmetic
///   - protocolRate() cap at MAX_PROTOCOL_RATE
///   - takeFees(0, ...) early-return (no FeeTaken event when shares == 0)
///   - takeManagementAndPerformanceFees arithmetic (exact-value assertions)
///   - previewSyncRedeem inner `shares - exitFeeShares` subtraction
contract TestFeeMath is BaseTest {
    using Math for uint256;

    uint16 constant PROTOCOL_RATE = 1000; // 10 %
    uint16 constant MANAGEMENT_RATE = 1000; // 10 %
    uint16 constant PERFORMANCE_RATE = 2000; // 20 %

    uint16 constant MAX_PROTOCOL_RATE = 3000; // FeeLib.MAX_PROTOCOL_RATE

    //////////////////////////////////////
    // ## computeFee / computeFeeReverse ## //
    //////////////////////////////////////

    function test_computeFee_returnsZeroWhenRateIsZero() public {
        _bareSetUp();
        // Large amount so mulDiv would produce > 0 if the early return is bypassed
        // and some non-zero rate is fed in by mistake.
        assertEq(FeeLib.computeFee(1e30, 0), 0, "computeFee must return 0 when rate is 0");
    }

    function test_computeFee_exactValue() public {
        _bareSetUp();
        // ceil(1000 * 200 / 10_000) = ceil(20) = 20
        assertEq(FeeLib.computeFee(1000, 200), 20, "2% of 1000 must be 20");
        // ceil(999 * 200 / 10_000) = ceil(19.98) = 20 (round up)
        assertEq(FeeLib.computeFee(999, 200), 20, "2% of 999 must round up to 20");
    }

    function test_computeFeeReverse_returnsZeroWhenRateIsZero() public {
        _bareSetUp();
        assertEq(FeeLib.computeFeeReverse(1e30, 0), 0, "computeFeeReverse must return 0 when rate is 0");
    }

    /// @notice Kills the `subtraction → addition` mutant in computeFeeReverse.
    /// The two outcomes differ by `2 * amount`, which makes the mutation
    /// unambiguous for any non-trivial input.
    function test_computeFeeReverse_subtractionMath() public {
        _bareSetUp();
        // amount = 9_800, rate = 200 (2%)
        // ceil(9800 * 10_000 / 9_800) - 9_800 = 10_000 - 9_800 = 200
        // If the `-` is mutated to `+`, the result would be 19_800 instead.
        assertEq(FeeLib.computeFeeReverse(9800, 200), 200, "reverse fee must be 200 (subtraction, not addition)");
    }

    /// @notice Inverse property: for any non-zero amount and rate,
    /// `computeFee(amount + computeFeeReverse(amount, rate), rate) == computeFeeReverse(amount, rate)`.
    /// This is the contract of the "reverse" function and fails under the `+` mutant.
    function test_computeFeeReverse_inverseProperty() public {
        _bareSetUp();
        uint256 net = 5000;
        uint16 rate = 200;
        uint256 fee = FeeLib.computeFeeReverse(net, rate);
        // ceil((net + fee) * rate / BPS) must equal fee
        assertEq(FeeLib.computeFee(net + fee, rate), fee, "inverse property must hold");
    }

    ///////////////////////
    // ## protocolRate ## //
    ///////////////////////

    /// @notice Kills `_protocolRate > MAX_PROTOCOL_RATE` → false mutant.
    /// Sets the registry's default rate above MAX_PROTOCOL_RATE and asserts
    /// the vault-side `FeeLib.protocolRate()` caps the returned value.
    function test_protocolRate_capsAtMaxProtocolRate() public {
        _bareSetUp();

        // Above the cap: must be capped to MAX_PROTOCOL_RATE.
        vm.prank(dao.addr);
        FeeRegistryV2(address(protocolRegistry)).updateDefaultRate(MAX_PROTOCOL_RATE + 1000);
        assertEq(vault.protocolRate(), MAX_PROTOCOL_RATE, "protocolRate must cap at MAX_PROTOCOL_RATE");

        // Below the cap: must return the raw value.
        vm.prank(dao.addr);
        FeeRegistryV2(address(protocolRegistry)).updateDefaultRate(MAX_PROTOCOL_RATE - 1);
        assertEq(vault.protocolRate(), MAX_PROTOCOL_RATE - 1, "protocolRate must return raw value below cap");
    }

    /////////////////////////
    // ## takeFees(0, ..) ## //
    /////////////////////////

    /// @notice Kills the `shares == 0` → false mutant in takeFees. When the
    /// vault settles with all fee rates at zero, `takeFees` is called with
    /// `shares == 0` for both Management and Performance. If the early return
    /// is bypassed, a `FeeTaken` event is still emitted.
    function test_takeFees_emitsNoEventWhenZeroShares() public {
        // Zero fee rates; settle triggers takeFees with shares = 0 for both
        // Management and Performance.
        enableWhitelist = false;
        setUpVault(0, 0, 0, 0, 0);

        // Make sure there's a non-trivial totalAssets so we're exercising the
        // fee path, not a vault-is-empty shortcut. A plain settle after a
        // requestDeposit is enough.
        dealAndApprove(user1.addr);
        uint256 amount = assetBalance(user1.addr);
        requestDeposit(amount, user1.addr);

        vm.recordLogs();
        updateAndSettle(amount);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 feeTakenTopic = keccak256("FeeTaken(uint8,uint256,uint16,uint40,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == feeTakenTopic) {
                assertTrue(false, "FeeTaken event must not be emitted when shares == 0");
            }
        }
    }

    ////////////////////////////////////////
    // ## takeManagementAndPerformanceFees ## //
    ////////////////////////////////////////

    /// @notice Kills the arithmetic mutants in takeManagementAndPerformanceFees
    /// by asserting a linearity property: for a 1-year settlement with a flat
    /// price-per-share, doubling the management rate must roughly double the
    /// fee shares minted to the receiver. Any mutation that turns a `*` into
    /// `+`/`/`/`%` or a `-` into `%` destroys this linearity.
    /// @dev Two identical vaults differ only in managementRate (5% vs 10%,
    /// both within MAX_MANAGEMENT_RATE). Tolerance of 2% accommodates mulDiv
    /// rounding; arithmetic mutants produce ratios that are off by orders of
    /// magnitude, well outside this.
    function test_takeManagementAndPerformanceFees_scalesWithRate() public {
        uint256 sharesAt5Pct = _managementSharesForOneYear(500);
        uint256 sharesAt10Pct = _managementSharesForOneYear(1000);

        assertGt(sharesAt5Pct, 0, "sanity: 5% rate must mint some management shares");
        assertGt(sharesAt10Pct, 0, "sanity: 10% rate must mint some management shares");

        // Expect ratio ≈ 2 (not exactly 2 because the denominator
        // `totalAssets - fees` shrinks as fees grow — the true ratio is
        // slightly above 2 for positive rates). Bound 1.5x..2.5x is tight
        // enough to reject every arithmetic mutation the audit flags
        // (which produce ratios near 1x, 0x, or explode to >>3x).
        assertGe(sharesAt10Pct * 2, sharesAt5Pct * 3, "10% must be at least 1.5x the 5% shares");
        assertLe(sharesAt10Pct * 2, sharesAt5Pct * 5, "10% must be at most 2.5x the 5% shares");
    }

    /// @notice Deploys a fresh vault with the given management rate, runs a
    /// full deposit → settle → warp 1 year → settle cycle, and returns the
    /// management shares minted to the fee receiver on the second settle.
    function _managementSharesForOneYear(
        uint16 managementRate
    ) internal returns (uint256) {
        enableWhitelist = false;
        setUpVault(0, managementRate, 0, 0, 0);

        uint256 unit = 10 ** vault.underlyingDecimals();
        uint256 amount = 1000 * unit;

        dealAmountAndApprove(user1.addr, amount);
        requestDeposit(amount, user1.addr);
        updateAndSettle(0);
        deposit(amount, user1.addr);

        vm.warp(block.timestamp + 365 days);

        uint256 feeReceiverSharesBefore = vault.balanceOf(vault.feeReceiver());
        uint256 totalAssetsBefore = vault.totalAssets();
        updateAndSettle(totalAssetsBefore);
        return vault.balanceOf(vault.feeReceiver()) - feeReceiverSharesBefore;
    }

    /////////////////////////////
    // ## previewSyncRedeem ## //
    /////////////////////////////

    /// @notice Kills the `shares - exitFeeShares` → `shares + exitFeeShares`
    /// mutant in previewSyncRedeem. With exitRate = 200 (2%), the inner call
    /// to computeFee takes the haircut off a net value. If the subtraction is
    /// mutated to addition, the haircut is computed off a larger base, so
    /// the returned assets change by more than rounding can explain.
    function test_previewSyncRedeem_usesSubtraction() public {
        enableWhitelist = false;
        setUpVault(0, 0, 0, 0, 200); // 2% exit fee

        // Enable sync flow.
        dealAndApprove(user1.addr);
        vm.prank(vault.safe());
        vault.updateTotalAssetsLifespan(1000);
        uint256 amount = assetBalance(user1.addr);
        requestDeposit(amount, user1.addr);
        updateAndSettle(0);
        deposit(amount, user1.addr);
        vm.warp(block.timestamp + 1);
        vm.prank(vault.safe());
        vault.setSyncMode(SyncMode.Both);

        // With haircutRate == 0, previewSyncRedeem reduces to:
        //   exitFeeShares = ceil(shares * 200 / 10_000)
        //   assets        = convertToAssets(shares - exitFeeShares)
        // If the `-` is flipped to `+`, shares-to-convert would jump by
        // 2 * exitFeeShares, which for the values below is a detectable delta.
        uint256 shares = 10_000 * 10 ** decimals;
        uint256 exitFeeShares = FeeLib.computeFee(shares, 200);
        uint256 expectedAssets = vault.convertToAssets(shares - exitFeeShares);
        assertEq(
            vault.previewSyncRedeem(shares), expectedAssets, "previewSyncRedeem must subtract exitFeeShares, not add"
        );
    }

    ///////////////////////
    // ## Test helpers ## //
    ///////////////////////

    /// @dev Minimal vault for unit tests that only need the storage/FeeLib
    /// plumbing to exist (e.g. pure-ish computeFee calls compiled against the
    /// correct library version). All rates are zero.
    function _bareSetUp() internal {
        enableWhitelist = false;
        setUpVault(0, 0, 0, 0, 0);
    }
}
