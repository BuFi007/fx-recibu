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

contract GuardUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 a) external { _mint(to, a); }
}

contract MockFeed is IRecibuPriceFeed {
    uint256 public p;
    uint256 public t;
    function set(uint256 price_, uint256 updatedAt_) external { p = price_; t = updatedAt_; }
    function latest() external view returns (uint256, uint256) { return (p, t); }
}

contract GuardHookTest is Test {
    GuardUSDC internal usdc;
    BUFIIdentityRegistry internal identity;
    BUFIReputationRegistry internal reputation;
    WorkspaceTierRegistry internal tiers;
    InvoiceShelf internal shelf;
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

    uint256 internal seller;
    uint256 internal debtor;
    uint256 internal invId;

    function setUp() public {
        usdc = new GuardUSDC();
        identity = new BUFIIdentityRegistry(admin);
        reputation = new BUFIReputationRegistry(admin, identity);
        tiers = new WorkspaceTierRegistry(identity, reputation);
        shelf = new InvoiceShelf(usdc, identity, reputation, tiers, admin);
        feed = new MockFeed();
        hook = new RecibuSettlementGuardHook(
            poolManager, IInvoiceShelf(address(shelf)), escrow, settlement, IRecibuPriceFeed(address(feed)), admin
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

        vm.prank(servicer);
        invId = shelf.lockInvoice(seller, debtor, 500e6, 2, uint64(block.timestamp + 30 days), 30 days, _docs());

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
        return IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -100e6, sqrtPriceLimitX96: 0});
    }

    function _key() internal view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(usdc)), Currency.wrap(address(1)), 100, 1, address(hook));
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
    }

    // ── every revert path ──

    function test_revert_notPoolManager() public {
        vm.expectRevert(RecibuSettlementGuardHook.NotPoolManager.selector);
        hook.beforeSwap(requester, _key(), _params(), abi.encode(_ctx(invId, requester, escrow, block.timestamp + 1 hours)));
    }

    function test_revert_notWhitelisted() public {
        address bad = makeAddr("bad");
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(RecibuSettlementGuardHook.NotWhitelisted.selector, bad));
        hook.beforeSwap(bad, _key(), _params(), abi.encode(_ctx(invId, bad, escrow, block.timestamp + 1 hours)));
    }

    function test_revert_invoiceNotFunded() public {
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(RecibuSettlementGuardHook.InvoiceNotFunded.selector, bytes32(uint256(9999))));
        hook.beforeSwap(requester, _key(), _params(), abi.encode(_ctx(9999, requester, escrow, block.timestamp + 1 hours)));
    }

    function test_revert_frozenWorkspace() public {
        // second invoice, same seller but a fresh debtor (concentration cap is per-debtor);
        // default IT to freeze the seller, leaving invId Funded.
        uint256 debtor2 = _ws("debtor2", 74, 87);
        vm.prank(servicer);
        uint256 inv2 = shelf.lockInvoice(seller, debtor2, 100e6, 2, uint64(block.timestamp + 30 days), 30 days, _docs());
        vm.warp(block.timestamp + 30 days + Params.GRACE_STRONG + 1);
        vm.prank(servicer);
        shelf.markDefaulted(inv2);
        assertTrue(shelf.workspaceFrozen(seller));

        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(RecibuSettlementGuardHook.WorkspaceFrozen.selector, seller));
        hook.beforeSwap(requester, _key(), _params(), abi.encode(_ctx(invId, requester, escrow, block.timestamp + 1 hours)));
    }

    function test_revert_badRecipient() public {
        address evil = makeAddr("evil");
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(RecibuSettlementGuardHook.BadRecipient.selector, evil));
        hook.beforeSwap(requester, _key(), _params(), abi.encode(_ctx(invId, requester, evil, block.timestamp + 1 hours)));
    }

    function test_revert_deadlinePassed() public {
        uint256 dl = block.timestamp + 10;
        vm.warp(dl + 1);
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(RecibuSettlementGuardHook.DeadlinePassed.selector, dl));
        hook.beforeSwap(requester, _key(), _params(), abi.encode(_ctx(invId, requester, escrow, dl)));
    }

    function test_revert_staleOracle() public {
        feed.set(1e18, block.timestamp); // fresh now
        vm.warp(block.timestamp + hook.maxOracleAge() + 1);
        uint256 staleAt = block.timestamp - hook.maxOracleAge() - 1;
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(RecibuSettlementGuardHook.StaleOracle.selector, staleAt));
        hook.beforeSwap(requester, _key(), _params(), abi.encode(_ctx(invId, requester, escrow, block.timestamp + 1 hours)));
    }

    function test_revert_deviationTooHigh() public {
        // supply a sqrtPriceLimit at parity (implied 1e18) but a feed mark 2x off → 10000bps
        feed.set(2e18, block.timestamp);
        IPoolManager.SwapParams memory p =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -100e6, sqrtPriceLimitX96: uint160(2 ** 96)});
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(RecibuSettlementGuardHook.DeviationTooHigh.selector, uint256(5000)));
        hook.beforeSwap(requester, _key(), p, abi.encode(_ctx(invId, requester, escrow, block.timestamp + 1 hours)));
    }

    // ── afterSwap ──

    function test_afterSwap_emitsAndGuardsRecipient() public {
        RecibuSettlementGuardHook.RecibuSwapContext memory c = _ctx(invId, requester, escrow, block.timestamp + 1 hours);
        vm.expectEmit(true, true, true, true, address(hook));
        emit RecibuSettlementGuardHook.RecibuFxSettlementSwap(
            c.invoiceId, c.workspaceId, c.settlementId, c.routeId, requester, escrow
        );
        vm.prank(poolManager);
        hook.afterSwap(requester, _key(), _params(), int256(0), abi.encode(c));

        // bad recipient rejected post-swap too
        RecibuSettlementGuardHook.RecibuSwapContext memory bad = _ctx(invId, requester, makeAddr("x"), block.timestamp + 1 hours);
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(RecibuSettlementGuardHook.BadRecipient.selector, bad.recipient));
        hook.afterSwap(requester, _key(), _params(), int256(0), abi.encode(bad));
    }
}
