// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "./VaultHelper.sol";
import "forge-std/Test.sol";

import {BaseTest} from "./Base.sol";
import {OptinProxyFactoryV3} from "@src/protocol-v3/OptinProxyFactory.sol";
import {AccessMode} from "@src/v0.6.0/primitives/Enums.sol";
import {InitStruct} from "@src/v0.6.0/vault/Vault-v0.6.0.sol";
import {VaultInit} from "@src/v0.6.0/vault/VaultInit.sol";

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @notice Targeted coverage for the VaultInit constructor/initialize and
/// OptinProxyFactory createVaultProxy/initialize side-effects flagged by
/// NM-0822.
contract TestInitFactory is BaseTest {
    function setUp() public {
        // Reuse the SetUp fixture: factory, protocolRegistry and users are all
        // deployed in the parent constructor.
        enableWhitelist = false;
        setUpVault(0, 0, 0);
    }

    //////////////////////////////////////
    // ## VaultInit constructor tests ## //
    //////////////////////////////////////

    /// @notice Kills `_disableInitializers()` → assert(true) mutant and the
    /// `if (disable)` → false mutant. When disable=true, further direct
    /// initialize() calls on the VaultInit instance must revert with
    /// InvalidInitialization.
    function test_vaultInit_constructorDisableTrueBlocksInitialize() public {
        VaultInit impl = new VaultInit(true);
        InitStruct memory init = _buildInitStruct();

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(abi.encode(init), address(protocolRegistry), WRAPPED_NATIVE_TOKEN);
    }

    /// @notice Kills `if (disable)` → true mutant (would always block init).
    /// With disable=false, a direct initialize call must succeed.
    function test_vaultInit_constructorDisableFalseAllowsInitialize() public {
        VaultInit impl = new VaultInit(false);
        InitStruct memory init = _buildInitStruct();

        // Should not revert.
        impl.initialize(abi.encode(init), address(protocolRegistry), WRAPPED_NATIVE_TOKEN);
    }

    ///////////////////////////////////////
    // ## VaultInit.initialize effects ## //
    ///////////////////////////////////////

    /// @notice Kills `__ERC20_init(init.name, init.symbol)` → assert(true)
    /// mutant. After initialize the vault must expose the exact name/symbol
    /// that were passed in.
    function test_vaultInit_initializeSetsNameAndSymbol() public {
        VaultHelper freshVault = new VaultHelper(false);
        InitStruct memory init = _buildInitStruct();
        init.name = "Lagoon Test Vault";
        init.symbol = "LTV";

        freshVault.initialize(abi.encode(init), address(protocolRegistry), WRAPPED_NATIVE_TOKEN);

        assertEq(freshVault.name(), "Lagoon Test Vault", "name must match init.name");
        assertEq(freshVault.symbol(), "LTV", "symbol must match init.symbol");
    }

    /// @notice Kills `__ERC20Pausable_init()` → assert(true) mutant. After
    /// initialize the vault must be in the unpaused state and the pause
    /// machinery must work (owner can pause and unpause without NotInitialized).
    function test_vaultInit_initializeLeavesVaultUnpausedAndPausable() public {
        VaultHelper freshVault = new VaultHelper(false);
        InitStruct memory init = _buildInitStruct();
        freshVault.initialize(abi.encode(init), address(protocolRegistry), WRAPPED_NATIVE_TOKEN);

        assertFalse(freshVault.paused(), "freshly initialized vault must be unpaused");

        vm.prank(freshVault.owner());
        freshVault.pause();
        assertTrue(freshVault.paused(), "owner must be able to pause after init");

        vm.prank(freshVault.owner());
        freshVault.unpause();
        assertFalse(freshVault.paused(), "owner must be able to unpause after init");
    }

    ////////////////////////////////////////
    // ## OptinProxyFactory.initialize ## //
    ////////////////////////////////////////

    /// @notice Kills `__Ownable_init(owner)` → assert(true), `$.REGISTRY = …`
    /// → assert(true), and `$.WRAPPED_NATIVE = …` → assert(true) mutants in
    /// OptinProxyFactory.initialize.
    function test_optinProxyFactory_initializeSetsStorage() public {
        OptinProxyFactoryV3 fresh = new OptinProxyFactoryV3(false);
        address ownerAddr = makeAddr("freshOwner");
        address registryAddr = makeAddr("freshRegistry");
        address wrappedAddr = makeAddr("freshWrapped");

        fresh.initialize(registryAddr, wrappedAddr, ownerAddr);

        assertEq(fresh.owner(), ownerAddr, "__Ownable_init must set owner");
        assertEq(fresh.registry(), registryAddr, "REGISTRY must be set");
        assertEq(fresh.wrappedNativeToken(), wrappedAddr, "WRAPPED_NATIVE must be set");
    }

    /// @notice Kills `$.isInstance[proxy] = true` → assert(true) mutant in
    /// OptinProxyFactory.createVaultProxy. After creating a proxy, the
    /// factory must report it as an instance.
    function test_optinProxyFactory_createVaultProxyMarksInstance() public {
        InitStruct memory init = _buildInitStruct();

        bytes memory call_data = abi.encodeWithSignature(
            "initialize(bytes,address,address)", abi.encode(init), factory.registry(), factory.wrappedNativeToken()
        );

        address proxy = factory.createVaultProxy({
            _logic: address(0),
            _initialOwner: init.admin,
            _initialDelay: 86_400,
            call_data: call_data,
            salt: keccak256("pr5")
        });

        assertTrue(factory.isInstance(proxy), "factory must mark created proxy as an instance");
    }

    /// @notice Complement of the above: a random address that was NOT created
    /// by the factory must NOT be reported as an instance. This pins down the
    /// positive branch — if the mutation sets the flag unconditionally somewhere
    /// else, or if the mapping is storing true for unrelated addresses, this fails.
    function test_optinProxyFactory_randomAddressIsNotInstance() public {
        assertFalse(factory.isInstance(makeAddr("random")), "random address must not be an instance");
        assertFalse(factory.isInstance(address(this)), "test contract must not be an instance");
    }

    ///////////////////////
    // ## Test helpers ## //
    ///////////////////////

    function _buildInitStruct() internal view returns (InitStruct memory) {
        return InitStruct({
            underlying: underlying,
            name: vaultName,
            symbol: vaultSymbol,
            safe: safe.addr,
            whitelistManager: whitelistManager.addr,
            valuationManager: valuationManager.addr,
            admin: admin.addr,
            feeReceiver: feeReceiver.addr,
            managementRate: 0,
            performanceRate: 0,
            accessMode: AccessMode.Blacklist,
            entryRate: 0,
            exitRate: 0,
            haircutRate: 0,
            securityCouncil: admin.addr,
            externalSanctionsList: address(0),
            initialTotalAssets: 0,
            superOperator: superOperator.addr,
            allowHighWaterMarkReset: false
        });
    }
}
