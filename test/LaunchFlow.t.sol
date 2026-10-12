// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {VerdictToken} from "../src/VerdictToken.sol";
import {LaunchLiquidity} from "../src/LaunchLiquidity.sol";
import {PoolInitializationGuard} from "../src/PoolInitializationGuard.sol";
import {HookFlags} from "../src/HookFlags.sol";

/// @dev A minimal ERC-20 standing in for the pair token (IMD), etched at a chosen address so the
///      test can force either currency ordering.
contract PairStub {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Plays the factory: deploys the token (so the supply is minted to it), mines and deploys the
///      initialization guard, opens the pool and seeds it through `LaunchLiquidity`.
contract FactoryStub is IUnlockCallback {
    IPoolManager public manager;
    VerdictToken public token;
    address public guard;

    constructor(IPoolManager manager_) {
        manager = manager_;
        token = new VerdictToken();
    }

    function deployGuard() external returns (address) {
        bytes memory code = abi.encodePacked(type(PoolInitializationGuard).creationCode, abi.encode(address(manager)));
        bytes32 codeHash = keccak256(code);
        for (uint256 i; i < 1_000_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, codeHash)))));
            if (HookFlags.matches(predicted, HookFlags.BEFORE_INITIALIZE)) {
                address deployed;
                assembly ("memory-safe") {
                    deployed := create2(0, add(code, 32), mload(code), salt)
                }
                require(deployed == predicted, "guard address mismatch");
                guard = deployed;
                return deployed;
            }
        }
        revert("salt search exhausted");
    }

    function initialize(PoolKey calldata key, uint160 price) external {
        manager.initialize(key, price);
    }

    function seed(LaunchLiquidity.Seed calldata seed_) external {
        manager.unlock(abi.encode(seed_));
    }

    function send(address to, uint256 amount) external {
        token.transfer(to, amount);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(manager), "not the pool manager");
        LaunchLiquidity.settleSeed(manager, data);
        return "";
    }
}

