// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";
import {VerdictToken} from "../src/VerdictToken.sol";

/// @notice Edge cases not covered by VerdictToken.t.sol: self-transfers, owner spending its own
///         balance through transferFrom, approval overwrites, zero-value spends, the maximum amount,
///         and that a failed spend consumes no allowance.
contract VerdictTokenEdgeTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;

    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    VerdictToken internal token;

    function setUp() public {
        vm.prank(deployer);
        token = new VerdictToken();
        vm.prank(deployer);
        token.transfer(alice, 1_000e18);
    }

    function test_selfTransferLeavesBalanceUnchanged() public {
        vm.prank(alice);
        assertTrue(token.transfer(alice, 400e18));
        assertEq(token.balanceOf(alice), 1_000e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_revert_selfTransferAboveBalance() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1_000e18, 1_000e18 + 1)
        );
        token.transfer(alice, 1_000e18 + 1);
    }

    function test_revert_transferMaxUint() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY - 1_000e18, type(uint256).max
            )
        );
        token.transfer(alice, type(uint256).max);
    }

    function test_revert_ownerTransferFromSelfNeedsAllowance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(alice, bob, 1);
    }

    function test_revert_transferFromToZeroAddress() public {
        vm.prank(alice);
        token.approve(bob, 10e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(alice, address(0), 1e18);
        assertEq(token.allowance(alice, bob), 10e18, "a reverted spend consumed allowance");
    }

    function test_revert_transferFromZeroAddressOwner() public {
        // address(0) holds nothing and has approved nobody; the allowance check fires first.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(address(0), bob, 1);
    }

    function test_zeroValueTransferFromNeedsNoAllowance() public {
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(token.balanceOf(alice), 1_000e18);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_approveOverwritesRatherThanAdds() public {
        vm.startPrank(alice);
        token.approve(bob, 100e18);
        token.approve(bob, 30e18);
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), 30e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 30e18, 31e18));
        token.transferFrom(alice, bob, 31e18);
    }

    function test_approveZeroRevokes() public {
        vm.startPrank(alice);
        token.approve(bob, 100e18);
        token.approve(bob, 0);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, bob, 1);
    }

    function test_allowanceIsExactlyConsumedThenExhausted() public {
        vm.prank(alice);
        token.approve(bob, 5e18);
        vm.startPrank(bob);
        token.transferFrom(alice, bob, 5e18);
        assertEq(token.allowance(alice, bob), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, bob, 1);
        vm.stopPrank();
    }

    function test_failedSpendForBalanceConsumesNoAllowance() public {
        vm.prank(alice);
        token.approve(bob, type(uint256).max - 1);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1_000e18, 2_000e18)
        );
        token.transferFrom(alice, bob, 2_000e18);
        assertEq(token.allowance(alice, bob), type(uint256).max - 1);
    }

    function test_oneWeiMoves() public {
        vm.prank(alice);
        token.transfer(bob, 1);
        assertEq(token.balanceOf(bob), 1);
        assertEq(token.balanceOf(alice), 1_000e18 - 1);
    }

    function test_noEtherAccepted() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok, "the token accepted ether it has no way to return");
        assertEq(address(token).balance, 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferFromDecrementsAllowanceExactly(uint256 allowance, uint256 amount) public {
        allowance = bound(allowance, 0, type(uint256).max - 1);
        amount = bound(amount, 0, allowance < 1_000e18 ? allowance : 1_000e18);
        vm.prank(alice);
        token.approve(bob, allowance);
        vm.prank(bob);
        token.transferFrom(alice, bob, amount);
        assertEq(token.allowance(alice, bob), allowance - amount);
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.balanceOf(alice), 1_000e18 - amount);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_spendAboveAllowanceReverts(uint256 allowance, uint256 amount) public {
        allowance = bound(allowance, 0, 1_000e18 - 1);
        amount = bound(amount, allowance + 1, 1_000e18);
        vm.prank(alice);
        token.approve(bob, allowance);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, allowance, amount)
        );
        token.transferFrom(alice, bob, amount);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_strangerCannotMoveAnotherHoldersBalance(address stranger, uint256 amount) public {
        vm.assume(stranger != alice);
        amount = bound(amount, 1, 1_000e18);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, stranger, 0, amount));
        token.transferFrom(alice, stranger, amount);
        assertEq(token.balanceOf(alice), 1_000e18);
    }
}
