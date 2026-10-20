// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IDMToken} from "../src/IDMToken.sol";

/// @notice Stands in for the launch factory: deploys the token through CREATE2 from its own
/// address, so the supply lands here as it will land in the factory, then pays it out.
contract FactoryProbe {
    function deploy(bytes32 salt) external returns (IDMToken) {
        return new IDMToken{salt: salt}();
    }

    function move(IDMToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract IDMTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 internal constant SWARM_BPS = 1_000;
    uint256 internal constant POOL_BPS = 5_000;

    IDMToken internal token;
    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal attacker = makeAddr("attacker");

    uint256 internal signerKey = 0xA11CE;
    address internal signer;

    function setUp() public {
        signer = vm.addr(signerKey);
        vm.prank(deployer);
        token = new IDMToken();
    }

    // ---------------------------------------------------------------- metadata and supply

    function test_metadata() public view {
        assertEq(token.name(), "idm");
        assertEq(token.symbol(), "IDM");
        assertEq(token.decimals(), 18);
        assertEq(token.TOKEN_NAME(), "idm");
        assertEq(token.TOKEN_SYMBOL(), "IDM");
    }

    function test_supplyIsOneBillionWithEighteenDecimals() public view {
        assertEq(token.TOTAL_SUPPLY(), 1_000_000_000 * 10 ** 18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_constructorMintsWholeSupplyToDeployer() public {
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(address(0), deployer, SUPPLY);
        vm.prank(deployer);
        IDMToken fresh = new IDMToken();
        assertEq(fresh.balanceOf(deployer), SUPPLY);
        assertEq(fresh.totalSupply(), SUPPLY);
    }

    function test_supplyLandsAtTheCreate2DeployerLikeTheFactory() public {
        FactoryProbe probe = new FactoryProbe();
        IDMToken launched = probe.deploy(bytes32(uint256(16)));
        assertEq(launched.totalSupply(), SUPPLY, "manifest supply mismatch");
        assertEq(launched.balanceOf(address(probe)), SUPPLY, "the factory does not hold the whole supply");
        assertEq(launched.balanceOf(address(this)), 0);
    }

    function test_eip712DomainMatchesTheToken() public view {
        (, string memory name, string memory version, uint256 chainId, address verifying,,) = token.eip712Domain();
        assertEq(name, "idm");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifying, address(token));
    }

    // ---------------------------------------------------------------- transfers: success

    function test_transferMovesExactAmount() public {
        vm.prank(deployer);
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(deployer, alice, 1_000 ether);
        assertTrue(token.transfer(alice, 1_000 ether));
        assertEq(token.balanceOf(alice), 1_000 ether);
        assertEq(token.balanceOf(deployer), SUPPLY - 1_000 ether);
        assertEq(token.totalSupply(), SUPPLY, "a transfer changed the supply");
    }

    function test_transferOfZeroSucceeds() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(deployer, 5 ether));
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_approveAndTransferFrom() public {
        vm.prank(deployer);
        token.transfer(alice, 100 ether);

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit IERC20.Approval(alice, bob, 60 ether);
        assertTrue(token.approve(bob, 60 ether));
        assertEq(token.allowance(alice, bob), 60 ether);

        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 40 ether));
        assertEq(token.balanceOf(bob), 40 ether);
        assertEq(token.balanceOf(alice), 60 ether);
        assertEq(token.allowance(alice, bob), 20 ether, "allowance was not reduced by the amount spent");
    }

    function test_infiniteAllowanceIsNotReduced() public {
        vm.prank(deployer);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.transferFrom(deployer, bob, 1 ether);
        assertEq(token.allowance(deployer, bob), type(uint256).max);
    }

    /// @dev The launch flows the factory performs: 10% to the distributor, a claim out of it, 50%
    /// into the pool, the remainder to the requester. Every hop must arrive whole.
    function test_launchFlowsArriveWhole() public {
        FactoryProbe probe = new FactoryProbe();
        IDMToken launched = probe.deploy(bytes32(uint256(16)));
        address distributor = makeAddr("distributor");
        address claimant = makeAddr("claimant");
        address pool = makeAddr("poolManager");
        address requester = makeAddr("requester");

        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        uint256 poolShare = (SUPPLY * POOL_BPS) / 10_000;
        uint256 remainder = SUPPLY - swarm - poolShare;

        assertTrue(probe.move(launched, distributor, swarm));
        assertEq(launched.balanceOf(distributor), swarm, "the swarm's share arrived short");
        vm.prank(distributor);
        assertTrue(launched.transfer(claimant, swarm));
        assertEq(launched.balanceOf(claimant), swarm, "a claim arrived short");
        assertEq(launched.balanceOf(distributor), 0);

        assertTrue(probe.move(launched, pool, poolShare));
        assertEq(launched.balanceOf(pool), poolShare, "the seed arrived short");
        assertTrue(probe.move(launched, requester, remainder));
        assertEq(launched.balanceOf(requester), remainder, "the remainder arrived short");

        assertEq(launched.balanceOf(address(probe)), 0, "the factory kept something back");
        assertEq(launched.totalSupply(), SUPPLY, "the launch flows changed the supply");
    }

    // ---------------------------------------------------------------- transfers: failure

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_transferRevertsToZeroAddress() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1 ether);
    }

    function test_transferFromRevertsWithoutAllowance() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1 ether));
        token.transferFrom(deployer, bob, 1 ether);
    }

    function test_transferFromRevertsBeyondAllowance() public {
        vm.prank(deployer);
        token.approve(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 1 ether, 2 ether));
        token.transferFrom(deployer, bob, 2 ether);
    }

    function test_transferFromRevertsWhenOwnerBalanceIsShort() public {
        vm.prank(alice);
        token.approve(bob, 10 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 10 ether));
        token.transferFrom(alice, bob, 10 ether);
    }

    function test_approveRevertsForZeroSpender() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    // ---------------------------------------------------------------- permit

    function _permitDigest(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                spender,
                value,
                nonce,
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
    }

    function test_permitSetsAllowanceAndConsumesNonce() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _permitDigest(signer, bob, 7 ether, 0, deadline));

        vm.prank(attacker); // anyone may relay a permit
        token.permit(signer, bob, 7 ether, deadline, v, r, s);
        assertEq(token.allowance(signer, bob), 7 ether);
        assertEq(token.nonces(signer), 1);
    }

    function test_permitRejectsReplay() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _permitDigest(signer, bob, 7 ether, 0, deadline));
        token.permit(signer, bob, 7 ether, deadline, v, r, s);

        vm.expectRevert();
        token.permit(signer, bob, 7 ether, deadline, v, r, s);
    }

    function test_permitRejectsExpiredDeadline() public {
        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _permitDigest(signer, bob, 7 ether, 0, deadline));
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(signer, bob, 7 ether, deadline, v, r, s);
    }

    function test_permitRejectsWrongSigner() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xB0B, _permitDigest(signer, bob, 7 ether, 0, deadline));
        vm.expectRevert();
        token.permit(signer, bob, 7 ether, deadline, v, r, s);
        assertEq(token.allowance(signer, bob), 0);
    }

    // ---------------------------------------------------------------- no privileged surface

    function test_noMintOrAdminCallGrowsSupply() public {
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            vm.prank(deployer);
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(attacker), 0, signatures[i]);
        }
    }

    function test_noPrivilegedCallMovesOrFreezesAHolder() public {
        vm.prank(deployer);
        token.transfer(alice, SUPPLY / 1_000);
        uint256 held = token.balanceOf(alice);

        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, true));
            assertFalse(ok, signatures[i]);
        }
        vm.prank(deployer);
        vm.expectRevert();
        token.transferFrom(alice, deployer, 1);

        assertEq(token.balanceOf(alice), held, "a privileged call moved the holder's balance");
        vm.prank(alice);
        assertTrue(token.transfer(bob, held / 2), "the holder can no longer transfer");
        assertEq(token.balanceOf(bob), held / 2);
    }

    function test_runtimeCodeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    function test_rejectsEther() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok, "the token accepted ether");
        assertEq(address(token).balance, 0);
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));
        if (to == deployer) {
            assertEq(token.balanceOf(deployer), SUPPLY);
        } else {
            assertEq(token.balanceOf(to), amount);
            assertEq(token.balanceOf(deployer), SUPPLY - amount);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferAboveBalanceReverts(uint256 amount) public {
        amount = bound(amount, SUPPLY + 1, type(uint256).max);
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, amount)
        );
        token.transfer(alice, amount);
    }

    function testFuzz_transferFromSpendsExactAllowance(uint256 allowed, uint256 spent) public {
        allowed = bound(allowed, 0, SUPPLY);
        spent = bound(spent, 0, allowed);
        vm.prank(deployer);
        token.approve(bob, allowed);
        vm.prank(bob);
        assertTrue(token.transferFrom(deployer, alice, spent));
        assertEq(token.balanceOf(alice), spent);
        assertEq(token.allowance(deployer, bob), allowed - spent);
    }
}
