// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BUFIIdentityRegistry} from "../../src/identity/BUFIIdentityRegistry.sol";
import {BUFIReputationRegistry} from "../../src/identity/BUFIReputationRegistry.sol";
import {WorkspaceTierRegistry} from "../../src/credit/WorkspaceTierRegistry.sol";
import {InvoiceShelf} from "../../src/invoice/InvoiceShelf.sol";
import {BINV} from "../../src/invoice/BINV.sol";
import {ReceivableEscrow} from "../../src/rails/ReceivableEscrow.sol";
import {RecibuMemoRouter} from "../../src/rails/RecibuMemoRouter.sol";
import {IInvoiceShelf} from "../../src/interfaces/IInvoiceShelf.sol";
import {MockUSDC3009} from "../mocks/MockUSDC3009.sol";
import {MockPermitToken} from "../mocks/MockPermitToken.sol";
import {MockPlainToken} from "../mocks/MockPlainToken.sol";

/// @title RecibuMemoRouter unit tests — multi-currency + gasless (ERC-3009) + permit + legacy.
/// @dev The shelf/escrow are single-token by design; this suite exercises the ROUTER's per-token
///      pull+bind+event mechanics (the invoice's Funded status gates every path). Cross-token
///      economic settlement (a non-shelf-token payment settling a shelf invoice) is out of scope —
///      the desk only offers a pay-QR in the invoice's own currency.
contract RecibuMemoRouterTest is Test {
    MockUSDC3009 internal usdc; // ERC-3009 (Circle-shaped)
    MockPermitToken internal eurc; // ERC-2612 permit
    MockPlainToken internal plain; // no 3009/permit, 6 dp
    MockPlainToken internal big; // no 3009/permit, 18 dp (JPYC-like)

    BUFIIdentityRegistry internal identity;
    BUFIReputationRegistry internal reputation;
    WorkspaceTierRegistry internal tiers;
    InvoiceShelf internal shelf;
    RecibuMemoRouter internal router;

    ReceivableEscrow internal escrowU;
    ReceivableEscrow internal escrowE;
    ReceivableEscrow internal escrowP;
    ReceivableEscrow internal escrowB;

    address internal admin = makeAddr("admin");
    address internal issuer = makeAddr("issuer");
    address internal attestor = makeAddr("attestor");
    address internal servicer = makeAddr("servicer");
    address internal relayer = makeAddr("relayer");
    address internal payer;
    uint256 internal payerKey;

    uint256 internal seller;
    uint256 internal debtor;
    uint256 internal invId;

    uint128 internal constant FACE = 500e6;
    bytes32 internal constant NONCE = keccak256("nonce-1");

    function setUp() public {
        (payer, payerKey) = makeAddrAndKey("payer");

        usdc = new MockUSDC3009();
        eurc = new MockPermitToken();
        plain = new MockPlainToken("Plain", "PLN", 6);
        big = new MockPlainToken("Big", "BIG", 18);

        identity = new BUFIIdentityRegistry(admin);
        reputation = new BUFIReputationRegistry(admin, identity);
        tiers = new WorkspaceTierRegistry(identity, reputation);
        shelf = new InvoiceShelf(usdc, identity, reputation, tiers, admin);

        router = new RecibuMemoRouter(IInvoiceShelf(address(shelf)), admin);
        escrowU = new ReceivableEscrow(usdc, admin);
        escrowE = new ReceivableEscrow(eurc, admin);
        escrowP = new ReceivableEscrow(plain, admin);
        escrowB = new ReceivableEscrow(big, admin);

        vm.startPrank(admin);
        identity.grantRole(identity.ISSUER_ROLE(), issuer);
        reputation.grantRole(reputation.ATTESTOR_ROLE(), attestor);
        reputation.grantRole(reputation.SETTLEMENT_ROLE(), address(shelf));
        shelf.grantRole(shelf.SERVICER_ROLE(), servicer);
        escrowU.grantRole(escrowU.ROUTER_ROLE(), address(router));
        escrowE.grantRole(escrowE.ROUTER_ROLE(), address(router));
        escrowP.grantRole(escrowP.ROUTER_ROLE(), address(router));
        escrowB.grantRole(escrowB.ROUTER_ROLE(), address(router));
        router.setToken(address(usdc), true, router.CAP_3009(), escrowU);
        router.setToken(address(eurc), true, router.CAP_PERMIT(), escrowE);
        router.setToken(address(plain), true, 0, escrowP);
        router.setToken(address(big), true, 0, escrowB);
        vm.stopPrank();

        seller = _ws("seller", makeAddr("sellerOwner"), 74, 74);
        debtor = _ws("debtor", makeAddr("dOwner"), 74, 87);

        address lp = makeAddr("lp");
        usdc.mint(lp, 1_000_000e6);
        vm.startPrank(lp);
        usdc.approve(address(shelf), type(uint256).max);
        shelf.depositTranche(2, 1_000_000e6);
        vm.stopPrank();

        vm.prank(servicer);
        invId = shelf.lockInvoice(seller, debtor, FACE, 2, uint64(block.timestamp + 30 days), 30 days, _docs());

        // Fund the payer in every token.
        usdc.mint(payer, 1_000_000e6);
        eurc.mint(payer, 1_000_000e6);
        plain.mint(payer, 1_000_000e6);
        big.mint(payer, 1_000e18);
    }

    // ── ERC-3009: gasless, one signed action ─────────────────────────────────

    function test_payWithAuthorization_gaslessOneTx() public {
        uint256 amount = 250e6;
        (uint8 v, bytes32 r, bytes32 s) = _sign3009(payer, address(router), amount, 0, block.timestamp + 1 hours, NONCE);

        // NO prior approve. A relayer submits; gas is paid by the relayer, not the payer.
        vm.expectEmit(true, true, true, true, address(router));
        emit RecibuMemoRouter.RecibuPayment(invId, 0, router.memoIdOf(invId, 0), address(usdc), amount, payer);
        vm.prank(relayer);
        router.payWithAuthorization(
            address(usdc), payer, invId, 0, amount, 0, block.timestamp + 1 hours, NONCE, v, r, s
        );

        assertEq(escrowU.escrowedOf(invId), amount);
        assertEq(usdc.balanceOf(address(escrowU)), amount);
        assertEq(usdc.balanceOf(payer), 1_000_000e6 - amount);
        assertEq(usdc.allowance(payer, address(router)), 0); // never approved
        assertTrue(usdc.authorizationState(payer, NONCE));
    }

    function test_payWithAuthorization_replayReverts() public {
        uint256 amount = 100e6;
        (uint8 v, bytes32 r, bytes32 s) = _sign3009(payer, address(router), amount, 0, block.timestamp + 1 hours, NONCE);
        vm.prank(relayer);
        router.payWithAuthorization(
            address(usdc), payer, invId, 0, amount, 0, block.timestamp + 1 hours, NONCE, v, r, s
        );

        vm.prank(relayer);
        vm.expectRevert(MockUSDC3009.AuthUsed.selector);
        router.payWithAuthorization(
            address(usdc), payer, invId, 0, amount, 0, block.timestamp + 1 hours, NONCE, v, r, s
        );
    }

    function test_payWithAuthorization_expiredReverts() public {
        uint256 amount = 100e6;
        uint256 validBefore = block.timestamp; // now >= validBefore → expired
        (uint8 v, bytes32 r, bytes32 s) = _sign3009(payer, address(router), amount, 0, validBefore, NONCE);
        vm.prank(relayer);
        vm.expectRevert(MockUSDC3009.AuthExpired.selector);
        router.payWithAuthorization(address(usdc), payer, invId, 0, amount, 0, validBefore, NONCE, v, r, s);
    }

    function test_payWithAuthorization_capMissingReverts() public {
        // `plain` is allowed but has no 3009 capability.
        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(RecibuMemoRouter.CapabilityMissing.selector, address(plain), router.CAP_3009())
        );
        router.payWithAuthorization(address(plain), payer, invId, 0, 1e6, 0, block.timestamp + 1 hours, NONCE, 0, 0, 0);
    }

    // ── ERC-2612 permit ──────────────────────────────────────────────────────

    function test_payWithPermit_oneTx() public {
        uint256 amount = 100e6;
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(payer, address(router), amount, deadline);

        // Relayer submits `payer`'s signed permit — no prior approve.
        vm.prank(relayer);
        router.payWithPermit(address(eurc), payer, invId, 0, amount, deadline, v, r, s);

        assertEq(escrowE.escrowedOf(invId), amount);
        assertEq(eurc.balanceOf(address(escrowE)), amount);
        assertEq(eurc.balanceOf(payer), 1_000_000e6 - amount);
    }

    // ── legacy fallback + guards ─────────────────────────────────────────────

    function test_pay_legacyApprove() public {
        uint256 amount = 250e6;
        vm.startPrank(payer);
        plain.approve(address(router), amount);
        router.pay(address(plain), invId, 0, amount);
        vm.stopPrank();
        assertEq(escrowP.escrowedOf(invId), amount);
    }

    function test_pay_nonSixDecimalToken() public {
        uint256 amount = 5e18; // 18-dp token, base units
        vm.startPrank(payer);
        big.approve(address(router), amount);
        router.pay(address(big), invId, 0, amount);
        vm.stopPrank();
        assertEq(escrowB.escrowedOf(invId), amount);
    }

    function test_pay_unregisteredTokenReverts() public {
        MockPlainToken rogue = new MockPlainToken("Rogue", "RGE", 6);
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(RecibuMemoRouter.TokenNotAllowed.selector, address(rogue)));
        router.pay(address(rogue), invId, 0, 1e6);
    }

    function test_pay_unfundedInvoiceReverts() public {
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(RecibuMemoRouter.InvoiceNotFunded.selector, uint256(999)));
        router.pay(address(plain), 999, 0, 1e6);
    }

    function test_pay_zeroAmountReverts() public {
        vm.prank(payer);
        vm.expectRevert(RecibuMemoRouter.ZeroAmount.selector);
        router.pay(address(plain), invId, 0, 0);
    }

    function test_setToken_escrowMismatchReverts() public {
        // escrowE is a EURC escrow; registering it for `usdc` must revert.
        uint8 cap = router.CAP_3009();
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(RecibuMemoRouter.EscrowTokenMismatch.selector, address(usdc), address(eurc))
        );
        router.setToken(address(usdc), true, cap, escrowE);
    }

    function test_memoIdParity() public view {
        assertEq(router.memoIdOf(invId, 3), keccak256(abi.encodePacked(invId, uint8(3))));
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _sign3009(address from, address to, uint256 value, uint256 validAfter, uint256 validBefore, bytes32 nonce)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash = keccak256(
            abi.encode(usdc.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(), from, to, value, validAfter, validBefore, nonce)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(payerKey, digest);
    }

    function _signPermit(address owner_, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 permitTypehash =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 structHash =
            keccak256(abi.encode(permitTypehash, owner_, spender, value, eurc.nonces(owner_), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", eurc.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(payerKey, digest);
    }

    function _ws(string memory tag, address owner_, uint8 s, uint8 d) internal returns (uint256 id) {
        vm.startPrank(issuer);
        id = identity.registerWorkspace(keccak256(bytes(tag)), owner_);
        identity.setKybStatus(id, true);
        vm.stopPrank();
        vm.prank(attestor);
        reputation.setScore(id, s, d, 1, bytes32("r"));
    }

    function _docs() internal pure returns (BINV.DocBundle memory) {
        return BINV.DocBundle(bytes32("i"), bytes32("a"), bytes32("p"), bytes32("s"), bytes32("d"));
    }
}
