// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IDMToken} from "../src/IDMToken.sol";

/// @notice Drives the token with bounded random calls from a fixed set of actors and keeps an
/// independent ledger (balances, allowances, nonces) that the invariants compare the token against.
/// Calls that must fail are tried too, and the handler checks they fail and leave state untouched.
contract IDMTokenHandler is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    IDMToken public immutable token;
    address[] public actors;
    uint256[] internal keys;

    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;
    mapping(address => uint256) public ghostNonce;

    uint256 public calls;
    uint256 public successfulMoves;
    uint256 public expectedFailures;

    constructor() {
        for (uint256 i; i < 5; ++i) {
            uint256 key = uint256(keccak256(abi.encode("idm-actor", i))) % (type(uint128).max) + 1;
            keys.push(key);
            actors.push(vm.addr(key));
        }
        // The first actor deploys, so it holds the whole supply exactly as the factory will.
        vm.prank(actors[0]);
        token = new IDMToken();
        ghostBalance[actors[0]] = SUPPLY;
        // The token's own address is a legal recipient: tokens sent there are part of the supply too.
        actors.push(address(token));
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev Only the keyed actors can sign or send; the token address only receives.
    function _signer(uint256 seed) internal view returns (address who, uint256 key) {
        uint256 i = seed % keys.length;
        return (actors[i], keys[i]);
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        ++calls;
        (address from,) = _signer(fromSeed);
        address to = _actor(toSeed);
        uint256 held = ghostBalance[from];
        amount = bound(amount, 0, held);

        vm.prank(from);
        assertTrue(token.transfer(to, amount), "transfer returned false");
        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        ++successfulMoves;
    }

    function transferTooMuch(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        ++calls;
        (address from,) = _signer(fromSeed);
        address to = _actor(toSeed);
        uint256 held = ghostBalance[from];
        uint256 amount = held + bound(excess, 1, SUPPLY);

        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount));
        token.transfer(to, amount);
        ++expectedFailures;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        ++calls;
        (address owner,) = _signer(ownerSeed);
        address spender = _actor(spenderSeed);
        // Half the time an infinite approval, which transferFrom must never reduce.
        amount = amount % 2 == 0 ? type(uint256).max : bound(amount, 0, SUPPLY);

        vm.prank(owner);
        assertTrue(token.approve(spender, amount), "approve returned false");
        ghostAllowance[owner][spender] = amount;
    }

    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) external {
        ++calls;
        (address spender,) = _signer(spenderSeed);
        (address owner,) = _signer(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = ghostAllowance[owner][spender];
        uint256 held = ghostBalance[owner];
        uint256 cap = allowed < held ? allowed : held;
        amount = bound(amount, 0, cap);

        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount), "transferFrom returned false");
        if (allowed != type(uint256).max) ghostAllowance[owner][spender] = allowed - amount;
        ghostBalance[owner] -= amount;
        ghostBalance[to] += amount;
        ++successfulMoves;
    }

    function transferFromBeyondAllowance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 excess)
        external
    {
        ++calls;
        (address spender,) = _signer(spenderSeed);
        (address owner,) = _signer(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = ghostAllowance[owner][spender];
        // An allowance near the maximum (from permit) leaves no room above it to ask for.
        if (allowed > type(uint256).max - SUPPLY) return;
        uint256 amount = allowed + bound(excess, 1, SUPPLY);

        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
        );
        token.transferFrom(owner, to, amount);
        ++expectedFailures;
    }

    function permit(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, uint256 ttl) external {
        ++calls;
        (address owner, uint256 key) = _signer(ownerSeed);
        address spender = _actor(spenderSeed);
        amount = bound(amount, 0, type(uint256).max);
        uint256 deadline = block.timestamp + bound(ttl, 0, 365 days);
        uint256 nonce = ghostNonce[owner];
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                token.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, amount, nonce, deadline))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);

        token.permit(owner, spender, amount, deadline, v, r, s);
        ghostAllowance[owner][spender] = amount;
        ghostNonce[owner] = nonce + 1;

        // The same signature never works twice.
        vm.expectRevert();
        token.permit(owner, spender, amount, deadline, v, r, s);
        ++expectedFailures;
    }

    function warp(uint256 seconds_) external {
        ++calls;
        vm.warp(block.timestamp + bound(seconds_, 0, 30 days));
    }
}

contract IDMTokenInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    IDMTokenHandler internal handler;
    IDMToken internal token;

    function setUp() public {
        handler = new IDMTokenHandler();
        token = handler.token();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = IDMTokenHandler.transfer.selector;
        selectors[1] = IDMTokenHandler.transferTooMuch.selector;
        selectors[2] = IDMTokenHandler.approve.selector;
        selectors[3] = IDMTokenHandler.transferFrom.selector;
        selectors[4] = IDMTokenHandler.transferFromBeyondAllowance.selector;
        selectors[5] = IDMTokenHandler.permit.selector;
        selectors[6] = IDMTokenHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_supplyNeverChanges() public view {
        assertEq(token.totalSupply(), SUPPLY, "the fixed supply changed");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_balancesSumToSupply() public view {
        uint256 sum;
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, token.totalSupply(), "balances do not add up to the supply");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_balancesMatchTheLedger() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address who = handler.actors(i);
            assertEq(token.balanceOf(who), handler.ghostBalance(who), "a balance moved without its owner's say");
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_allowancesAndNoncesMatchTheLedger() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address owner = handler.actors(i);
            assertEq(token.nonces(owner), handler.ghostNonce(owner), "a nonce moved without a permit");
            for (uint256 j; j < n; ++j) {
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.ghostAllowance(owner, spender), "allowance drifted");
            }
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_tokenHoldsNoEther() public view {
        assertEq(address(token).balance, 0, "the token holds ether");
    }

    function afterInvariant() external view {
        // Not vacuous: something has to have been driven in the run.
        assertGt(handler.calls(), 0, "the handler was never called");
    }
}
