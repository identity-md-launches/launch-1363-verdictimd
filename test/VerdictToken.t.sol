// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";
import {VerdictToken} from "../src/VerdictToken.sol";

/// @notice Unit tests for the VERDICT token: metadata, the one-time mint, and the unmodified
///         ERC-20 transfer/approval semantics with their failure paths.
contract VerdictTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;

    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    VerdictToken internal token;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        vm.prank(deployer);
        token = new VerdictToken();
    }

    // ---------------------------------------------------------------- metadata

    function test_metadata() public view {
        assertEq(token.name(), "VerdictIMD");
        assertEq(token.symbol(), "VERDICT");
        assertEq(token.decimals(), 18);
    }

    // ------------------------------------------------------------ constructor

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_constructorEmitsSingleMintTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), deployer, SUPPLY);
        vm.prank(deployer);
        new VerdictToken();
    }

    function test_supplyIsMintedToWhoeverDeploys() public {
        // The launch factory is `msg.sender` of the constructor; nothing else receives anything.
        address factory = makeAddr("factory");
        vm.prank(factory);
        VerdictToken fresh = new VerdictToken();
        assertEq(fresh.balanceOf(factory), SUPPLY);
        assertEq(fresh.balanceOf(deployer), 0);
        assertEq(fresh.balanceOf(address(this)), 0);
    }

    function test_constructorTakesNoArguments() public view {
        // An empty-args constructor keeps the launch manifest's constructorArgs empty and lets the
        // token deploy on an empty chain: the creation code is the compiled bytecode and nothing more.
        assertEq(type(VerdictToken).creationCode.length > 0, true);
    }

    // ---------------------------------------------------------- no admin surface

    function test_noMintPauseOrOwnerFunctionsExist() public {
        string[14] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "owner()",
            "transferOwnership(address)",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "freeze(address)",
            "setTransfersEnabled(bool)",
            "upgradeTo(address)",
            "initialize(address)",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], address(this), type(uint128).max);
            vm.prank(deployer);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_runtimeHasNoDelegatecallOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
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

    // ------------------------------------------------------------- transfers

    function test_transferMovesExactAmount() public {
        vm.prank(deployer);
        vm.expectEmit(true, true, true, true);
        emit Transfer(deployer, alice, 1_000e18);
        assertTrue(token.transfer(alice, 1_000e18));
        assertEq(token.balanceOf(alice), 1_000e18);
        assertEq(token.balanceOf(deployer), SUPPLY - 1_000e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferOfZeroSucceeds() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferWholeBalance() public {
        vm.prank(deployer);
        token.transfer(alice, SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), SUPPLY);
    }

    function test_revert_transferMoreThanBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_revert_transferToZeroAddress() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    // ------------------------------------------------------------- allowances

    function test_approveAndTransferFrom() public {
        vm.prank(deployer);
        token.transfer(alice, 500e18);

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Approval(alice, bob, 200e18);
        assertTrue(token.approve(bob, 200e18));
        assertEq(token.allowance(alice, bob), 200e18);

        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 150e18));
        assertEq(token.balanceOf(alice), 350e18);
        assertEq(token.balanceOf(bob), 150e18);
        assertEq(token.allowance(alice, bob), 50e18);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        vm.prank(deployer);
        token.transfer(alice, 500e18);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.transferFrom(alice, bob, 100e18);
        assertEq(token.allowance(alice, bob), type(uint256).max);
    }

    function test_revert_transferFromWithoutAllowance() public {
        vm.prank(deployer);
        token.transfer(alice, 500e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, bob, 1);
    }

    function test_revert_transferFromExceedingAllowance() public {
        vm.prank(deployer);
        token.transfer(alice, 500e18);
        vm.prank(alice);
        token.approve(bob, 10e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 10e18, 11e18));
        token.transferFrom(alice, bob, 11e18);
    }

    function test_revert_transferFromExceedingBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 5e18);
        vm.prank(alice);
        token.approve(bob, 10e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 5e18, 6e18));
        token.transferFrom(alice, bob, 6e18);
    }

    function test_revert_approveZeroSpender() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(to, amount);
        assertEq(token.balanceOf(to) + token.balanceOf(deployer), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_cannotTransferMoreThanHeld(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        amount = bound(amount, held + 1, type(uint256).max);
        vm.prank(deployer);
        token.transfer(alice, held);
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, amount);
    }
}
