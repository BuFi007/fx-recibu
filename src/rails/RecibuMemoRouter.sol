// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IInvoiceShelf} from "../interfaces/IInvoiceShelf.sol";
import {IERC3009} from "../interfaces/IERC3009.sol";
import {IERC2612} from "../interfaces/IERC2612.sol";
import {ReceivableEscrow} from "./ReceivableEscrow.sol";

/// @title RecibuMemoRouter — multi-currency, gasless, one-signed-action memo settlement front door.
///
/// Generalizes InvoiceMemoRouter (single immutable USDC + approve→pay) into a token-parametrized
/// router with three entrypoints that all pull the payment token, bind it in that token's escrow,
/// and emit the Arc-Memo twin `RecibuPayment{token,…}`:
///   • payWithAuthorization — ERC-3009 `receiveWithAuthorization`: gasless for the payer, no prior
///     approve, one tx, replay- + expiry-safe. USDC/EURC support this natively.
///   • payWithPermit        — ERC-2612 `permit`: signed approval + pull in one tx.
///   • pay                  — legacy approve→transferFrom fallback for tokens with neither.
///
/// NOT EIP-1363: that is a token-side standard our third-party stablecoins don't implement. See
/// docs/superpowers/specs/2026-07-09-erc3009-gasless-memo-settlement.md.
///
/// Multi-currency: each allowed token maps to its OWN ReceivableEscrow (the escrow is single-token
/// by design — Σ escrowedOf == token held). `setToken` is the registry-sourced allowlist; adding a
/// stablecoin is a config action, never a redeploy. Settlement stays separate (InvoiceSettlement /
/// the CRE keeper reacting to `RecibuPayment`) — this router is the thin, auditable deposit path.
contract RecibuMemoRouter is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// Capability bitfield — which signed-pull primitives a token supports.
    uint8 public constant CAP_3009 = 1 << 0;
    uint8 public constant CAP_PERMIT = 1 << 1;

    struct TokenConfig {
        bool allowed;
        uint8 caps; // CAP_3009 | CAP_PERMIT
        ReceivableEscrow escrow; // per-token escrow (escrow.USDC() == token)
    }

    IInvoiceShelf public immutable SHELF;
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
    error TokenNotAllowed(address token);
    error CapabilityMissing(address token, uint8 required);
    error EscrowTokenMismatch(address token, address escrowToken);

    constructor(IInvoiceShelf shelf, address admin) {
        SHELF = shelf;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice canonical Arc-Memo reconciliation key — byte-identical to InvoiceMemoRouter +
    ///         computeShelfMemoId (desk) so on/off-chain settlement reconcile.
    function memoIdOf(uint256 invoiceId, uint8 installment) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(invoiceId, installment));
    }

    // ── admin: registry-sourced token allowlist ──────────────────────────────

    /// @notice enable/disable a settlement token + its per-token escrow + capabilities.
    ///         The escrow MUST be deployed for `token` (single-token invariant).
    function setToken(address token, bool allowed, uint8 caps, ReceivableEscrow escrow)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (allowed && address(escrow.USDC()) != token) {
            revert EscrowTokenMismatch(token, address(escrow.USDC()));
        }
        tokenConfig[token] = TokenConfig(allowed, caps, escrow);
        emit TokenConfigured(token, allowed, caps, address(escrow));
    }

    // ── pay: three entrypoints, one downstream ───────────────────────────────

    /// @notice legacy path — needs a prior `token.approve(router, amount)`. Fallback for tokens
    ///         with neither ERC-3009 nor ERC-2612.
    function pay(address token, uint256 invoiceId, uint8 installment, uint256 amount) external nonReentrant {
        TokenConfig memory cfg = _guard(token, invoiceId, amount);
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        _bind(cfg, token, invoiceId, installment, amount, msg.sender);
    }

    /// @notice ERC-2612 permit — `owner`'s signed approval + pull in one tx (no prior approve).
    ///         Relayable: any caller may submit on behalf of `owner` (the payer/signer).
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
        TokenConfig memory cfg = _guard(token, invoiceId, amount);
        if (cfg.caps & CAP_PERMIT == 0) revert CapabilityMissing(token, CAP_PERMIT);
        // Permit can be front-run (griefed) into a used state; tolerate a pre-existing allowance
        // and let the transferFrom below be the source of truth.
        try IERC2612(token).permit(owner, address(this), amount, deadline, v, r, s) {} catch {}
        IERC20(token).safeTransferFrom(owner, address(this), amount);
        _bind(cfg, token, invoiceId, installment, amount, owner);
    }

    /// @notice ERC-3009 receiveWithAuthorization — gasless for `from`, one tx, no approve.
    ///         `from` is the off-chain signer; any relayer may submit. The token binds the
    ///         authorization to this router (`to == address(this)`), so it can't be front-run.
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
    ) external nonReentrant {
        TokenConfig memory cfg = _guard(token, invoiceId, amount);
        if (cfg.caps & CAP_3009 == 0) revert CapabilityMissing(token, CAP_3009);
        IERC3009(token).receiveWithAuthorization(from, address(this), amount, validAfter, validBefore, nonce, v, r, s);
        _bind(cfg, token, invoiceId, installment, amount, from);
    }

    // ── internals ────────────────────────────────────────────────────────────

    function _guard(address token, uint256 invoiceId, uint256 amount) internal view returns (TokenConfig memory cfg) {
        if (amount == 0) revert ZeroAmount();
        cfg = tokenConfig[token];
        if (!cfg.allowed) revert TokenNotAllowed(token);
        if (SHELF.invoiceStatus(invoiceId) != IInvoiceShelf.Status.Funded) revert InvoiceNotFunded(invoiceId);
    }

    /// @dev token now sits in the router; bind it in the per-token escrow + emit the twin event.
    function _bind(
        TokenConfig memory cfg,
        address token,
        uint256 invoiceId,
        uint8 installment,
        uint256 amount,
        address from
    ) internal {
        IERC20(token).forceApprove(address(cfg.escrow), amount);
        cfg.escrow.deposit(invoiceId, amount, address(this));
        emit RecibuPayment(invoiceId, installment, memoIdOf(invoiceId, installment), token, amount, from);
    }
}
