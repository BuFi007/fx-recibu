// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBUFIIdentityRegistry} from "../interfaces/IBUFIIdentityRegistry.sol";
import {IBUFIReputationRegistry} from "../interfaces/IBUFIReputationRegistry.sol";
import {WorkspaceTierRegistry} from "../credit/WorkspaceTierRegistry.sol";
import {BINV} from "./BINV.sol";
import {BIFTranche} from "./BIFTranche.sol";
import {Params} from "../libraries/Params.sol";

/// @title InvoiceShelf — the single custodian of locked invoices (M3, Tinlake-Shelf-inspired design lineage; no AGPL code)
///
///  lockInvoice (SERVICER attests docs)                         apply memo inflow
///        │ caps: L(w) · debtor-concentration · velocity              │
///        ▼                                                           ▼
///  mint bINV ─▶ advance = face×rate − holdback ─▶ installments ─▶ applyPayment
///        │            (USDC out of tranche liquidity)                │ on-time → reputation++
///        │                                                           │ (the ONLY L(w) raiser)
///        ▼                                                           ▼
///  markDefaulted (past grace) ──▶ §4.8 waterfall: holdback → [reserve → recourse M4] → C → B → A
///        └─ one-way workspace freeze (cross-default; extracted to registry in M4)
///
/// FRAUD-CONTAINMENT INVARIANTS (test/invariant/ShelfInvariants.t.sol):
///   I1 atRiskExposure(w) ≤ L(w)                      (SPEC §3.5/§4.9)
///   I2 loss allocation strictly C→B→A                (SPEC §4.8 layers 4–6)
///   I3 Σ trancheAssets + holdbacks ≤ USDC under management (no NAV inflation)
contract InvoiceShelf is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant SERVICER_ROLE = keccak256("SERVICER_ROLE");

    enum Status {
        None,
        Funded,
        Settled,
        Defaulted
    }

    struct Invoice {
        uint256 sellerAgentId;
        uint256 debtorAgentId;
        uint128 face; // USDC 6-dec
        uint128 advance; // funded to seller at lock
        uint128 outstanding; // advance not yet repaid
        uint128 holdback; // face − advance (notional): the seller's residual, paid by the debtor
        uint128 holdbackCollected; // debtor payments received beyond the advance — CASH held here
        uint64 firstMaturity;
        uint32 interval;
        uint32 grace;
        uint8 nInstallments;
        uint8 paidInstallments;
        uint8 tranche; // 0=A 1=B 2=C — the most-junior eligible tranche funds it
        Status status;
    }

    IERC20 public immutable USDC;
    IBUFIIdentityRegistry public immutable IDENTITY;
    IBUFIReputationRegistry public immutable REPUTATION;
    WorkspaceTierRegistry public immutable TIERS;
    BINV public immutable BINV_TOKEN;
    BIFTranche[3] public tranches; // [A, B, C]

    uint256 public nextInvoiceId = 1;
    mapping(uint256 => Invoice) public invoices;

    /// @dev I1 accounting: per-seller aggregate outstanding + per-(seller,debtor) outstanding
    mapping(uint256 => uint256) public outstandingOf;
    mapping(uint256 => mapping(uint256 => uint256)) public debtorOutstandingOf;
    /// @dev velocity: advances started per epoch (SPEC §3.5)
    mapping(uint256 => mapping(uint256 => uint256)) public advancesInEpoch;
    /// @dev one-way cross-default flip (M4 extracts to its own registry)
    mapping(uint256 => bool) public workspaceFrozen;

    /// @dev tranche asset accounting (SPEC §6.2): principal deployed + liquid, minus allocated losses
    uint256[3] public trancheLiquid; // undeployed USDC per tranche
    uint256[3] public tranchePrincipal; // outstanding advances funded per tranche
    uint256[3] public trancheLoss; // realized losses allocated (C fills first)

    event InvoiceLocked(
        uint256 indexed invoiceId, uint256 indexed sellerAgentId, uint256 indexed debtorAgentId, uint128 face, uint128 advance, uint8 tranche
    );
    event InstallmentPaid(uint256 indexed invoiceId, uint8 index, uint256 amount, bool onTime);
    event InvoiceSettled(uint256 indexed invoiceId, uint256 holdbackReleased);
    event InvoiceDefaulted(uint256 indexed invoiceId, uint256 lossAfterHoldback);
    event LossAllocated(uint8 indexed tranche, uint256 amount);
    event TrancheDeposit(uint8 indexed tranche, address indexed lp, uint256 assets, uint256 shares);
    event WorkspaceFrozen(uint256 indexed agentId);

    error NotEligible(uint256 agentId);
    error Frozen(uint256 agentId);
    error ExposureCapExceeded(uint256 agentId, uint256 requested, uint256 headroom);
    error ConcentrationCapExceeded(uint256 debtorAgentId);
    error VelocityCapExceeded(uint256 agentId);
    error BadSchedule();
    error BadStatus(uint256 invoiceId);
    error InsufficientTrancheLiquidity(uint8 tranche);
    error NotPastGrace();
    error ZeroAmount();

    constructor(
        IERC20 usdc,
        IBUFIIdentityRegistry identity_,
        IBUFIReputationRegistry reputation_,
        WorkspaceTierRegistry tiers_,
        address admin
    ) {
        USDC = usdc;
        IDENTITY = identity_;
        REPUTATION = reputation_;
        TIERS = tiers_;
        BINV_TOKEN = new BINV(address(this));
        tranches[0] = new BIFTranche("BUFI Invoice Senior", "bIF-A", address(this));
        tranches[1] = new BIFTranche("BUFI Invoice Mezzanine", "bIF-B", address(this));
        tranches[2] = new BIFTranche("BUFI Invoice Junior", "bIF-C", address(this));
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ── LP side (M3: par-NAV deposits; BUFIOracle NAV pricing lands next milestone) ──

    function depositTranche(uint8 tranche, uint256 assets) external nonReentrant returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        USDC.safeTransferFrom(msg.sender, address(this), assets);
        trancheLiquid[tranche] += assets;
        shares = assets * 1e12; // 6-dec USDC → 18-dec shares at par
        tranches[tranche].mint(msg.sender, shares);
        emit TrancheDeposit(tranche, msg.sender, assets, shares);
    }

    // ── Lock (SPEC §3) ──────────────────────────────────────────────────

    function lockInvoice(
        uint256 sellerAgentId,
        uint256 debtorAgentId,
        uint128 face,
        uint8 nInstallments,
        uint64 firstMaturity,
        uint32 interval,
        BINV.DocBundle calldata docs
    ) external onlyRole(SERVICER_ROLE) nonReentrant returns (uint256 invoiceId) {
        // v2v hard gate: KYB'd + not defaulted, both sides (SPEC §1)
        if (!TIERS.eligible(sellerAgentId)) revert NotEligible(sellerAgentId);
        if (!TIERS.eligible(debtorAgentId)) revert NotEligible(debtorAgentId);
        if (workspaceFrozen[sellerAgentId]) revert Frozen(sellerAgentId);
        if (
            nInstallments < Params.MIN_INSTALLMENTS || nInstallments > Params.MAX_INSTALLMENTS
                || interval < Params.MIN_INSTALLMENT_INTERVAL || firstMaturity <= block.timestamp || face == 0
        ) revert BadSchedule();

        bool pair = TIERS.hasPairHistory(sellerAgentId, debtorAgentId);
        IBUFIReputationRegistry.ScoreSnapshot memory sellerS = REPUTATION.scoreOf(sellerAgentId);
        IBUFIReputationRegistry.ScoreSnapshot memory debtorS = REPUTATION.scoreOf(debtorAgentId);

        uint128 advance = uint128((uint256(face) * TIERS.advanceRateBps(debtorS.debtorScore, pair)) / Params.BPS);

        // I1 — the fraud ramp (SPEC §3.5)
        uint256 limit = TIERS.limitOf(sellerAgentId);
        uint256 current = outstandingOf[sellerAgentId];
        if (current + advance > limit) revert ExposureCapExceeded(sellerAgentId, advance, limit - current);
        // debtor concentration
        uint256 debtorCap = TIERS.debtorConcentrationCap(sellerAgentId);
        if (debtorOutstandingOf[sellerAgentId][debtorAgentId] + advance > debtorCap) {
            revert ConcentrationCapExceeded(debtorAgentId);
        }
        // velocity
        uint256 epoch = block.timestamp / Params.EPOCH_LENGTH;
        if (advancesInEpoch[sellerAgentId][epoch] >= Params.MAX_ADVANCES_PER_EPOCH) {
            revert VelocityCapExceeded(sellerAgentId);
        }
        advancesInEpoch[sellerAgentId][epoch] += 1;

        // tranche placement (SPEC §3.4) — funded from the most-junior eligible bucket
        uint8 tranche = uint8(TIERS.trancheEligibility(sellerS.sellerScore, debtorS.debtorScore, pair));
        if (trancheLiquid[tranche] < advance) revert InsufficientTrancheLiquidity(tranche);

        invoiceId = nextInvoiceId++;
        uint32 grace = TIERS.tierOf(sellerS.sellerScore) >= WorkspaceTierRegistry.Tier.Strong
            ? Params.GRACE_STRONG
            : Params.GRACE_WEAK;
        invoices[invoiceId] = Invoice({
            sellerAgentId: sellerAgentId,
            debtorAgentId: debtorAgentId,
            face: face,
            advance: advance,
            outstanding: advance,
            holdback: face - advance,
            holdbackCollected: 0,
            firstMaturity: firstMaturity,
            interval: interval,
            grace: grace,
            nInstallments: nInstallments,
            paidInstallments: 0,
            tranche: tranche,
            status: Status.Funded
        });

        outstandingOf[sellerAgentId] = current + advance;
        debtorOutstandingOf[sellerAgentId][debtorAgentId] += advance;
        trancheLiquid[tranche] -= advance;
        tranchePrincipal[tranche] += advance;

        BINV_TOKEN.mint(IDENTITY.ownerOf(sellerAgentId), invoiceId, docs);
        USDC.safeTransfer(IDENTITY.ownerOf(sellerAgentId), advance);
        emit InvoiceLocked(invoiceId, sellerAgentId, debtorAgentId, face, advance, tranche);
    }

    // ── Repayment (SPEC §3.6 — earliest open installment; M5 wires the Memo router in front) ──

    /// @notice apply a debtor payment to the invoice's earliest open installment.
    ///         Caller transfers USDC in (servicer relays escrowed memo inflows in M3).
    function applyPayment(uint256 invoiceId, uint256 amount) external onlyRole(SERVICER_ROLE) nonReentrant {
        Invoice storage inv = invoices[invoiceId];
        if (inv.status != Status.Funded) revert BadStatus(invoiceId);
        if (amount == 0) revert ZeroAmount();
        USDC.safeTransferFrom(msg.sender, address(this), amount);

        uint8 idx = inv.paidInstallments;
        uint256 due = installmentDue(invoiceId, idx);
        bool onTime = block.timestamp <= due + inv.grace;

        // split: tranche recovery first (outstanding), then the seller's holdback slice.
        // anything beyond face is rejected — the debtor owes face, no more.
        uint128 toOutstanding = amount >= inv.outstanding ? inv.outstanding : uint128(amount);
        uint128 remainder = uint128(amount) - toOutstanding;
        uint128 holdbackRoom = inv.holdback - inv.holdbackCollected;
        if (remainder > holdbackRoom) revert ZeroAmount(); // overpayment beyond face

        inv.outstanding -= toOutstanding;
        inv.holdbackCollected += remainder;
        inv.paidInstallments = idx + 1;
        if (toOutstanding > 0) {
            _reduceExposure(inv, toOutstanding);
            trancheLiquid[inv.tranche] += toOutstanding;
            tranchePrincipal[inv.tranche] -= toOutstanding;
        }

        if (onTime) {
            // the ONLY input that raises L(w) — realized repayment (SPEC §4.9)
            REPUTATION.recordOnTimeInstallment(inv.sellerAgentId);
            REPUTATION.recordPairSettlement(inv.sellerAgentId, inv.debtorAgentId);
        }
        emit InstallmentPaid(invoiceId, idx, uint256(toOutstanding) + remainder, onTime);

        if (inv.outstanding == 0 && inv.holdbackCollected == inv.holdback) {
            _settle(invoiceId, inv);
        }
    }

    /// @notice flip a missed invoice (earliest open installment past grace) into default
    ///         and run the M3 waterfall slice: holdback first, then C→B→A.
    function markDefaulted(uint256 invoiceId) external onlyRole(SERVICER_ROLE) {
        Invoice storage inv = invoices[invoiceId];
        if (inv.status != Status.Funded) revert BadStatus(invoiceId);
        uint256 due = installmentDue(invoiceId, inv.paidInstallments);
        if (block.timestamp <= due + inv.grace) revert NotPastGrace();

        inv.status = Status.Defaulted;
        uint128 outstanding = inv.outstanding;
        inv.outstanding = 0;
        _reduceExposure(inv, outstanding);

        // §4.8 layer 1: the UNRELEASED holdback cash held here absorbs first
        uint128 fromHoldback = outstanding < inv.holdbackCollected ? outstanding : inv.holdbackCollected;
        inv.holdbackCollected -= fromHoldback; // recovered value stays with the funding tranche
        trancheLiquid[inv.tranche] += fromHoldback;
        uint256 loss = outstanding - fromHoldback;
        // (layers 2–3, reserve + recourse, land in M4)  layers 4–6: C → B → A
        tranchePrincipal[inv.tranche] -= outstanding;
        if (loss > 0) _allocateLoss(loss);

        // one-way freeze: no new locks, no residual releases, pending M4 resolution
        // (PERMANENT_DEFAULT vs RESTRUCTURED is an ops decision via RestructureRouter —
        //  a legitimate credit default is not automatically identity-terminal, SPEC §3.3/§4.8)
        workspaceFrozen[inv.sellerAgentId] = true;
        emit WorkspaceFrozen(inv.sellerAgentId);
        emit InvoiceDefaulted(invoiceId, loss);
    }

    // ── Views ──────────────────────────────────────────────────────────

    function installmentDue(uint256 invoiceId, uint8 index) public view returns (uint256) {
        Invoice storage inv = invoices[invoiceId];
        return uint256(inv.firstMaturity) + uint256(index) * inv.interval;
    }

    /// @notice SPEC §6.2 tranche assets (NAV numerator; oracle pricing next milestone)
    function trancheAssets(uint8 tranche) public view returns (uint256) {
        return trancheLiquid[tranche] + tranchePrincipal[tranche];
    }

    // ── Internals ──────────────────────────────────────────────────────

    function _settle(uint256 invoiceId, Invoice storage inv) internal {
        inv.status = Status.Settled;
        uint256 residual = inv.holdbackCollected; // only CASH actually collected is releasable
        inv.holdbackCollected = 0;
        // frozen workspaces never receive residuals (cross-default law); retained
        // cash is netted in M4 recovery rather than released.
        if (residual > 0) {
            if (!workspaceFrozen[inv.sellerAgentId]) {
                USDC.safeTransfer(IDENTITY.ownerOf(inv.sellerAgentId), residual);
            } else {
                trancheLiquid[inv.tranche] += residual;
            }
        }
        BINV_TOKEN.burn(invoiceId);
        emit InvoiceSettled(invoiceId, residual);
    }

    function _reduceExposure(Invoice storage inv, uint128 amount) internal {
        outstandingOf[inv.sellerAgentId] -= amount;
        debtorOutstandingOf[inv.sellerAgentId][inv.debtorAgentId] -= amount;
    }

    /// @dev SPEC §4.8 layers 4–6 / §6.2: losses fill junior-first — C until exhausted, then B, then A.
    function _allocateLoss(uint256 loss) internal {
        for (uint8 t = 2;; --t) {
            uint256 capacity = trancheAssets(t) > trancheLoss[t] ? trancheAssets(t) - trancheLoss[t] : 0;
            uint256 take = loss < capacity ? loss : capacity;
            if (take > 0) {
                trancheLoss[t] += take;
                loss -= take;
                emit LossAllocated(t, take);
            }
            if (loss == 0 || t == 0) break;
        }
    }
}
