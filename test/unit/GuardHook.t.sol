// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BUFIIdentityRegistry} from "../../src/identity/BUFIIdentityRegistry.sol";
import {BUFIReputationRegistry} from "../../src/identity/BUFIReputationRegistry.sol";
import {WorkspaceTierRegistry} from "../../src/credit/WorkspaceTierRegistry.sol";
import {InvoiceShelf} from "../../src/invoice/InvoiceShelf.sol";
import {BINV} from "../../src/invoice/BINV.sol";
import {RecibuSettlementGuardHook} from "../../src/hooks/RecibuSettlementGuardHook.sol";
import {PoolKey, Currency, IPoolManager, BeforeSwapDelta, IRecibuPriceFeed} from "../../src/interfaces/IV4Types.sol";
import {IInvoiceShelf} from "../../src/interfaces/IInvoiceShelf.sol";
import {Params} from "../../src/libraries/Params.sol";
import {ReceivableCommitment} from "../../src/libraries/ReceivableCommitment.sol";
import {StrictAuthorityFixture, StrictAuthorityInvoiceVerifier} from "../utils/StrictAuthorityInvoiceVerifier.sol";

contract GuardUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

contract MockFeed is IRecibuPriceFeed {
    uint256 public p;
    uint256 public t;

    function set(uint256 price_, uint256 updatedAt_) external {
        p = price_;
        t = updatedAt_;
    }

    function latest() external view returns (uint256, uint256) {
        return (p, t);
    }
}

