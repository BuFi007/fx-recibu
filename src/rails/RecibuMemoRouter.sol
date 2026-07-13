// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IInvoiceShelf} from "../interfaces/IInvoiceShelf.sol";
import {IERC3009} from "../interfaces/IERC3009.sol";
import {IERC2612} from "../interfaces/IERC2612.sol";
import {InvoiceInstallmentKey} from "../libraries/InvoiceInstallmentKey.sol";
import {ReceivableEscrow} from "./ReceivableEscrow.sol";

/// @title RecibuMemoRouter — canonical-currency, gasless, one-signed-action memo settlement front door.
///
/// Generalizes InvoiceMemoRouter (single immutable USDC + approve→pay) into a capability-aware
/// router with three entrypoints that all pull the shelf's canonical settlement token, bind it in
/// the shelf's canonical escrow,
/// and emit the Arc-Memo twin `RecibuPayment{token,…}`:
///   • payWithAuthorization — ERC-3009 `receiveWithAuthorization`: gasless for the payer, no prior
///     approve, one tx, replay- + expiry-safe. USDC/EURC support this natively.
///   • payWithPermit        — ERC-2612 `permit`: signed approval + pull in one tx.
///   • pay                  — legacy approve→transferFrom fallback for tokens with neither.
///
/// NOT EIP-1363: that is a token-side standard our third-party stablecoins don't implement. See
/// docs/superpowers/specs/2026-07-09-erc3009-gasless-memo-settlement.md.
///
/// Alternate-token settlement is intentionally inactive: InvoiceShelf and InvoiceSettlement observe
/// one canonical token/escrow, so accepting another token here would strand custody. A reviewed FX
/// conversion registry must land before this fail-closed constraint can be widened. The capability
/// registry remains useful for selecting ERC-3009, ERC-2612, or approve→pay on the canonical token.
contract RecibuMemoRouter is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// Capability bitfield — which signed-pull primitives a token supports.
    uint8 public constant CAP_3009 = 1 << 0;
    uint8 public constant CAP_PERMIT = 1 << 1;
    /// @notice Trusted DCW/CRE submitters for ERC-3009 memo payments.
    /// @dev The role is an operational ingress boundary, while the deterministic
    ///      ERC-3009 nonce below cryptographically commits the signed token
    ///      authorization to the complete invoice/installment payment tuple.
    bytes32 public constant MEMO_RELAYER_ROLE = keccak256("MEMO_RELAYER_ROLE");
    bytes32 public constant MEMO_AUTHORIZATION_NONCE_TYPEHASH = keccak256(
        "RecibuMemoAuthorization(uint256 chainId,address router,address token,address from,uint256 invoiceId,uint8 installment,uint256 amount,uint256 validAfter,uint256 validBefore)"
    );

    struct TokenConfig {
        bool allowed;
        uint8 caps; // CAP_3009 | CAP_PERMIT
        ReceivableEscrow escrow; // per-token escrow (escrow.USDC() == token)
    }

    IInvoiceShelf public immutable SHELF;
    address public immutable SETTLEMENT_TOKEN;
    ReceivableEscrow public immutable settlementEscrow;
    mapping(address => TokenConfig) public tokenConfig;

    event RecibuPayment(
        uint256 indexed invoiceId,
        uint8 indexed installment,
        bytes32 indexed memoId,
        address token,
        uint256 amount,
        address from
    );
    event TokenConfigured(address indexed token, bool allowed, uint8 caps, address escrow);

    error ZeroAmount();
    error InvoiceNotFunded(uint256 invoiceId);
    error InstallmentMismatch(uint256 invoiceId, uint8 supplied, uint8 expected);
    error TokenNotAllowed(address token);
    error CapabilityMissing(address token, uint8 required);
    error EscrowTokenMismatch(address token, address escrowToken);
    error ZeroSettlementToken();
    error ZeroSettlementEscrow();
    error NonCanonicalSettlementToken(address token, address expectedToken);
    error CanonicalEscrowMismatch(address escrow, address expectedEscrow);
    error InvalidInstallmentAccounting(uint256 invoiceId, uint256 fullAmount, uint256 paidAmount);
    error PaymentExceedsInstallmentRemaining(
        uint256 invoiceId, address token, uint256 attemptedAmount, uint256 shelfRemaining, uint256 pendingEscrow
    );
    error InvalidRefundWindow(uint256 invoiceId, uint256 maturity, uint256 graceEndsAt);
    error RefundUnlockOverflow(uint256 invoiceId, uint256 depositTimestamp, uint256 lockDuration);
    error UnauthorizedPayer(uint256 invoiceId, address payer, address expectedPayer);
    error PermitCallerMustBeOwner(address caller, address owner);
    error MemoAuthorizationNonceMismatch(bytes32 received, bytes32 expected);

    constructor(IInvoiceShelf shelf, address admin) {
        SHELF = shelf;
        address settlementToken = shelf.USDC();
        if (settlementToken == address(0)) revert ZeroSettlementToken();
        SETTLEMENT_TOKEN = settlementToken;
        address canonicalEscrow = shelf.escrow();
        if (canonicalEscrow == address(0)) revert ZeroSettlementEscrow();
        settlementEscrow = ReceivableEscrow(canonicalEscrow);
        address escrowToken = address(settlementEscrow.USDC());
        if (escrowToken != settlementToken) revert EscrowTokenMismatch(settlementToken, escrowToken);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice canonical Arc-Memo reconciliation key — byte-identical to InvoiceMemoRouter +
    ///         computeShelfMemoId (desk) so on/off-chain settlement reconcile.
    function memoIdOf(uint256 invoiceId, uint8 installment) public pure returns (bytes32) {
        return InvoiceInstallmentKey.memoId(invoiceId, installment);
    }

    /// @notice The ERC-3009 nonce that binds one token authorization to one Recibu memo payment.
    /// @dev The stablecoin validates the signature over this nonce. DCW/CRE remains a trusted
    ///      relayer boundary, but cannot substitute the invoice, installment, payer, amount,
    ///      token, router, validity window, or chain without invalidating this commitment.
    function memoAuthorizationNonceOf(
        address token,
        address from,
        uint256 invoiceId,
        uint8 installment,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                MEMO_AUTHORIZATION_NONCE_TYPEHASH,
                block.chainid,
                address(this),
                token,
                from,
                invoiceId,
                installment,
                amount,
                validAfter,
                validBefore
            )
        );
    }

    // ── admin: registry-sourced token allowlist ──────────────────────────────

    /// @notice Enable/disable capabilities for the shelf's canonical settlement token.
    /// @dev The first enabled escrow is pinned. Alternate tokens/escrows remain fail-closed until
    ///      an FX conversion layer can atomically deliver canonical assets to InvoiceSettlement.
    function setToken(address token, bool allowed, uint8 caps, ReceivableEscrow escrow)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (allowed) {
            if (token != SETTLEMENT_TOKEN) revert NonCanonicalSettlementToken(token, SETTLEMENT_TOKEN);
            address escrowToken = address(escrow.USDC());
            if (escrowToken != token) revert EscrowTokenMismatch(token, escrowToken);
            address canonicalEscrow = address(settlementEscrow);
            if (address(escrow) != canonicalEscrow) {
                revert CanonicalEscrowMismatch(address(escrow), canonicalEscrow);
            }
        }
        tokenConfig[token] = TokenConfig(allowed, caps, escrow);
        emit TokenConfigured(token, allowed, caps, address(escrow));
    }

    // ── pay: three entrypoints, one downstream ───────────────────────────────

    /// @notice legacy path — needs a prior `token.approve(router, amount)`. Fallback for tokens
    ///         with neither ERC-3009 nor ERC-2612.
    function pay(address token, uint256 invoiceId, uint8 installment, uint256 amount) external nonReentrant {
        (TokenConfig memory cfg, uint64 refundUnlockAt) = _guard(token, msg.sender, invoiceId, installment, amount);
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        _bind(cfg, token, invoiceId, installment, amount, msg.sender, refundUnlockAt);
    }

    /// @notice ERC-2612 permit — `owner`'s signed approval + pull in one owner-submitted tx.
    /// @dev ERC-2612 cannot bind arbitrary invoice metadata, so this path is deliberately
    ///      non-relayable and fails closed on every invalid or already-used permit.
    function payWithPermit(
        address token,
        address owner,
        uint256 invoiceId,
        uint8 installment,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant {
        (TokenConfig memory cfg, uint64 refundUnlockAt) = _guard(token, owner, invoiceId, installment, amount);
        if (cfg.caps & CAP_PERMIT == 0) revert CapabilityMissing(token, CAP_PERMIT);
        // ERC-2612 has no caller-supplied nonce that can bind invoice metadata. Keep this
        // one-transaction path owner-submitted so a relayer cannot substitute an invoice.
        if (msg.sender != owner) revert PermitCallerMustBeOwner(msg.sender, owner);
        // Fail closed: an invalid/used permit is never rescued by a standing allowance.
        IERC2612(token).permit(owner, address(this), amount, deadline, v, r, s);
        IERC20(token).safeTransferFrom(owner, address(this), amount);
        _bind(cfg, token, invoiceId, installment, amount, owner, refundUnlockAt);
    }

    /// @notice ERC-3009 receiveWithAuthorization — gasless for `from`, one tx, no approve.
    /// @dev `from` is the off-chain signer; only a trusted DCW/CRE memo relayer may submit.
    ///      The stablecoin does not understand invoice semantics: BUFI creates that binding
    ///      by requiring the signed nonce to equal {memoAuthorizationNonceOf}.
    function payWithAuthorization(
        address token,
        address from,
        uint256 invoiceId,
        uint8 installment,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external onlyRole(MEMO_RELAYER_ROLE) nonReentrant {
        (TokenConfig memory cfg, uint64 refundUnlockAt) = _guard(token, from, invoiceId, installment, amount);
        if (cfg.caps & CAP_3009 == 0) revert CapabilityMissing(token, CAP_3009);
        bytes32 expectedNonce =
            memoAuthorizationNonceOf(token, from, invoiceId, installment, amount, validAfter, validBefore);
        if (nonce != expectedNonce) revert MemoAuthorizationNonceMismatch(nonce, expectedNonce);
        IERC3009(token).receiveWithAuthorization(from, address(this), amount, validAfter, validBefore, nonce, v, r, s);
        _bind(cfg, token, invoiceId, installment, amount, from, refundUnlockAt);
    }

    // ── internals ────────────────────────────────────────────────────────────

    function _guard(address token, address payer, uint256 invoiceId, uint8 installment, uint256 amount)
        internal
        view
        returns (TokenConfig memory cfg, uint64 refundUnlockAt)
    {
        if (amount == 0) revert ZeroAmount();
        cfg = tokenConfig[token];
        if (!cfg.allowed) revert TokenNotAllowed(token);
        if (token != SETTLEMENT_TOKEN) revert NonCanonicalSettlementToken(token, SETTLEMENT_TOKEN);
        address canonicalEscrow = SHELF.escrow();
        if (address(cfg.escrow) != canonicalEscrow || canonicalEscrow != address(settlementEscrow)) {
            revert CanonicalEscrowMismatch(address(cfg.escrow), canonicalEscrow);
        }
        if (SHELF.invoiceStatus(invoiceId) != IInvoiceShelf.Status.Funded) revert InvoiceNotFunded(invoiceId);
        address expectedPayer = SHELF.debtorPayerOf(invoiceId);
        if (payer != expectedPayer) revert UnauthorizedPayer(invoiceId, payer, expectedPayer);
        (uint8 expectedInstallment, uint256 fullAmount, uint256 paidAmount, uint256 maturity, uint256 graceEndsAt) =
            SHELF.currentInstallment(invoiceId);
        if (installment != expectedInstallment) {
            revert InstallmentMismatch(invoiceId, installment, expectedInstallment);
        }
        if (paidAmount > fullAmount) revert InvalidInstallmentAccounting(invoiceId, fullAmount, paidAmount);
        uint256 shelfRemaining = fullAmount - paidAmount;
        uint256 pendingEscrow = cfg.escrow.escrowedOf(invoiceId);
        if (pendingEscrow > shelfRemaining || amount > shelfRemaining - pendingEscrow) {
            revert PaymentExceedsInstallmentRemaining(invoiceId, token, amount, shelfRemaining, pendingEscrow);
        }
        if (graceEndsAt <= maturity) revert InvalidRefundWindow(invoiceId, maturity, graceEndsAt);
        uint256 lockDuration = graceEndsAt - maturity;
        if (lockDuration > type(uint64).max || block.timestamp > type(uint64).max - lockDuration) {
            revert RefundUnlockOverflow(invoiceId, block.timestamp, lockDuration);
        }
        refundUnlockAt = uint64(block.timestamp + lockDuration);
    }

    /// @dev token now sits in the router; bind it in the per-token escrow + emit the twin event.
    function _bind(
        TokenConfig memory cfg,
        address token,
        uint256 invoiceId,
        uint8 installment,
        uint256 amount,
        address from,
        uint64 refundUnlockAt
    ) internal {
        IERC20(token).forceApprove(address(cfg.escrow), amount);
        cfg.escrow.depositWithRefundLock(invoiceId, amount, address(this), refundUnlockAt);
        emit RecibuPayment(invoiceId, installment, memoIdOf(invoiceId, installment), token, amount, from);
    }
}