/// @dev An ordinary trader that pays and collects through `LaunchLiquidity.settle`.
contract TraderStub is IUnlockCallback {
    IPoolManager private immutable manager;
    PoolKey private key;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    receive() external payable {}

    function swap(PoolKey calldata key_, bool zeroForOne, int256 amountSpecified) external returns (BalanceDelta) {
        key = key_;
        return abi.decode(manager.unlock(abi.encode(zeroForOne, amountSpecified)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(manager), "not the pool manager");
        (bool zeroForOne, int256 amountSpecified) = abi.decode(data, (bool, int256));
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        BalanceDelta delta = manager.swap(key, SwapParams(zeroForOne, amountSpecified, limit), "");
        LaunchLiquidity.settle(manager, key.currency0, BalanceDeltaLibrary.amount0(delta));
        LaunchLiquidity.settle(manager, key.currency1, BalanceDeltaLibrary.amount1(delta));
        return abi.encode(delta);
    }
}

/// @notice Exercises the launch flows the factory performs with this token on Uniswap v4, with the
///         pool's pair token placed on either side of the token so both currency orderings are covered.
contract LaunchFlowTest is Test {
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;

    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 internal constant SWARM_BPS = 1_000;
    uint256 internal constant POOL_BPS = 8_000;
    uint24 internal constant FEE = 12_500;
    int24 internal constant SPACING = 60;
    uint160 internal constant ONE_TO_ONE = 79_228_162_514_264_337_593_543_950_336;
    uint128 internal constant LIQUIDITY = 1e26;

    address internal constant DISTRIBUTOR = address(0xD157);
    address internal constant REMAINDER_TO = address(0x612a9bB008e16ef2D24f41DAe9Fc661831d93367);

    PoolManager internal manager;
    FactoryStub internal factory;
    VerdictToken internal token;
    address internal guard;

    function setUp() public {
        manager = new PoolManager(address(this));
        factory = new FactoryStub(manager);
        token = factory.token();
        guard = factory.deployGuard();
    }

    // ----------------------------------------------------------------- HookFlags

    function test_hookFlagsMatchesExactly() public pure {
        address only = address(uint160(0xABCD << 14) | HookFlags.BEFORE_INITIALIZE);
        assertTrue(HookFlags.matches(only, HookFlags.BEFORE_INITIALIZE));
        // Any extra permission bit disqualifies the address: the manager would call hooks the guard lacks.
        assertFalse(HookFlags.matches(address(uint160(only) | (1 << 7)), HookFlags.BEFORE_INITIALIZE));
        assertFalse(HookFlags.matches(address(uint160(0xABCD << 14)), HookFlags.BEFORE_INITIALIZE));
        assertFalse(HookFlags.matches(address(0), HookFlags.BEFORE_INITIALIZE));
    }

    function test_minedGuardCarriesOnlyTheBeforeInitializeFlag() public view {
        assertTrue(HookFlags.matches(guard, HookFlags.BEFORE_INITIALIZE));
        assertEq(uint160(guard) & HookFlags.ALL_FLAGS, HookFlags.BEFORE_INITIALIZE);
        assertEq(PoolInitializationGuard(guard).factory(), address(factory));
        assertEq(PoolInitializationGuard(guard).poolManager(), address(manager));
    }

    // ------------------------------------------------------------------- Guard

    function test_factoryCanInitializeThePool() public {
        (PoolKey memory key,) = _pool(true);
        factory.initialize(key, ONE_TO_ONE);
    }

    function test_revert_strangerCannotInitializeThePool() public {
        (PoolKey memory key,) = _pool(true);
        vm.expectRevert();
        manager.initialize(key, ONE_TO_ONE);
    }

    function test_revert_guardRejectsCallsNotFromThePoolManager() public {
        (PoolKey memory key,) = _pool(true);
        vm.expectRevert(abi.encodeWithSelector(PoolInitializationGuard.NotPoolManager.selector, address(this)));
        PoolInitializationGuard(guard).beforeInitialize(address(factory), key, ONE_TO_ONE);
    }

    function test_revert_guardRejectsInitializerOtherThanFactory() public {
        (PoolKey memory key,) = _pool(true);
        vm.prank(address(manager));
        vm.expectRevert(abi.encodeWithSelector(PoolInitializationGuard.NotFactory.selector, address(this)));
        PoolInitializationGuard(guard).beforeInitialize(address(this), key, ONE_TO_ONE);
    }

    // ----------------------------------------------------------- Launch flows

    function test_supplyIsMintedToTheFactory() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
    }

    function test_swarmShareArrivesWholeAndIsClaimableWhole() public {
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        factory.send(DISTRIBUTOR, swarm);
        assertEq(token.balanceOf(DISTRIBUTOR), swarm);
        vm.prank(DISTRIBUTOR);
        token.transfer(address(0xC1A1), swarm);
        assertEq(token.balanceOf(address(0xC1A1)), swarm);
        assertEq(token.balanceOf(DISTRIBUTOR), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_remainderArrivesWhole() public {
        uint256 remainder = SUPPLY - (SUPPLY * (SWARM_BPS + POOL_BPS)) / 10_000;
        factory.send(REMAINDER_TO, remainder);
        assertEq(token.balanceOf(REMAINDER_TO), remainder);
    }

    function test_seedAndRoundTripSwap_tokenIsCurrency0() public {
        _seedAndTrade(true);
    }

    function test_seedAndRoundTripSwap_tokenIsCurrency1() public {
        _seedAndTrade(false);
    }

    function test_revert_seedWithoutEnoughTokensLeavesNothingBehind() public {
        (PoolKey memory key, bool tokenIs0) = _pool(true);
        factory.initialize(key, ONE_TO_ONE);
        // Drain the factory so the seed's debt cannot be paid: the whole unlock must revert.
        factory.send(address(0xDEAD), SUPPLY);
        vm.expectRevert();
        factory.seed(_seedFor(key, tokenIs0));
        assertEq(_positionLiquidity(key, _seedFor(key, tokenIs0)), 0);
    }

    function test_revert_seedBeforeInitializeFails() public {
        (PoolKey memory key, bool tokenIs0) = _pool(true);
        vm.expectRevert();
        factory.seed(_seedFor(key, tokenIs0));
    }

    function test_settleZeroIsANoOp() public {
        // Settling a zero delta must neither sync nor take; a plain unlock with nothing owed succeeds.
        ZeroSettler z = new ZeroSettler(manager);
        z.run(Currency.wrap(address(token)));
    }

    // ------------------------------------------------------------------ helpers

    /// @dev Places a pair token stub immediately below or above the token's address so that the
    ///      token sorts as currency0 or currency1, then returns the pool key for it.
    function _pool(bool tokenIs0) internal returns (PoolKey memory key, bool) {
        address paired = tokenIs0 ? address(uint160(address(token)) + 1) : address(uint160(address(token)) - 1);
        vm.etch(paired, address(new PairStub()).code);
        (Currency c0, Currency c1) = address(token) < paired
            ? (Currency.wrap(address(token)), Currency.wrap(paired))
            : (Currency.wrap(paired), Currency.wrap(address(token)));
        key = PoolKey(c0, c1, FEE, SPACING, IHooks(guard));
        return (key, tokenIs0);
    }

    /// @dev A single-sided range at the one-to-one price: above the current tick when the token is
    ///      currency0 (so only token0 is deposited), below it when the token is currency1.
    function _seedFor(PoolKey memory key, bool tokenIs0) internal pure returns (LaunchLiquidity.Seed memory) {
        int24 maxUsable = (TickMath.MAX_TICK / SPACING) * SPACING;
        return tokenIs0
            ? LaunchLiquidity.Seed(key, SPACING, maxUsable, LIQUIDITY)
            : LaunchLiquidity.Seed(key, -maxUsable, -SPACING, LIQUIDITY);
    }

    function _positionLiquidity(PoolKey memory key, LaunchLiquidity.Seed memory seed_) internal view returns (uint128) {
        bytes32 positionKey =
            Position.calculatePositionKey(address(factory), seed_.tickLower, seed_.tickUpper, bytes32(0));
        return IPoolManager(address(manager)).getPositionLiquidity(key.toId(), positionKey);
    }

    function _seedAndTrade(bool tokenIs0) internal {
        (PoolKey memory key,) = _pool(tokenIs0);
        address paired = tokenIs0 ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);
        factory.initialize(key, ONE_TO_ONE);

        uint256 before = token.balanceOf(address(factory));
        factory.seed(_seedFor(key, tokenIs0));
        uint256 taken = before - token.balanceOf(address(factory));
        assertGt(taken, 0, "seed took nothing");
        assertLe(taken, (SUPPLY * POOL_BPS) / 10_000, "seed exceeded the pool share");
        assertEq(token.balanceOf(address(manager)), taken, "pool manager did not receive the seed");
        assertEq(PairStub(paired).balanceOf(address(manager)), 0, "single-sided seed took pair tokens");
        // The seed sits entirely on one side of the current tick, so it is not "active" liquidity yet;
        // check the factory's position directly.
        assertEq(_positionLiquidity(key, _seedFor(key, tokenIs0)), LIQUIDITY);

        TraderStub trader = new TraderStub(manager);
        PairStub(paired).mint(address(trader), 10 ether);
        bool pairIsZero = Currency.unwrap(key.currency0) == paired;

        // Buy: pair token in, VERDICT out.
        BalanceDelta buy = trader.swap(key, pairIsZero, -0.01 ether);
        uint256 bought = token.balanceOf(address(trader));
        assertGt(bought, 0, "could not buy");
        assertEq(PairStub(paired).balanceOf(address(trader)), 10 ether - 0.01 ether, "trader paid the wrong amount");
        int128 paid = pairIsZero ? buy.amount0() : buy.amount1();
        assertEq(paid, -0.01 ether);

        // Sell everything back: VERDICT in, pair token out.
        trader.swap(key, !pairIsZero, -int256(bought));
        assertEq(token.balanceOf(address(trader)), 0, "could not sell");
        assertGt(PairStub(paired).balanceOf(address(trader)), 10 ether - 0.01 ether, "sale returned nothing");
        assertEq(token.totalSupply(), SUPPLY, "trading changed the supply");
    }
}

/// @dev Calls `LaunchLiquidity.settle` with a zero delta inside an unlock, proving it is a no-op.
contract ZeroSettler is IUnlockCallback {
    IPoolManager private immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function run(Currency currency) external {
        manager.unlock(abi.encode(currency));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(manager), "not the pool manager");
        LaunchLiquidity.settle(manager, abi.decode(data, (Currency)), 0);
        return "";
    }
}
