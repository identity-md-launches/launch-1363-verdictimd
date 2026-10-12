// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VerdictToken} from "../src/VerdictToken.sol";

/// @notice Drives VERDICT with bounded random calls from a fixed set of actors and keeps its own
///         ledger of what every balance and allowance should be. Calls that must fail (overdrafts,
///         over-allowance spends, zero-address receivers) are attempted too, and the handler checks
///         that they revert and leave state untouched.
contract VerdictHandler is Test {
    VerdictToken public immutable token;
    address[] public actors;

    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    uint256 public successfulMoves;
    uint256 public rejectedCalls;
    /// @dev Set if a call that must revert succeeded, or a rejected call changed state.
    bool public rejectedCallMutatedState;

    constructor(VerdictToken token_, address[] memory actors_) {
        token = token_;
        actors = actors_;
        for (uint256 i; i < actors_.length; ++i) {
            ghostBalance[actors_[i]] = token_.balanceOf(actors_[i]);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    // ------------------------------------------------------------- success paths

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        ++successfulMoves;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool infinite) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        amount = infinite ? type(uint256).max : bound(amount, 0, 2 * token.INITIAL_SUPPLY());
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        ghostAllowance[owner][spender] = amount;
    }

    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(from, spender);
        uint256 held = token.balanceOf(from);
        amount = bound(amount, 0, allowed < held ? allowed : held);
        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount));
        if (ghostAllowance[from][spender] != type(uint256).max) ghostAllowance[from][spender] -= amount;
        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        ++successfulMoves;
    }

    // ------------------------------------------------------------- failure paths

    function overdraft(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 held = token.balanceOf(from);
        uint256 amount = held + bound(excess, 1, type(uint256).max - held);
        _expectRejected(from, abi.encodeCall(token.transfer, (to, amount)), from, to);
    }

    function overspendAllowance(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(from, spender);
        if (allowed == type(uint256).max) return; // nothing exceeds an infinite allowance
        uint256 amount = allowed + bound(excess, 1, type(uint256).max - allowed);
        _expectRejected(spender, abi.encodeCall(token.transferFrom, (from, to, amount)), from, to);
    }

    function transferToZero(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        _expectRejected(from, abi.encodeCall(token.transfer, (address(0), amount)), from, from);
    }

    function _expectRejected(address caller, bytes memory data, address a, address b) internal {
        uint256 supply = token.totalSupply();
        uint256 balA = token.balanceOf(a);
        uint256 balB = token.balanceOf(b);
        vm.prank(caller);
        (bool ok,) = address(token).call(data);
        if (ok || token.totalSupply() != supply || token.balanceOf(a) != balA || token.balanceOf(b) != balB) {
            rejectedCallMutatedState = true;
        }
        ++rejectedCalls;
    }
}

/// @notice Invariants VERDICT must keep after every random sequence of calls.
contract VerdictTokenInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;

    VerdictToken internal token;
    VerdictHandler internal handler;
    address internal deployer = makeAddr("deployer");

    function setUp() public {
        vm.prank(deployer);
        token = new VerdictToken();

        address[] memory actors = new address[](5);
        actors[0] = deployer;
        actors[1] = makeAddr("alice");
        actors[2] = makeAddr("bob");
        actors[3] = makeAddr("carol");
        actors[4] = address(token); // tokens sent to the token contract itself are just a balance
        handler = new VerdictHandler(token, actors);

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = VerdictHandler.transfer.selector;
        selectors[1] = VerdictHandler.approve.selector;
        selectors[2] = VerdictHandler.transferFrom.selector;
        selectors[3] = VerdictHandler.overdraft.selector;
        selectors[4] = VerdictHandler.overspendAllowance.selector;
        selectors[5] = VerdictHandler.transferToZero.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_supplyIsFixed() public view {
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_actorBalancesSumToSupply() public view {
        uint256 sum;
        for (uint256 i; i < handler.actorCount(); ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, token.totalSupply());
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_balancesMatchLedger() public view {
        for (uint256 i; i < handler.actorCount(); ++i) {
            address a = handler.actors(i);
            assertEq(token.balanceOf(a), handler.ghostBalance(a));
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_allowancesMatchLedger() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < n; ++j) {
                address o = handler.actors(i);
                address s = handler.actors(j);
                assertEq(token.allowance(o, s), handler.ghostAllowance(o, s));
            }
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_rejectedCallsNeverMutateState() public view {
        assertFalse(handler.rejectedCallMutatedState());
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_nothingLeaksToTheZeroAddress() public view {
        assertEq(token.balanceOf(address(0)), 0);
    }
}
