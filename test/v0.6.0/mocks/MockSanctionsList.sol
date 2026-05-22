// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SanctionsList} from "@src/v0.6.0/interfaces/SanctionsList.sol";

/// @notice Minimal SanctionsList implementation for tests. Each address's sanctioned
/// status is toggled via `setSanctioned`; `isSanctioned` simply reads the mapping.
contract MockSanctionsList is SanctionsList {
    mapping(address => bool) private _sanctioned;

    function setSanctioned(
        address account,
        bool value
    ) external {
        _sanctioned[account] = value;
    }

    function isSanctioned(
        address account
    ) external view override returns (bool) {
        return _sanctioned[account];
    }
}