contract GuardHookTest is StrictAuthorityFixture {
    uint160 internal constant PARITY_SQRT_PRICE_X96 = uint160((uint256(1) << 96) * 1e6);

    GuardUSDC internal usdc;
    BUFIIdentityRegistry internal identity;
    BUFIReputationRegistry internal reputation;
    WorkspaceTierRegistry internal tiers;
    InvoiceShelf internal shelf;
    StrictAuthorityInvoiceVerifier internal authorityVerifier;
    RecibuSettlementGuardHook internal hook;
    MockFeed internal feed;

    address internal admin = makeAddr("admin");
    address internal issuer = makeAddr("issuer");
    address internal attestor = makeAddr("attestor");
    address internal servicer = makeAddr("servicer");
    address internal poolManager = makeAddr("poolManager");
    address internal requester = makeAddr("requester");
    address internal escrow = makeAddr("escrow");
    address internal settlement = makeAddr("settlement");
    address internal stableFx = makeAddr("stableFx");

    uint256 internal seller;
    uint256 internal debtor;
    uint256 internal invId;

    function setUp() public {
        usdc = new GuardUSDC();
        identity = new BUFIIdentityRegistry(admin);
        reputation = new BUFIReputationRegistry(admin, identity);
        tiers = new WorkspaceTierRegistry(identity, reputation);
        (shelf, authorityVerifier) = _deployStrictShelf(usdc, identity, reputation, tiers, admin);
        feed = new MockFeed();
        hook = new RecibuSettlementGuardHook(
            poolManager,
            IInvoiceShelf(address(shelf)),
            escrow,
            settlement,
            _poolConfig(true),
            IRecibuPriceFeed(address(feed)),
            admin
        );

        vm.startPrank(admin);
        identity.grantRole(identity.ISSUER_ROLE(), issuer);
        reputation.grantRole(reputation.ATTESTOR_ROLE(), attestor);
        reputation.grantRole(reputation.SETTLEMENT_ROLE(), address(shelf));
        shelf.grantRole(shelf.SERVICER_ROLE(), servicer);
        hook.setWhitelist(requester, true);
        vm.stopPrank();

        seller = _ws("seller", 74, 74);
        debtor = _ws("debtor", 74, 87);

        address lp = makeAddr("lp");
        usdc.mint(lp, 1_000_000e6);
        vm.startPrank(lp);
        usdc.approve(address(shelf), type(uint256).max);
        shelf.depositTranche(2, 1_000_000e6);
        vm.stopPrank();

        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory terms =
            _newApprovedTerms(authorityVerifier, seller, debtor, address(usdc), 500e6, 2, firstMaturity, 30 days);
        vm.prank(servicer);
        invId = shelf.lockInvoice(seller, debtor, 500e6, 2, firstMaturity, 30 days, terms, _docs());

        feed.set(1e18, block.timestamp); // fresh, parity
    }

    function _ws(string memory tag, uint8 s, uint8 d) internal returns (uint256 id) {
        vm.startPrank(issuer);
        id = identity.registerWorkspace(keccak256(bytes(tag)), makeAddr(tag));
        identity.setKybStatus(id, true);
        vm.stopPrank();
        vm.prank(attestor);
        reputation.setScore(id, s, d, 1, bytes32("r"));
    }

    function _docs() internal pure returns (BINV.DocBundle memory) {
        return BINV.DocBundle(bytes32("i"), bytes32("a"), bytes32("p"), bytes32("s"), bytes32("d"));
    }

    function _ctx(uint256 id, address req, address recip, uint256 deadline)
        internal
        pure
        returns (RecibuSettlementGuardHook.RecibuSwapContext memory c)
    {
        c.invoiceId = bytes32(id);
        c.workspaceId = keccak256("ws");
        c.settlementId = keccak256("set");
        c.routeId = keccak256("route");
        c.expectedRequester = req;
        c.recipient = recip;
        c.minAmountOut = 1;
        c.deadline = deadline;
    }

    function _params() internal pure returns (IPoolManager.SwapParams memory) {
        return
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -100e6, sqrtPriceLimitX96: PARITY_SQRT_PRICE_X96
            });
    }

    function _delta(int128 amount0, int128 amount1) internal pure returns (int256) {
        return (int256(amount0) << 128) | int256(uint256(uint128(amount1)));
    }

    function _successfulDelta() internal pure returns (int256) {
        return _delta(-100e6, 100e6);
    }

    function _key() internal view returns (PoolKey memory) {
        return _keyFor(address(hook));
    }

    function _keyFor(address hookAddress) internal view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(usdc)), Currency.wrap(stableFx), 100, 1, hookAddress);
    }

    function _poolConfig(bool feedPriceIsCurrency1PerCurrency0)
        internal
        view
        returns (RecibuSettlementGuardHook.PoolConfiguration memory)
    {
        return RecibuSettlementGuardHook.PoolConfiguration({
            currency0: Currency.wrap(address(usdc)),
            currency1: Currency.wrap(stableFx),
            fee: 100,
            tickSpacing: 1,
            currency0Decimals: 6,
            currency1Decimals: 18,
            feedPriceIsCurrency1PerCurrency0: feedPriceIsCurrency1PerCurrency0
        });
    }

    function _call(RecibuSettlementGuardHook.RecibuSwapContext memory c) internal {
        vm.prank(poolManager);
        hook.beforeSwap(requester, _key(), _params(), abi.encode(c));
    }

    // ── happy path ──

    function test_beforeSwap_passesValidSettlement() public {
        _call(_ctx(invId, requester, escrow, block.timestamp + 1 hours));
        // also settlement recipient is valid
        _call(_ctx(invId, requester, settlement, block.timestamp + 1 hours));
    }

    function test_permissions_beforeAndAfterSwapOnly() public view {
        assertTrue(hook.getHookPermissions().beforeSwap);
        assertTrue(hook.getHookPermissions().afterSwap);
        assertFalse(hook.getHookPermissions().beforeSwapReturnDelta); // guard, not PMM
        assertFalse(hook.getHookPermissions().beforeAddLiquidity);
        assertEq(hook.EXPECTED_HOOK_FLAGS(), (1 << 7) | (1 << 6));
        assertEq(hook.ALL_HOOK_MASK(), (1 << 14) - 1);
        assertEq(
            hook.hasExpectedHookAddressFlags(),
            uint160(address(hook)) & hook.ALL_HOOK_MASK() == hook.EXPECTED_HOOK_FLAGS()
        );
    }

    function test_constructor_isLocalSimulationOnly() public {
        uint256 liveChainId = 43_113;
        vm.chainId(liveChainId);
        vm.expectRevert(abi.encodeWithSelector(RecibuSettlementGuardHook.LiveDeploymentDisabled.selector, liveChainId));
        new RecibuSettlementGuardHook(
            poolManager,
            IInvoiceShelf(address(shelf)),
            escrow,
            settlement,
            _poolConfig(true),
            IRecibuPriceFeed(address(feed)),
            admin
        );
    }

    function test_constructor_revertsForZeroFeed() public {
        vm.expectRevert(RecibuSettlementGuardHook.ZeroAddress.selector);
        new RecibuSettlementGuardHook(
            poolManager,
            IInvoiceShelf(address(shelf)),
            escrow,
            settlement,
            _poolConfig(true),
            IRecibuPriceFeed(address(0)),
            admin
        );
    }

    function test_constructor_revertsForUnsupportedDecimals() public {
        RecibuSettlementGuardHook.PoolConfiguration memory config = _poolConfig(true);
        config.currency1Decimals = hook.MAX_SUPPORTED_DECIMALS() + 1;
        vm.expectRevert(RecibuSettlementGuardHook.InvalidPoolConfiguration.selector);
        new RecibuSettlementGuardHook(
            poolManager,
            IInvoiceShelf(address(shelf)),
            escrow,
            settlement,
            config,
            IRecibuPriceFeed(address(feed)),
            admin
        );
    }

    function test_adminCanRevokeTrustedPeriphery() public {
        vm.prank(admin);
        hook.setWhitelist(requester, false);
        assertFalse(hook.whitelisted(requester));

        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(RecibuSettlementGuardHook.NotWhitelisted.selector, requester));
        hook.beforeSwap(
            requester, _key(), _params(), abi.encode(_ctx(invId, requester, escrow, block.timestamp + 1 hours))
        );
    }

    function test_revert_zeroWhitelistEntry() public {
        vm.prank(admin);
        vm.expectRevert(RecibuSettlementGuardHook.ZeroAddress.selector);
        hook.setWhitelist(address(0), true);
    }

    function test_guardParams_acceptBoundedNonzeroConfiguration() public {
        MockFeed replacement = new MockFeed();
        uint256 maxAge = hook.MAX_ORACLE_AGE_LIMIT();
        uint16 maxDeviation = hook.MAX_DEVIATION_BPS_LIMIT();
        vm.prank(admin);
        hook.setGuardParams(maxAge, maxDeviation, replacement);

        assertEq(hook.maxOracleAge(), maxAge);
        assertEq(hook.maxDeviationBps(), maxDeviation);
        assertEq(address(hook.priceFeed()), address(replacement));
    }

    function test_revert_guardParamsZeroFeed() public {
        vm.prank(admin);
        vm.expectRevert(RecibuSettlementGuardHook.ZeroAddress.selector);
        hook.setGuardParams(60, 100, IRecibuPriceFeed(address(0)));
    }

    function test_revert_guardParamsZeroAge() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(RecibuSettlementGuardHook.InvalidGuardParams.selector, uint256(0), uint16(100))
        );
        hook.setGuardParams(0, 100, feed);
    }

    function test_revert_guardParamsUnboundedAge() public {
        uint256 tooOld = hook.MAX_ORACLE_AGE_LIMIT() + 1;
        uint16 currentDeviation = hook.maxDeviationBps();
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(RecibuSettlementGuardHook.InvalidGuardParams.selector, tooOld, currentDeviation)
        );
        hook.setGuardParams(tooOld, currentDeviation, feed);
    }

    function test_revert_guardParamsUnboundedDeviation() public {
        uint16 tooWide = hook.MAX_DEVIATION_BPS_LIMIT() + 1;
        uint256 currentAge = hook.maxOracleAge();
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(RecibuSettlementGuardHook.InvalidGuardParams.selector, currentAge, tooWide)
        );
        hook.setGuardParams(currentAge, tooWide, feed);
    }

    // ── every revert path ──

    function test_revert_notPoolManager() public {
        vm.expectRevert(RecibuSettlementGuardHook.NotPoolManager.selector);
        hook.beforeSwap(
            requester, _key(), _params(), abi.encode(_ctx(invId, requester, escrow, block.timestamp + 1 hours))
        );
    }

    function test_revert_exactOutputAndZeroSpecifiedAmount() public {
        IPoolManager.SwapParams memory params = _params();
        params.amountSpecified = 100e6;
        vm.prank(poolManager);
        vm.expectRevert(
            abi.encodeWithSelector(RecibuSettlementGuardHook.ExactOutputUnsupported.selector, int256(100e6))
        );
        hook.beforeSwap(
            requester, _key(), params, abi.encode(_ctx(invId, requester, escrow, block.timestamp + 1 hours))
        );

        params.amountSpecified = 0;
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(RecibuSettlementGuardHook.ExactOutputUnsupported.selector, int256(0)));
        hook.beforeSwap(
            requester, _key(), params, abi.encode(_ctx(invId, requester, escrow, block.timestamp + 1 hours))
        );
    }

    function test_revert_zeroSqrtPriceLimit() public {
        IPoolManager.SwapParams memory params = _params();
        params.sqrtPriceLimitX96 = 0;
        vm.prank(poolManager);
        vm.expectRevert(RecibuSettlementGuardHook.ZeroSqrtPriceLimit.selector);
        hook.beforeSwap(
            requester, _key(), params, abi.encode(_ctx(invId, requester, escrow, block.timestamp + 1 hours))
        );
    }

    function test_revert_poolKeyMustMatchEveryPinnedField() public {
        PoolKey memory key = _key();
        key.currency0 = Currency.wrap(makeAddr("wrong-currency0"));
        _expectPoolKeyRevert(key);

        key = _key();
        key.currency1 = Currency.wrap(makeAddr("wrong-currency1"));
        _expectPoolKeyRevert(key);

        key = _key();
        key.fee += 1;
        _expectPoolKeyRevert(key);

        key = _key();
        key.tickSpacing += 1;
        _expectPoolKeyRevert(key);

        key = _key();
        key.hooks = makeAddr("wrong-hook");
        _expectPoolKeyRevert(key);
    }

    function _expectPoolKeyRevert(PoolKey memory key) internal {
        vm.prank(poolManager);
        vm.expectRevert(RecibuSettlementGuardHook.UnexpectedPoolKey.selector);
        hook.beforeSwap(
            requester, key, _params(), abi.encode(_ctx(invId, requester, escrow, block.timestamp + 1 hours))
        );
    }

    function test_revert_notWhitelisted() public {
        address bad = makeAddr("bad");
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(RecibuSettlementGuardHook.NotWhitelisted.selector, bad));
        hook.beforeSwap(bad, _key(), _params(), abi.encode(_ctx(invId, bad, escrow, block.timestamp + 1 hours)));
    }

    function test_revert_attackerCannotNameWhitelistedRequester() public {
        address attacker = makeAddr("attacker");
        RecibuSettlementGuardHook.RecibuSwapContext memory c = _ctx(invId, requester, escrow, block.timestamp + 1 hours);

        vm.prank(poolManager);
        vm.expectRevert(
            abi.encodeWithSelector(RecibuSettlementGuardHook.RequesterMismatch.selector, attacker, requester)
        );
        hook.beforeSwap(attacker, _key(), _params(), abi.encode(c));
    }

    function test_revert_invoiceNotFunded() public {
        vm.prank(poolManager);
        vm.expectRevert(
            abi.encodeWithSelector(RecibuSettlementGuardHook.InvoiceNotFunded.selector, bytes32(uint256(9999)))
        );
        hook.beforeSwap(
            requester, _key(), _params(), abi.encode(_ctx(9999, requester, escrow, block.timestamp + 1 hours))
        );
    }

    function test_revert_frozenWorkspace() public {
        // second invoice, same seller but a fresh debtor (concentration cap is per-debtor);
        // default IT to freeze the seller, leaving invId Funded.
        uint256 debtor2 = _ws("debtor2", 74, 87);
        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory terms =
            _newApprovedTerms(authorityVerifier, seller, debtor2, address(usdc), 100e6, 2, firstMaturity, 30 days);
        vm.prank(servicer);
        uint256 inv2 = shelf.lockInvoice(seller, debtor2, 100e6, 2, firstMaturity, 30 days, terms, _docs());
        vm.warp(block.timestamp + 30 days + Params.GRACE_STRONG + 1);
        vm.prank(servicer);
        shelf.markDefaulted(inv2);
        assertTrue(shelf.workspaceFrozen(seller));

        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(RecibuSettlementGuardHook.WorkspaceFrozen.selector, seller));
        hook.beforeSwap(
            requester, _key(), _params(), abi.encode(_ctx(invId, requester, escrow, block.timestamp + 1 hours))
        );
    }

    function test_revert_malformedFreezeLookupFailsClosed() public {
        vm.mockCall(address(shelf), abi.encodeWithSignature("workspaceFrozen(uint256)", seller), abi.encode(uint256(2)));
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(RecibuSettlementGuardHook.FreezeLookupFailed.selector, seller));
        hook.beforeSwap(
            requester, _key(), _params(), abi.encode(_ctx(invId, requester, escrow, block.timestamp + 1 hours))
        );
    }

    function test_revert_badRecipient() public {
        address evil = makeAddr("evil");
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(RecibuSettlementGuardHook.BadRecipient.selector, evil));
        hook.beforeSwap(
            requester, _key(), _params(), abi.encode(_ctx(invId, requester, evil, block.timestamp + 1 hours))
        );
    }

    function test_revert_deadlinePassed() public {
        uint256 dl = block.timestamp + 10;
        vm.warp(dl + 1);
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(RecibuSettlementGuardHook.DeadlinePassed.selector, dl));
        hook.beforeSwap(requester, _key(), _params(), abi.encode(_ctx(invId, requester, escrow, dl)));
    }

    function test_revert_zeroMinimumAmountOut() public {
        RecibuSettlementGuardHook.RecibuSwapContext memory c = _ctx(invId, requester, escrow, block.timestamp + 1 hours);
        c.minAmountOut = 0;
        vm.prank(poolManager);
        vm.expectRevert(RecibuSettlementGuardHook.ZeroMinimumAmountOut.selector);
        hook.beforeSwap(requester, _key(), _params(), abi.encode(c));
    }

    function test_revert_staleOracle() public {
        feed.set(1e18, block.timestamp); // fresh now
        vm.warp(block.timestamp + hook.maxOracleAge() + 1);
        uint256 staleAt = block.timestamp - hook.maxOracleAge() - 1;
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(RecibuSettlementGuardHook.StaleOracle.selector, staleAt));
        hook.beforeSwap(
            requester, _key(), _params(), abi.encode(_ctx(invId, requester, escrow, block.timestamp + 1 hours))
        );
    }

    function test_revert_recoveryModeCannotBypassStaleOracle() public {
        feed.set(1e18, block.timestamp);
        vm.warp(block.timestamp + hook.maxOracleAge() + 1);
        uint256 staleAt = block.timestamp - hook.maxOracleAge() - 1;
        RecibuSettlementGuardHook.RecibuSwapContext memory c = _ctx(invId, requester, escrow, block.timestamp + 1 hours);
        c.isRecoveryMode = true;

        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(RecibuSettlementGuardHook.StaleOracle.selector, staleAt));
        hook.beforeSwap(requester, _key(), _params(), abi.encode(c));
    }

    function test_revert_zeroOraclePrice() public {
        feed.set(0, block.timestamp);
        vm.prank(poolManager);
        vm.expectRevert(RecibuSettlementGuardHook.InvalidOraclePrice.selector);
        hook.beforeSwap(
            requester, _key(), _params(), abi.encode(_ctx(invId, requester, escrow, block.timestamp + 1 hours))
        );
    }

    function test_revert_futureOracleTimestamp() public {
        uint256 future = block.timestamp + 1;
        feed.set(1e18, future);
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(RecibuSettlementGuardHook.InvalidOracleTimestamp.selector, future));
        hook.beforeSwap(
            requester, _key(), _params(), abi.encode(_ctx(invId, requester, escrow, block.timestamp + 1 hours))
        );
    }

    function test_revert_deviationTooHigh() public {
        // 6-decimal currency0 to 18-decimal currency1 normalizes to a 1e18 parity mark.
        feed.set(2e18, block.timestamp);
        IPoolManager.SwapParams memory p = _params();
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(RecibuSettlementGuardHook.DeviationTooHigh.selector, uint256(5000)));
        hook.beforeSwap(requester, _key(), p, abi.encode(_ctx(invId, requester, escrow, block.timestamp + 1 hours)));
    }

    function test_oracleNormalizationHonorsPinnedInverseDirection() public {
        MockFeed inverseFeed = new MockFeed();
        inverseFeed.set(0.25e18, block.timestamp);
        RecibuSettlementGuardHook inverseHook = new RecibuSettlementGuardHook(
            poolManager,
            IInvoiceShelf(address(shelf)),
            escrow,
            settlement,
            _poolConfig(false),
            IRecibuPriceFeed(address(inverseFeed)),
            admin
        );
        vm.prank(admin);
        inverseHook.setWhitelist(requester, true);

        IPoolManager.SwapParams memory params = _params();
        params.sqrtPriceLimitX96 = PARITY_SQRT_PRICE_X96 * 2; // direct mark 4; configured inverse mark 0.25
        vm.prank(poolManager);
        inverseHook.beforeSwap(
            requester,
            _keyFor(address(inverseHook)),
            params,
            abi.encode(_ctx(invId, requester, escrow, block.timestamp + 1 hours))
        );
    }

    function test_maxSqrtPriceUsesFullPrecisionWithoutOverflow() public {
        IPoolManager.SwapParams memory params = _params();
        params.sqrtPriceLimitX96 = type(uint160).max;
        vm.prank(poolManager);
        vm.expectPartialRevert(RecibuSettlementGuardHook.DeviationTooHigh.selector);
        hook.beforeSwap(
            requester, _key(), params, abi.encode(_ctx(invId, requester, escrow, block.timestamp + 1 hours))
        );
    }

    // ── afterSwap ──

    function test_afterSwap_emitsAndGuardsRecipient() public {
        RecibuSettlementGuardHook.RecibuSwapContext memory c = _ctx(invId, requester, escrow, block.timestamp + 1 hours);
        vm.expectEmit(true, true, true, true, address(hook));
        emit RecibuSettlementGuardHook.RecibuFxSettlementSwap(
            c.invoiceId, c.workspaceId, c.settlementId, c.routeId, requester, escrow
        );
        vm.prank(poolManager);
        hook.afterSwap(requester, _key(), _params(), _successfulDelta(), abi.encode(c));

        // bad recipient rejected post-swap too
        RecibuSettlementGuardHook.RecibuSwapContext memory bad =
            _ctx(invId, requester, makeAddr("x"), block.timestamp + 1 hours);
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(RecibuSettlementGuardHook.BadRecipient.selector, bad.recipient));
        hook.afterSwap(requester, _key(), _params(), _successfulDelta(), abi.encode(bad));
    }

    function test_afterSwap_revert_attackerCannotNameWhitelistedRequester() public {
        address attacker = makeAddr("after-attacker");
        RecibuSettlementGuardHook.RecibuSwapContext memory c = _ctx(invId, requester, escrow, block.timestamp + 1 hours);

        vm.prank(poolManager);
        vm.expectRevert(
            abi.encodeWithSelector(RecibuSettlementGuardHook.RequesterMismatch.selector, attacker, requester)
        );
        hook.afterSwap(attacker, _key(), _params(), _successfulDelta(), abi.encode(c));
    }

    function test_afterSwap_revertsBelowActualMinimumOut() public {
        RecibuSettlementGuardHook.RecibuSwapContext memory c = _ctx(invId, requester, escrow, block.timestamp + 1 hours);
        c.minAmountOut = 101e6;

        vm.prank(poolManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                RecibuSettlementGuardHook.InsufficientAmountOut.selector, uint256(100e6), uint256(101e6)
            )
        );
        hook.afterSwap(requester, _key(), _params(), _successfulDelta(), abi.encode(c));
    }

    function test_afterSwap_checksCurrency0OutputForOneForZero() public {
        RecibuSettlementGuardHook.RecibuSwapContext memory c =
            _ctx(invId, requester, settlement, block.timestamp + 1 hours);
        c.minAmountOut = 80e6;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: false, amountSpecified: -100e6, sqrtPriceLimitX96: PARITY_SQRT_PRICE_X96
        });

        vm.prank(poolManager);
        hook.afterSwap(requester, _key(), params, _delta(80e6, -100e6), abi.encode(c));
    }
}
