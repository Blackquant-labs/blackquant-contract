// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "../VaultHelper.sol";
import "forge-std/Test.sol";

import {BaseTest} from "../Base.sol";
import {MockSanctionsList} from "../mocks/MockSanctionsList.sol";
import {SanctionsList} from "@src/v0.6.0/interfaces/SanctionsList.sol";

/// @notice Kills the `externalListApproval = !isSanctioned(...)` mutant in
/// AccessableLib.isAllowed. If that line is replaced with `externalListApproval = false`,
/// these tests must fail: the sanctioned-status-dependent branch is exercised with
/// both values (sanctioned → not allowed, not sanctioned → allowed).
contract TestExternalSanctions is BaseTest {
    MockSanctionsList sanctions;

    function setUp() public {
        setUpVault(0, 0, 0);
        sanctions = new MockSanctionsList();

        vm.prank(vault.whitelistManager());
        vault.setExternalSanctionsList(SanctionsList(address(sanctions)));

        // Whitelist so the internal check alone would pass; the sanctions list is the
        // variable under test.
        whitelist(user1.addr);
    }

    function test_isAllowed_trueWhen_notSanctioned() public view {
        // not in the sanctions map and whitelisted -> allowed
        assertTrue(vault.isAllowed(user1.addr));
    }

    function test_isAllowed_falseWhen_sanctioned() public {
        sanctions.setSanctioned(user1.addr, true);
        assertFalse(vault.isAllowed(user1.addr));
    }

    /// @notice If the mutant `externalListApproval = false` is applied, this toggling
    /// test fails because un-sanctioning the user would no longer restore access.
    function test_isAllowed_tracksSanctionedToggles() public {
        assertTrue(vault.isAllowed(user1.addr));

        sanctions.setSanctioned(user1.addr, true);
        assertFalse(vault.isAllowed(user1.addr));

        sanctions.setSanctioned(user1.addr, false);
        assertTrue(vault.isAllowed(user1.addr));
    }

    /// @notice End-to-end: a sanctioned user cannot requestDeposit, even if whitelisted.
    function test_requestDeposit_revertsWhen_senderSanctioned() public {
        dealAndApprove(user1.addr);
        sanctions.setSanctioned(user1.addr, true);

        vm.prank(user1.addr);
        vm.expectRevert(abi.encodeWithSelector(AddressNotAllowed.selector, user1.addr));
        vault.requestDeposit(1e6, user1.addr, user1.addr);
    }
}
