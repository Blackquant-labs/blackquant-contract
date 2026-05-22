// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "./VaultHelper.sol";
import "forge-std/Test.sol";

import {BaseTest} from "./Base.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWETH9} from "@src/v0.6.0/interfaces/IWETH9.sol";
import {AccessMode, SyncMode} from "@src/v0.6.0/primitives/Enums.sol";
import {DepositSync, Referral} from "@src/v0.6.0/primitives/Events.sol";
import {InitStruct} from "@src/v0.6.0/vault/Vault-v0.6.0.sol";

/// @notice End-to-end coverage for the native-ETH deposit path. Kills the
/// NM-0822 mutants on Silo.depositEth and Vault.syncDeposit's WETH wrapping /
/// safeTransferFrom / assets = msg.value assignment. These tests deploy a
/// vault whose underlying is WETH regardless of the ASSET env var, so the
/// ETH path is always exercised.
contract TestNativeEthFlow is BaseTest {
    IWETH9 weth;

    uint16 constant ENTRY_FEE_RATE = 0;

    function setUp() public {
        weth = IWETH9(WRAPPED_NATIVE_TOKEN);
        _setUpWethVault(ENTRY_FEE_RATE, 0);

        // Give user1 plenty of ETH; WETH balance is obtained via syncDeposit.
        vm.deal(user1.addr, 1000 ether);
        whitelist(user1.addr);

        // Enable the synchronous deposit flow.
        vm.prank(vault.safe());
        vault.updateTotalAssetsLifespan(1000);
        updateAndSettle(0);
        vm.warp(block.timestamp + 1);
    }

    ////////////////////////////////////
    // ## Silo.depositEth unit test ## //
    ////////////////////////////////////

    /// @notice Kills `IWETH9(wrappedNativeToken).deposit{value: msg.value}()` →
    /// assert(true) mutant in Silo.depositEth. A standalone Silo is deployed
    /// with WETH; after calling depositEth with msg.value the Silo must hold
    /// that exact amount of WETH and have zero raw ETH balance.
    function test_silo_depositEth_wrapsMsgValueIntoWETH() public {
        Silo silo = new Silo(IERC20(address(weth)), address(weth));

        uint256 ethAmount = 3.5 ether;
        vm.deal(address(this), ethAmount);

        silo.depositEth{value: ethAmount}();

        assertEq(weth.balanceOf(address(silo)), ethAmount, "silo WETH balance must equal msg.value");
        assertEq(address(silo).balance, 0, "silo must not hold raw ETH after wrapping");
    }

    //////////////////////////////////////////
    // ## Vault.syncDeposit ETH-path tests ## //
    //////////////////////////////////////////

    /// @notice Kills the `$.pendingSilo.depositEth{value: assets}()` and
    /// `safeTransferFrom(pendingSilo, safe, assets)` mutants in Vault.syncDeposit.
    /// If either is turned into a no-op, the safe's WETH balance will not
    /// increase by `assets` and the test fails.
    function test_syncDeposit_ethPath_movesWethToSafe() public {
        uint256 ethAmount = 5 ether;

        uint256 safeWethBefore = weth.balanceOf(vault.safe());
        uint256 pendingSiloWethBefore = weth.balanceOf(vault.pendingSilo());
        uint256 safeEthBefore = vault.safe().balance;
        uint256 user1EthBefore = user1.addr.balance;

        vm.prank(user1.addr);
        uint256 shares = vault.syncDeposit{value: ethAmount}(0, user1.addr, address(0));

        // Safe actually received the wrapped amount.
        assertEq(
            weth.balanceOf(vault.safe()), safeWethBefore + ethAmount, "safe WETH balance must increase by msg.value"
        );
        // Pending silo is a pure relay: its WETH balance must be unchanged.
        assertEq(
            weth.balanceOf(vault.pendingSilo()),
            pendingSiloWethBefore,
            "pending silo WETH balance must be unchanged (relay)"
        );
        // Safe never receives raw ETH in this path.
        assertEq(vault.safe().balance, safeEthBefore, "safe raw ETH balance must be unchanged");
        // User paid exactly msg.value in ETH.
        assertEq(user1.addr.balance, user1EthBefore - ethAmount, "user ETH must decrease by exactly msg.value");
        // User received the expected shares.
        assertEq(vault.balanceOf(user1.addr), shares, "user must hold the minted shares");
        assertGt(shares, 0, "shares must be > 0");
    }

    /// @notice Kills the `assets = msg.value` → `assets = 1`/`assets = 0`/
    /// `assert(true)` mutants in Vault.syncDeposit. By calling with a large
    /// msg.value and the `assets` argument set to 0, we force the function
    /// to re-assign `assets` from `msg.value`. If the assignment is mutated
    /// away, the derived `shares` count will be wrong (either 0 or based on 1 wei).
    function test_syncDeposit_ethPath_assetsEqualsMsgValue() public {
        uint256 ethAmount = 2 ether;

        // previewSyncDeposit is based on the *actual* assets that will land in
        // the vault. With a 1:1 PPS and 0 entry fee, shares == ethAmount.
        uint256 expectedShares = vault.previewSyncDeposit(ethAmount);
        assertEq(expectedShares, ethAmount, "sanity: 1:1 PPS and no entry fee");

        vm.prank(user1.addr);
        // We intentionally pass `assets = 0` so that a mutation such as
        // `assets = 1` or `assets = 0` (no-op) is detectable via the shares count.
        uint256 shares = vault.syncDeposit{value: ethAmount}(0, user1.addr, address(0));

        assertEq(shares, expectedShares, "shares must be derived from msg.value, not the assets argument");
        assertEq(vault.balanceOf(user1.addr), expectedShares, "user must receive exactly previewSyncDeposit shares");
    }

    ///////////////////////
    // ## Test helpers ## //
    ///////////////////////

    /// @dev Deploy and initialize a VaultHelper with WETH as the underlying.
    /// Mirrors SetUp.setUpVault but hard-codes the underlying so the test is
    /// independent of the ASSET env var.
    function _setUpWethVault(
        uint16 _entryRate,
        uint16 _exitRate
    ) internal {
        vm.prank(dao.addr);
        protocolRegistry.updateDefaultRate(0);

        InitStruct memory initStruct = InitStruct({
            underlying: IERC20(address(weth)),
            name: "weth_vault",
            symbol: "WETHV",
            safe: safe.addr,
            whitelistManager: whitelistManager.addr,
            valuationManager: valuationManager.addr,
            admin: admin.addr,
            feeReceiver: feeReceiver.addr,
            managementRate: 0,
            performanceRate: 0,
            accessMode: AccessMode.Whitelist,
            entryRate: _entryRate,
            exitRate: _exitRate,
            haircutRate: 0,
            securityCouncil: admin.addr,
            externalSanctionsList: address(0),
            initialTotalAssets: 0,
            superOperator: superOperator.addr,
            allowHighWaterMarkReset: false
        });

        vault = VaultHelper(new VaultHelper(false));
        vault.initialize(abi.encode(initStruct), address(protocolRegistry), WRAPPED_NATIVE_TOKEN);

        decimals = vault.decimals();
        underlyingDecimals = ERC20(address(weth)).decimals();

        address[] memory wl = new address[](5);
        wl[0] = feeReceiver.addr;
        wl[1] = dao.addr;
        wl[2] = safe.addr;
        wl[3] = vault.pendingSilo();
        wl[4] = address(protocolRegistry);
        vm.prank(whitelistManager.addr);
        vault.addToWhitelist(wl);

        vm.label(address(vault), "weth_vault");
    }
}
