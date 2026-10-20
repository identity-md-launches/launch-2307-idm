// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IDMToken} from "../src/IDMToken.sol";

/// @notice Edges the base suite leaves open: the full supply, one wei, the same call twice, a
/// caller the code did not expect, and permit signatures that are malformed or reused.
contract IDMTokenEdgeTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    IDMToken internal token;
    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal ownerKey = 0x0DDBA11;
    address internal owner;

    function setUp() public {
        owner = vm.addr(ownerKey);
        vm.prank(deployer);
        token = new IDMToken();
    }

    function _sign(uint256 key, address holder, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                token.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(PERMIT_TYPEHASH, holder, spender, value, nonce, deadline))
            )
        );
        return vm.sign(key, digest);
    }

    // ---------------------------------------------------------------- balances at the edges

    function test_transferOfTheWholeSupplyEmptiesTheSender() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(deployer), 0);

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, 0, 1));
        token.transfer(alice, 1);
    }

    function test_transferOneWeiOverBalanceReverts() public {
        vm.prank(deployer);
        token.transfer(alice, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1, 2));
        token.transfer(bob, 2);
        assertEq(token.balanceOf(alice), 1, "a failed transfer moved something");
    }

    function test_transferToTheTokenItselfIsKeptInSupply() public {
        vm.prank(deployer);
        token.transfer(address(token), 1 ether);
        assertEq(token.balanceOf(address(token)), 1 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromZeroAddressCannotBeSpent() public {
        // Nobody can hold an allowance from address(0), so its (empty) balance can never be spent.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(address(0), alice, 1);
    }

    function test_transferFromToZeroAddressReverts() public {
        vm.prank(deployer);
        token.approve(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(deployer, address(0), 1 ether);
        assertEq(token.allowance(deployer, bob), 1 ether, "a failed transferFrom spent the allowance");
    }

    function test_transferFromBySelfStillNeedsAllowance() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1 ether));
        token.transferFrom(deployer, alice, 1 ether);
    }

    function test_transferFromCannotSpendTheSameAllowanceTwice() public {
        vm.prank(deployer);
        token.approve(bob, 3 ether);
        vm.prank(bob);
        token.transferFrom(deployer, bob, 3 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 3 ether));
        token.transferFrom(deployer, bob, 3 ether);
        assertEq(token.balanceOf(bob), 3 ether);
    }

    function test_approveOverwritesRatherThanAdds() public {
        vm.startPrank(deployer);
        token.approve(bob, 5 ether);
        token.approve(bob, 2 ether);
        vm.stopPrank();
        assertEq(token.allowance(deployer, bob), 2 ether);
        vm.prank(deployer);
        token.approve(bob, 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(deployer, bob, 1);
    }

    function test_approvalOfAnotherHolderIsNotSharedBySpenders() public {
        vm.prank(deployer);
        token.approve(alice, 1 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1 ether));
        token.transferFrom(deployer, bob, 1 ether);
    }

    function test_infiniteAllowanceStillBoundByBalance() public {
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transferFrom(alice, bob, 1);
    }

    function test_unknownSelectorReverts() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("burn(uint256)", 1 ether));
        assertFalse(ok, "burn(uint256) exists");
        (ok,) = address(token).call(hex"deadbeef");
        assertFalse(ok, "fallback accepted an unknown selector");
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------- permit edges

    function test_permitAtExactDeadlineSucceeds() public {
        uint256 deadline = block.timestamp;
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, bob, 1 ether, 0, deadline);
        token.permit(owner, bob, 1 ether, deadline, v, r, s);
        assertEq(token.allowance(owner, bob), 1 ether);
    }

    function test_permitOneSecondPastDeadlineReverts() public {
        uint256 deadline = block.timestamp;
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, bob, 1 ether, 0, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(owner, bob, 1 ether, deadline, v, r, s);
    }

    function test_permitForAnotherValueReverts() public {
        uint256 deadline = block.timestamp + 1;
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, bob, 1 ether, 0, deadline);
        vm.expectRevert();
        token.permit(owner, bob, 2 ether, deadline, v, r, s);
        assertEq(token.nonces(owner), 0);
    }

    function test_permitForAnotherSpenderReverts() public {
        uint256 deadline = block.timestamp + 1;
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, bob, 1 ether, 0, deadline);
        vm.expectRevert();
        token.permit(owner, alice, 1 ether, deadline, v, r, s);
        assertEq(token.allowance(owner, alice), 0);
    }

    function test_permitSignedForAFutureNonceReverts() public {
        uint256 deadline = block.timestamp + 1;
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, bob, 1 ether, 1, deadline);
        vm.expectRevert();
        token.permit(owner, bob, 1 ether, deadline, v, r, s);
    }

    function test_permitWithMalleableHighSReverts() public {
        uint256 deadline = block.timestamp + 1;
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, bob, 1 ether, 0, deadline);
        bytes32 highS = bytes32(SECP256K1_N - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, highS));
        token.permit(owner, bob, 1 ether, deadline, flippedV, r, highS);
    }

    function test_permitWithGarbageSignatureReverts() public {
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        token.permit(owner, bob, 1 ether, block.timestamp, 27, bytes32(0), bytes32(0));
    }

    function test_permitForZeroOwnerCannotBeForged() public {
        // ecrecover yields address(0) for an invalid signature; OZ must refuse it, not match owner 0.
        vm.expectRevert();
        token.permit(address(0), bob, 1 ether, block.timestamp, 27, bytes32(uint256(1)), bytes32(uint256(1)));
        assertEq(token.allowance(address(0), bob), 0);
    }

    function test_permitToZeroSpenderReverts() public {
        uint256 deadline = block.timestamp + 1;
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, address(0), 1 ether, 0, deadline);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.permit(owner, address(0), 1 ether, deadline, v, r, s);
        assertEq(token.nonces(owner), 0, "a reverted permit consumed the nonce");
    }

    function test_permitSignatureIsBoundToTheChain() public {
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, bob, 1 ether, 0, deadline);
        bytes32 separator = token.DOMAIN_SEPARATOR();
        vm.chainId(block.chainid + 1);
        assertTrue(token.DOMAIN_SEPARATOR() != separator, "domain separator ignores the chain id");
        vm.expectRevert();
        token.permit(owner, bob, 1 ether, deadline, v, r, s);
    }

    // ---------------------------------------------------------------- fuzz

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferBetweenHoldersConservesBalances(uint256 seedAmount, uint256 amount, address to) public {
        // address(0) cannot receive; every other recipient, including the sender, is in play.
        if (to == address(0)) to = bob;
        seedAmount = bound(seedAmount, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, seedAmount);

        amount = bound(amount, 0, seedAmount);
        uint256 aliceBefore = token.balanceOf(alice);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(alice);
        assertTrue(token.transfer(to, amount));
        if (to == alice) {
            assertEq(token.balanceOf(alice), aliceBefore);
        } else {
            assertEq(token.balanceOf(alice), aliceBefore - amount);
            assertEq(token.balanceOf(to), toBefore + amount);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferFromBeyondAllowanceRevertsAndChangesNothing(uint256 allowed, uint256 excess) public {
        allowed = bound(allowed, 0, SUPPLY - 1);
        uint256 amount = allowed + bound(excess, 1, SUPPLY - allowed);
        vm.prank(deployer);
        token.approve(bob, allowed);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, allowed, amount));
        token.transferFrom(deployer, bob, amount);
        assertEq(token.allowance(deployer, bob), allowed);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_permitSetsAnyValue(uint256 value, uint256 ttl) public {
        uint256 deadline = block.timestamp + bound(ttl, 0, 3650 days);
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, bob, value, 0, deadline);
        token.permit(owner, bob, value, deadline, v, r, s);
        assertEq(token.allowance(owner, bob), value);
        assertEq(token.nonces(owner), 1);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_permitFromTheWrongKeyNeverApproves(uint256 wrongKey) public {
        wrongKey = bound(wrongKey, 1, SECP256K1_N - 1);
        if (wrongKey == ownerKey) wrongKey = ownerKey + 1;
        uint256 deadline = block.timestamp + 1;
        (uint8 v, bytes32 r, bytes32 s) = _sign(wrongKey, owner, bob, 1 ether, 0, deadline);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, vm.addr(wrongKey), owner));
        token.permit(owner, bob, 1 ether, deadline, v, r, s);
    }
}
