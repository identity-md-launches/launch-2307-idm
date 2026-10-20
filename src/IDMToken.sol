// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title idm (IDM)
/// @notice A plain, fixed-supply ERC-20. The whole supply is minted once, in the constructor, to the
/// deployer (`msg.sender`). There is no owner, no minter, no pause, no blacklist, no tax and no
/// burn-on-transfer: after deployment the contract has no privileged party and no function that can
/// change the supply upward or move a holder's balance without that holder's approval.
/// @dev The Solidity name `IDMToken` is the launch's contract name (at most 32 characters). The
/// token's own `name()` is "idm" and its `symbol()` is "IDM". ERC-2612 `permit` is included so
/// holders can approve by signature; it is pure ERC-20 state, with no admin surface.
contract IDMToken is ERC20, ERC20Permit {
    /// @notice The token's name, as `name()` returns it.
    string public constant TOKEN_NAME = "idm";

    /// @notice The token's symbol, as `symbol()` returns it.
    string public constant TOKEN_SYMBOL = "IDM";

    /// @notice 1,000,000,000 whole tokens at 18 decimals: the only supply there will ever be.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    /// @notice Mints `TOTAL_SUPPLY` to the deployer. Takes no arguments and calls no other contract,
    /// so the launch factory can run it on an empty chain.
    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) ERC20Permit(TOKEN_NAME) {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
