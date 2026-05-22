// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "./VaultHelper.sol";
import "forge-std/Test.sol";

import {BaseTest} from "./Base.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract TestMint is BaseTest {
    function setUp() public {
        setUpVault(0, 0, 0);
        dealAndApproveAndWhitelist(user1.addr);
    }

    function test_mint() public {
        uint256 userBalance = assetBalance(user1.addr);
        uint256 requestId = requestDeposit(userBalance, user1.addr);
        updateAndSettle(0);
        assertEq(vault.maxDeposit(user1.addr), userBalance);

        uint256 claimableAssets = vault.claimableDepositRequest(0, user1.addr);
        uint256 assetsClaimed = mint(12 * 10 ** vault.decimalsOffset(), user1.addr);
        assertEq(vault.convertToAssets(12 * 10 ** vault.decimalsOffset(), requestId), assetsClaimed);
        assertEq(12 * 10 ** vault.decimalsOffset(), vault.balanceOf(user1.addr));
        uint256 claimableAssetsAfter = vault.claimableDepositRequest(0, user1.addr);
        assertEq(claimableAssetsAfter + assetsClaimed, claimableAssets);
        assertLt(claimableAssetsAfter, claimableAssets);
    }

    function test_mintAsOperator() public {
        whitelist(user2.addr);

        uint256 userBalance = assetBalance(user1.addr);

        requestDeposit(userBalance, user1.addr);
        updateAndSettle(0);
        vm.prank(user1.addr);
        vault.setOperator(user2.addr, true);
        assertEq(vault.maxDeposit(user1.addr), userBalance);
        uint256 claimableAssets = vault.claimableDepositRequest(0, user1.addr);
        uint256 assetsClaimed = mint(12 * 10 ** vault.decimalsOffset(), user1.addr, user2.addr, user1.addr);
        assertEq(12 * 10 ** vault.decimalsOffset(), vault.balanceOf(user1.addr));
        uint256 claimableAssetsAfter = vault.claimableDepositRequest(0, user1.addr);
        assertEq(claimableAssetsAfter + assetsClaimed, claimableAssets);
        assertLt(claimableAssetsAfter, claimableAssets);
    }

    function test_mint_revertIfNotOperator() public {
        vm.prank(user2.addr);
        vm.expectRevert(ERC7540InvalidOperator.selector);
        vault.mint(42, user1.addr, user1.addr);
    }

    function test_mint_revertIfRequestIdNotClaimable() public {
        uint256 userBalance = assetBalance(user1.addr);
        requestDeposit(userBalance, user1.addr);
        vm.prank(user1.addr);
        vm.expectRevert(RequestIdNotClaimable.selector);
        vault.mint(userBalance, user1.addr, user1.addr);
    }

    function test_mint_shouldRevertIfInvalidReceiver() public {
        uint256 userBalance = assetBalance(user1.addr);
        whitelist(address(0));
        requestDeposit(userBalance, user1.addr);
        updateAndSettle(0);
        assertEq(vault.maxDeposit(user1.addr), userBalance);

        uint256 totalSupplyBefore = vault.totalSupply();

        uint256 amountToMint = 12 * 10 ** vault.decimalsOffset();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(user1.addr);
        vault.mint(amountToMint, address(0));

        uint256 totalSupplyAfter = vault.totalSupply();
        assertEq(totalSupplyBefore, totalSupplyAfter, "supply before != supply after");
    }

    function test_mint_shouldTakeEntryFeesIntoConsideration() public {
        // we setup a vault with entry fees
        setUpVault({_protocolRate: 0, _managementRate: 0, _performanceRate: 0, _entryRate: 200, _exitRate: 0});

        dealAndApproveAndWhitelist(user3.addr);

        requestDeposit(2000, user3.addr);
        updateAndSettle(0);
        deposit(2000, user3.addr);

        dealAndApproveAndWhitelist(user1.addr);
        dealAndApproveAndWhitelist(user2.addr);

        requestDeposit(800, user1.addr);
        requestDeposit(1000, user2.addr);

        // we settle deposits with a pps != 1:1 to complexify the situation
        updateAndSettle(2001);

        uint256 user1MaxDeposit = vault.maxDeposit(user1.addr);
        uint256 user2MaxDeposit = vault.maxDeposit(user2.addr);
        uint256 user1MaxMint = vault.maxMint(user1.addr);
        uint256 user2MaxMint = vault.maxMint(user2.addr);

        assertEq(user1MaxDeposit, 800);
        assertEq(user2MaxDeposit, 1000);

        uint256 user1MaxDepositSharesEquivalent = vault.convertToShares(user1MaxDeposit);
        uint256 user2MaxDepositSharesEquivalent = vault.convertToShares(user2MaxDeposit);

        uint40 user1LastRequestId = vault.lastDepositRequestId(user1.addr);
        uint40 user2LastRequestId = vault.lastDepositRequestId(user2.addr);
        assertEq(
            vault.maxMint(user1.addr),
            user1MaxDepositSharesEquivalent
                - FeeLib.computeFee(
                    user1MaxDepositSharesEquivalent, vault.getSettlementEntryFeeRate(user1LastRequestId)
                )
        );
        assertEq(
            vault.maxMint(user2.addr),
            user2MaxDepositSharesEquivalent
                - FeeLib.computeFee(
                    user2MaxDepositSharesEquivalent, vault.getSettlementEntryFeeRate(user2LastRequestId)
                )
        );

        mint(user1MaxMint, user1.addr);
        mint(user2MaxMint, user2.addr);

        // they both have no more max deposit or mint
        assertEq(vault.maxMint(user1.addr), 0);
        assertEq(vault.maxMint(user2.addr), 0);
        assertEq(vault.maxDeposit(user1.addr), 0);
        assertEq(vault.maxDeposit(user2.addr), 0);

        // if all shares are claimed, the vault should have no balance
        // assertEq(vault.balanceOf(address(vault)), 0); // this fails because of 1 wei, is it bad?
    }

    function test_mint_shouldNotBeAffectedByEntryFeeUpdate() public {
        // we setup a vault with entry fees
        setUpVault({_protocolRate: 0, _managementRate: 0, _performanceRate: 0, _entryRate: 200, _exitRate: 0});

        dealAndApproveAndWhitelist(user3.addr);

        requestDeposit(2000, user3.addr);
        updateAndSettle(0);
        deposit(2000, user3.addr);

        dealAndApproveAndWhitelist(user1.addr);
        dealAndApproveAndWhitelist(user2.addr);

        requestDeposit(800, user1.addr);
        requestDeposit(1000, user2.addr);

        // we settle deposits with a pps != 1:1 to complexify the situation
        updateAndSettle(2001);

        vm.prank(vault.owner());

        vault.updateRates(Rates({managementRate: 0, performanceRate: 0, entryRate: 100, exitRate: 0, haircutRate: 0}));
        vm.warp(block.timestamp + rateUpdateCooldown + 1);

        uint256 user1MaxDeposit = vault.maxDeposit(user1.addr);
        uint256 user2MaxDeposit = vault.maxDeposit(user2.addr);
        uint256 user1MaxMint = vault.maxMint(user1.addr);
        uint256 user2MaxMint = vault.maxMint(user2.addr);

        assertEq(user1MaxDeposit, 800);
        assertEq(user2MaxDeposit, 1000);

        uint256 user1MaxDepositSharesEquivalent = vault.convertToShares(user1MaxDeposit);
        uint256 user2MaxDepositSharesEquivalent = vault.convertToShares(user2MaxDeposit);

        uint40 user1LastRequestId = vault.lastDepositRequestId(user1.addr);
        uint40 user2LastRequestId = vault.lastDepositRequestId(user2.addr);
        assertEq(
            vault.maxMint(user1.addr),
            user1MaxDepositSharesEquivalent
                - FeeLib.computeFee(
                    user1MaxDepositSharesEquivalent, vault.getSettlementEntryFeeRate(user1LastRequestId)
                )
        );
        assertEq(
            vault.maxMint(user2.addr),
            user2MaxDepositSharesEquivalent
                - FeeLib.computeFee(
                    user2MaxDepositSharesEquivalent, vault.getSettlementEntryFeeRate(user2LastRequestId)
                )
        );

        assertNotEq(
            vault.getSettlementEntryFeeRate(user1LastRequestId),
            vault.entryRate(),
            "entry fee rates should not be equal"
        );

        mint(user1MaxMint, user1.addr);
        mint(user2MaxMint, user2.addr);

        // they both have no more max deposit or mint
        assertEq(vault.maxMint(user1.addr), 0);
        assertEq(vault.maxMint(user2.addr), 0);
        assertEq(vault.maxDeposit(user1.addr), 0);
        assertEq(vault.maxDeposit(user2.addr), 0);

        // assertEq(vault.balanceOf(address(vault)), 0); // this fails because of 1 wei, is it bad?
    }

    /// @notice Mint counterpart of `test_entry_fees_consistency` in
    /// `Deposit.t.sol`. Exercises `_mint` under the same state used in
    /// the production-scale walkthrough — Alice claims via `mint` and
    /// the fee-reverse-on-shares algebra drains her pending bucket to
    /// the exact 13 WETH she requested, for the exact vault claim pool.
    ///
    /// Scenario (production-scale WETH vault):
    ///   underlying      = 18-dec mock     (decimalsOffset = 0)
    ///   entryRate       = 200 (2 %)
    ///   totalAssets pre = 10_000 WETH     (seed at PPS = 1)
    ///   totalSupply pre = 10_000 shares
    ///   newTotalAssets  = 11_000 WETH     (10 % yield at settle)
    ///   pendingAssets   = 13 WETH         (Alice)
    ///
    /// Expected `_mint(maxMint)` flow at exact wei precision:
    ///   grossShares = shares + computeFeeReverse(shares, 200)
    ///              = ceil(11_581_818_181_818_181_817 * 10_000 / 9_800)
    ///              = 11_818_181_818_181_818_181
    ///   assets     = ceil(grossShares * TTA / TTS)
    ///              = ceil(11_818_181_818_181_818_181 * 11 / 10)
    ///              = 13_000_000_000_000_000_000  (13 WETH exactly)
    function test_entry_fees_consistency_mint() public {
        _useMockUnderlying(18);
        setUpVault({_protocolRate: 0, _managementRate: 0, _performanceRate: 0, _entryRate: 200, _exitRate: 0});
        assertEq(vault.decimalsOffset(), 0, "offset must be 0 for 18-dec underlying");

        // Seed: user2 deposits 10_000 WETH at PPS = 1.
        dealAmountAndApproveAndWhitelist(user2.addr, 10_000 * 1e18);
        requestDeposit(10_000 * 1e18, user2.addr);
        updateAndSettle(0);
        deposit(10_000 * 1e18, user2.addr);

        // Epoch N: Alice requests 13 WETH; vault reports 10 % yield.
        dealAmountAndApproveAndWhitelist(user1.addr, 13 * 1e18);
        requestDeposit(13 * 1e18, user1.addr);
        updateAndSettle(11_000 * 1e18);

        uint256 expectedGross = 11_818_181_818_181_818_181;
        uint256 expectedFeeS = 236_363_636_363_636_364;
        uint256 expectedPool = expectedGross - expectedFeeS; // 11_581_818_181_818_181_817

        assertEq(vault.balanceOf(address(vault)), expectedPool, "settle: vault claim pool matches walkthrough");
        assertEq(vault.maxMint(user1.addr), expectedPool, "preview: maxMint = vault pool");
        assertEq(vault.claimableDepositRequest(0, user1.addr), 13 * 1e18, "pending: 13 WETH claimable");

        // Alice calls mint(maxMint). The BaseTest `mint` helper asserts
        // that the assets returned match
        //   convertToAssets(amount + computeFeeReverse(amount, rate), requestId, Ceil)
        // which is the post-fix `_mint` algebra.
        uint256 assetsPaid = mint(vault.maxMint(user1.addr), user1.addr);

        assertEq(assetsPaid, 13 * 1e18, "mint: Alice paid full 13 WETH");
        assertEq(vault.balanceOf(user1.addr), expectedPool, "mint: Alice got full pool");
        assertEq(vault.balanceOf(address(vault)), 0, "mint: vault self-balance fully drained");
        assertEq(vault.claimableDepositRequest(0, user1.addr), 0, "pending: request drained");
    }
}
