// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "./VaultHelper.sol";
import "forge-std/Test.sol";

import {BaseTest} from "./Base.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract TestDeposit is BaseTest {
    function setUp() public {
        setUpVault(0, 0, 0);
        dealAndApproveAndWhitelist(user1.addr);
    }

    function test_deposit() public {
        uint256 userBalance = assetBalance(user1.addr);
        uint256 requestId = requestDeposit(userBalance, user1.addr);
        updateAndSettle(0);
        assertEq(vault.maxDeposit(user1.addr), userBalance);
        uint256 shares = deposit(userBalance, user1.addr);
        assertEq(vault.convertToShares(userBalance, requestId), shares);
        assertEq(shares, vault.balanceOf(user1.addr));
        assertEq(shares, userBalance * 10 ** vault.decimalsOffset());
    }

    function test_deposit_revertIfNotOperator() public {
        vm.prank(user2.addr);
        vm.expectRevert(ERC7540InvalidOperator.selector);
        vault.deposit(42, user1.addr, user1.addr);
    }

    function test_deposit_revertIfRequestIdNotClaimable() public {
        uint256 userBalance = assetBalance(user1.addr);
        requestDeposit(userBalance, user1.addr);
        vm.prank(user1.addr);
        vm.expectRevert(RequestIdNotClaimable.selector);
        vault.deposit(userBalance, user1.addr, user1.addr);
    }

    function test_deposit_shouldRevertIfInvalidReceiver() public {
        whitelist(address(0));
        uint256 userBalance = assetBalance(user1.addr);
        requestDeposit(userBalance, user1.addr);
        updateAndSettle(0);
        assertEq(vault.maxDeposit(user1.addr), userBalance);
        uint256 totalSupplyBefore = vault.totalSupply();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(user1.addr);
        vault.deposit(userBalance, address(0));
        uint256 totalSupplyAfter = vault.totalSupply();
        assertEq(totalSupplyBefore, totalSupplyAfter, "supply before != supply after");
    }

    function test_deposit_shouldTakeEntryFeesIntoConsideration() public {
        // we setup a vault with entry fees
        setUpVault({_protocolRate: 0, _managementRate: 0, _performanceRate: 0, _entryRate: 200, _exitRate: 0});

        dealAndApproveAndWhitelist(user3.addr);

        requestDeposit(2000, user3.addr);
        updateAndSettle(0);
        deposit(2000, user3.addr);
        assertEq(vault.balanceOf(address(vault)), 0, "vault balance should be 0");

        dealAndApproveAndWhitelist(user1.addr);
        dealAndApproveAndWhitelist(user2.addr);

        requestDeposit(800, user1.addr);
        requestDeposit(1000, user2.addr);

        // we settle deposits with a pps != 1:1 to complexify the situation
        updateAndSettle(2001);

        uint256 user1MaxDeposit = vault.maxDeposit(user1.addr);
        uint256 user2MaxDeposit = vault.maxDeposit(user2.addr);

        assertEq(user1MaxDeposit, 800);
        assertEq(user2MaxDeposit, 1000);

        uint256 user1MaxDepositSharesEquivalent = vault.convertToShares(user1MaxDeposit);
        uint256 user2MaxDepositSharesEquivalent = vault.convertToShares(user2MaxDeposit);
        uint16 user1LastRequestIdRate = vault.getSettlementEntryFeeRate(vault.lastDepositRequestId(user1.addr));
        uint16 user2LastRequestIdRate = vault.getSettlementEntryFeeRate(vault.lastDepositRequestId(user2.addr));

        assertEq(
            vault.maxMint(user1.addr),
            user1MaxDepositSharesEquivalent - FeeLib.computeFee(user1MaxDepositSharesEquivalent, user1LastRequestIdRate)
        );
        assertEq(
            vault.maxMint(user2.addr),
            user2MaxDepositSharesEquivalent - FeeLib.computeFee(user2MaxDepositSharesEquivalent, user2LastRequestIdRate)
        );

        deposit(user1MaxDeposit, user1.addr);
        deposit(user2MaxDeposit, user2.addr);

        // they both have no more max deposit or mint
        assertEq(vault.maxMint(user1.addr), 0);
        assertEq(vault.maxMint(user2.addr), 0);
        assertEq(vault.maxDeposit(user1.addr), 0);
        assertEq(vault.maxDeposit(user2.addr), 0);

        // if all shares are claimed, the vault should have no balance
        // assertEq(vault.balanceOf(address(vault)), 0); // this fails because of 1 wei, is it bad?
    }

    /// @notice Regression test for the deposit-side entry-fee rounding bug:
    /// `settleDeposit` ceils the fee on SHARES while the pre-fix `_deposit`
    /// ceiled on ASSETS, so the two paths disagreed by rounding and a
    /// legitimate claim of `maxDeposit` reverted with
    /// `ERC20InsufficientBalance`. The fix in `ERC7540Lib._deposit` and
    /// `_mint` mirrors the settle algebra.
    ///
    /// Scenario (production-scale WETH vault):
    ///   underlying      = 18-dec mock     (decimalsOffset = 0)
    ///   entryRate       = 200 (2 %)
    ///   totalAssets pre = 10_000 WETH     (seed at PPS = 1)
    ///   totalSupply pre = 10_000 shares
    ///   newTotalAssets  = 11_000 WETH     (10 % yield at settle)
    ///   pendingAssets   = 13 WETH         (Alice)
    ///
    /// Expected settle arithmetic at exact wei precision:
    ///   shares_bucket         = floor(13e18 * 10 / 11) = 11_818_181_818_181_818_181
    ///   entryFeeShares_bucket = ceil(shares * 200/1e4) =    236_363_636_363_636_364
    ///   vault claim pool      = shares - fee           = 11_581_818_181_818_181_817
    function test_entry_fees_consistency() public {
        _useMockUnderlying(18);
        setUpVault({_protocolRate: 0, _managementRate: 0, _performanceRate: 0, _entryRate: 200, _exitRate: 0});
        assertEq(vault.decimalsOffset(), 0, "offset must be 0 for 18-dec underlying");

        // ------------------------------------------------------------
        // Seed — user2 deposits 10_000 WETH at PPS = 1.
        //   shares_bucket  = 10_000e18
        //   feeS_bucket    = ceil(10_000e18 * 200 / 10_000) = 200e18
        //   vault pool     = 9_800e18        → transferred to user2 on claim
        //   feeReceiver   += 200e18
        //   totalSupply    = 10_000e18      (user2 + feeReceiver)
        //   totalAssets    = 10_000e18
        // ------------------------------------------------------------
        dealAmountAndApproveAndWhitelist(user2.addr, 10_000 * 1e18);
        requestDeposit(10_000 * 1e18, user2.addr);
        updateAndSettle(0);
        deposit(10_000 * 1e18, user2.addr);

        assertEq(vault.totalAssets(), 10_000 * 1e18, "seed: totalAssets = 10_000 WETH");
        assertEq(vault.totalSupply(), 10_000 * 1e18, "seed: totalSupply = 10_000 shares");
        assertEq(vault.balanceOf(address(vault)), 0, "seed: vault self-balance drained");
        assertEq(vault.balanceOf(user2.addr), 9800 * 1e18, "seed: user2 got 9_800 shares");
        assertEq(vault.balanceOf(feeReceiver.addr), 200 * 1e18, "seed: feeReceiver got 200 shares");

        // ------------------------------------------------------------
        // Epoch N — Alice requests 13 WETH; vault reports 10 % yield.
        // ------------------------------------------------------------
        dealAmountAndApproveAndWhitelist(user1.addr, 13 * 1e18);
        requestDeposit(13 * 1e18, user1.addr);
        updateAndSettle(11_000 * 1e18);

        uint256 expectedGross = 11_818_181_818_181_818_181;
        uint256 expectedFeeS = 236_363_636_363_636_364;
        uint256 expectedPool = expectedGross - expectedFeeS; // 11_581_818_181_818_181_817

        assertEq(vault.balanceOf(address(vault)), expectedPool, "settle: vault claim pool matches walkthrough");
        assertEq(vault.maxDeposit(user1.addr), 13 * 1e18, "preview: maxDeposit = 13 WETH");
        assertEq(vault.maxMint(user1.addr), expectedPool, "preview: maxMint = vault pool");

        // ------------------------------------------------------------
        // Alice claims her full maxDeposit — post-fix succeeds and
        // drains the vault's claim pool exactly.
        // ------------------------------------------------------------
        uint256 claim = vault.maxDeposit(user1.addr);
        uint256 aliceBefore = vault.balanceOf(user1.addr);
        uint256 vaultBefore = vault.balanceOf(address(vault));

        vm.prank(user1.addr);
        uint256 shares = vault.deposit(claim, user1.addr);

        assertEq(shares, expectedPool, "claim: returned shares = expected pool");
        assertEq(vault.balanceOf(user1.addr) - aliceBefore, expectedPool, "claim: Alice received expected pool");
        assertEq(vaultBefore - vault.balanceOf(address(vault)), expectedPool, "claim: vault transferred full pool");
        assertEq(vault.balanceOf(address(vault)), 0, "claim: vault self-balance fully drained");
    }
}
