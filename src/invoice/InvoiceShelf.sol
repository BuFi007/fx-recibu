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
import {WorkspaceOperatingReserve} from "../rails/WorkspaceOperatingReserve.sol";
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
    bytes32 public constant OPS_ROLE = keccak256("OPS_ROLE");

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
    BIFTranche[3] internal _tranches; // [A, B, C]
    /// @dev M4: seller first-loss capital (waterfall layer 2). Set once post-deploy.
    WorkspaceOperatingReserve public reserve;

    uint256 public nextInvoiceId = 1;
    mapping(uint256 => Invoice) public invoices;

    /// @dev I1 accounting: per-seller aggregate outstanding + per-(seller,debtor) outstanding
    mapping(uint256 => uint256) public outstandingOf;
    mapping(uint256 => mapping(uint256 => uint256)) public debtorOutstandingOf;
    /// @dev velocity: advances started per epoch (SPEC §3.5)
    mapping(uint256 => mapping(uint256 => uint256)) public advancesInEpoch;
    /// @dev one-way cross-default flip (M4 extracts to its own registry)
    mapping(uint256 => bool) public workspaceFrozen;

    /// @dev SHARED-POOL tranche model (SPEC §6.2). Tranches are risk layers over one pool;
    ///      cash is fungible for funding, but LOSSES fill junior→senior (C→B→A).
    ///        NAV(T) = trancheDeposits[T] − trancheLoss[T]     (accrued/reserveCredit = future)
    ///      Pool identity: totalLiquid + totalPrincipal == Σ deposits − Σ loss.
    uint256 public totalLiquid; // shared fundable cash (LP capital, undeployed)
    uint256 public totalPrincipal; // shared outstanding advances (deployed, expected back)
    uint256[3] public trancheDeposits; // LP capital contributed per tranche (NAV basis + subordination capacity)
    uint256[3] public trancheLoss; // realized loss allocated per tranche (C fills first)
    uint256 public totalHoldbackHeld; // collected holdback cash owed to sellers (liability, not tranche capital)
    /// @dev residual holdback of a settled invoice whose workspace is frozen — custodied,
    ///      pending M4 recourse netting (part of totalHoldbackHeld; per-workspace slice)
    mapping(uint256 => uint256) public frozenHoldbackOf;

    event InvoiceLocked(
        uint256 indexed invoiceId, uint256 indexed sellerAgentId, uint256 indexed debtorAgentId, uint128 face, uint128 advance, uint8 tranche
    );
    event InstallmentPaid(uint256 indexed invoiceId, uint8 index, uint256 amount, bool onTime);
    event InvoiceSettled(uint256 indexed invoiceId, uint256 holdbackReleased);
    event InvoiceDefaulted(uint256 indexed invoiceId, uint256 lossAfterHoldback);
    event LossAllocated(uint8 indexed tranche, uint256 amount);
    event TrancheDeposit(uint8 indexed tranche, address indexed lp, uint256 assets, uint256 shares);
    event WorkspaceFrozen(uint256 indexed agentId);
    event DefaultResolved(uint256 indexed invoiceId, bool fraud);

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
    error ReserveAlreadySet();
    error BondNotPosted(uint256 required, uint256 posted);

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
        _tranches[0] = new BIFTranche("BUFI Invoice Senior", "bIF-A", address(this));
        _tranches[1] = new BIFTranche("BUFI Invoice Mezzanine", "bIF-B", address(this));
        _tranches[2] = new BIFTranche("BUFI Invoice Junior", "bIF-C", address(this));
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice one-time wiring of the seller first-loss reserve (M4)
    function setReserve(WorkspaceOperatingReserve reserve_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(reserve) != address(0)) revert ReserveAlreadySet();
        reserve = reserve_;
    }

    function tranches(uint8 tranche) public view returns (BIFTranche) {
        return _tranches[tranche];
    }

    // ── LP side (M3: par deposits; BUFIOracle prices NAV = deposits − loss) ──

    function depositTranche(uint8 tranche, uint256 assets) external nonReentrant returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        USDC.safeTransferFrom(msg.sender, address(this), assets);
        totalLiquid += assets;
        trancheDeposits[tranche] += assets;
        shares = assets * 1e12; // 6-dec USDC → 18-dec shares at par
        _tranches[tranche].mint(msg.sender, shares);
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

        // bond gate (SPEC §3.2): weak-tier sellers must have POSTED first-loss capital
        // covering bondShare × reserveRatio × new outstanding, before funds move.
        if (address(reserve) != address(0)) {
            uint16 bondShare = TIERS.bondShareBps(sellerS.sellerScore);
            uint256 requiredFloor = (
                (current + advance) * TIERS.reserveRatioBps(sellerS.sellerScore) / Params.BPS
            ) * bondShare / Params.BPS;
            if (bondShare > 0 && reserve.balanceOf(sellerAgentId) < requiredFloor) {
                revert BondNotPosted(requiredFloor, reserve.balanceOf(sellerAgentId));
            }
            reserve.setRequired(sellerAgentId, requiredFloor);
        }

        // tranche placement (SPEC §3.4): the recorded risk layer whose junior-first
        // capacity must subordinate this advance. Cash is funded from the SHARED pool;
        // the tranche tag decides who eats a loss first, not which wallet pays out.
        uint8 tranche = uint8(TIERS.trancheEligibility(sellerS.sellerScore, debtorS.debtorScore, pair));
        if (totalLiquid < advance) revert InsufficientTrancheLiquidity(tranche);

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
        totalLiquid -= advance;
        totalPrincipal += advance;

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
            totalPrincipal -= toOutstanding; // receivable repaid → back to fundable cash
            totalLiquid += toOutstanding;
        }
        if (remainder > 0) totalHoldbackHeld += remainder; // seller's cash, held as liability

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

        // the receivable is written off the pool; recovery below returns real cash to it
        totalPrincipal -= outstanding;

        // §4.8 layer 1: the UNRELEASED holdback cash this invoice collected absorbs first
        uint128 fromHoldback = outstanding < inv.holdbackCollected ? outstanding : inv.holdbackCollected;
        inv.holdbackCollected -= fromHoldback;
        totalHoldbackHeld -= fromHoldback; // that cash now backs the pool, not the seller
        totalLiquid += fromHoldback;
        uint256 loss = outstanding - fromHoldback;

        // §4.8 layer 2: the SELLER's posted reserve burns before any LP tranche
        if (loss > 0 && address(reserve) != address(0)) {
            uint256 covered = reserve.sweepFor(inv.sellerAgentId, loss);
            totalLiquid += covered; // reserve cash enters the pool
            loss -= covered;
        }
        // (layer 3 recourse/inflow-diversion is custody-layer policy — SPEC §8.2)
        // layers 4–6: allocate the residual loss C → B → A over each tranche's capacity
        if (loss > 0) _allocateLoss(loss);

        // one-way freeze: no new locks, no residual releases, pending M4 resolution
        // (PERMANENT_DEFAULT vs RESTRUCTURED is an ops decision via RestructureRouter —
        //  a legitimate credit default is not automatically identity-terminal, SPEC §3.3/§4.8)
        workspaceFrozen[inv.sellerAgentId] = true;
        emit WorkspaceFrozen(inv.sellerAgentId);
        emit InvoiceDefaulted(invoiceId, loss);
    }

    /// @notice M4 resolution (ops multisig): the PERMANENT_DEFAULT vs RESTRUCTURED split
    ///         (SPEC §3.3/§4.8). Fraud is identity-terminal and the freeze is permanent;
    ///         a legitimate-distress restructure marks the history and lifts the freeze
    ///         (L(w) is unchanged — capacity was earned and stays earned).
    function resolveDefault(uint256 invoiceId, bool fraud) external onlyRole(OPS_ROLE) {
        Invoice storage inv = invoices[invoiceId];
        if (inv.status != Status.Defaulted) revert BadStatus(invoiceId);
        uint256 contested = frozenHoldbackOf[inv.sellerAgentId];
        if (fraud) {
            REPUTATION.setPermanentDefault(inv.sellerAgentId);
            // fraud: contested holdback is a recovery — apply it against realized losses
            // (junior-first reversal), returning that value to LPs; excess stays custodied.
            if (contested > 0) {
                frozenHoldbackOf[inv.sellerAgentId] = 0;
                uint256 applied = _recoverLoss(contested);
                totalHoldbackHeld -= applied;
                totalLiquid += applied; // recovered cash re-enters the pool (loss reduced in step)
            }
        } else {
            REPUTATION.markRestructured(inv.sellerAgentId);
            workspaceFrozen[inv.sellerAgentId] = false;
            // legitimate distress: release the seller's custodied residual back to them
            if (contested > 0) {
                frozenHoldbackOf[inv.sellerAgentId] = 0;
                totalHoldbackHeld -= contested;
                USDC.safeTransfer(IDENTITY.ownerOf(inv.sellerAgentId), contested);
            }
        }
        emit DefaultResolved(invoiceId, fraud);
    }

    // ── Views ──────────────────────────────────────────────────────────

    function installmentDue(uint256 invoiceId, uint8 index) public view returns (uint256) {
        Invoice storage inv = invoices[invoiceId];
        return uint256(inv.firstMaturity) + uint256(index) * inv.interval;
    }

    /// @notice SPEC §6.2 NAV numerator per tranche: contributed capital minus allocated
    ///         loss (accrued yield / reserveCredit are future terms, 0 today). BUFIOracle
    ///         divides this by the tranche's share supply.
    function trancheAssets(uint8 tranche) public view returns (uint256) {
        uint256 dep = trancheDeposits[tranche];
        uint256 loss = trancheLoss[tranche];
        return dep > loss ? dep - loss : 0;
    }

    /// @notice loss-absorbing capacity still available in a tranche (deposits − loss)
    function trancheCapacity(uint8 tranche) public view returns (uint256) {
        return trancheAssets(tranche);
    }

    // ── Internals ──────────────────────────────────────────────────────

    function _settle(uint256 invoiceId, Invoice storage inv) internal {
        inv.status = Status.Settled;
        uint256 residual = inv.holdbackCollected; // only CASH actually collected is releasable
        inv.holdbackCollected = 0;
        if (residual > 0) {
            if (!workspaceFrozen[inv.sellerAgentId]) {
                totalHoldbackHeld -= residual;
                USDC.safeTransfer(IDENTITY.ownerOf(inv.sellerAgentId), residual);
            } else {
                // Frozen (cross-default): the seller's residual is CONTESTED capital,
                // not released and not seized into the LP pool — it stays custodied in
                // totalHoldbackHeld and is netted against recourse when M4 resolveDefault
                // runs. Keeps both the pool identity and cash-backed invariants intact.
                frozenHoldbackOf[inv.sellerAgentId] += residual;
            }
        }
        BINV_TOKEN.burn(invoiceId);
        // release the bond floor once the workspace carries no exposure (and is clean)
        if (
            address(reserve) != address(0) && outstandingOf[inv.sellerAgentId] == 0
                && !workspaceFrozen[inv.sellerAgentId]
        ) {
            reserve.setRequired(inv.sellerAgentId, 0);
        }
        emit InvoiceSettled(invoiceId, residual);
    }

    function _reduceExposure(Invoice storage inv, uint128 amount) internal {
        outstandingOf[inv.sellerAgentId] -= amount;
        debtorOutstandingOf[inv.sellerAgentId][inv.debtorAgentId] -= amount;
    }

    /// @dev SPEC §4.8 layers 4–6 / §6.2: losses fill junior-first — C until its
    ///      capacity (deposits − loss) is exhausted, then B, then A. Senior NAV holds
    ///      par until junior+mezz are wiped (invariant_seniorNavParUnlessJuniorExhausted).
    ///      If loss exceeds all capacity (catastrophic), the remainder is unabsorbed —
    ///      pool insolvency, surfaced rather than silently mis-booked.
    function _allocateLoss(uint256 loss) internal {
        for (uint8 t = 2;; --t) {
            uint256 capacity = trancheAssets(t); // = deposits[t] − loss[t], the remaining buffer
            uint256 take = loss < capacity ? loss : capacity;
            if (take > 0) {
                trancheLoss[t] += take;
                loss -= take;
                emit LossAllocated(t, take);
            }
            if (loss == 0 || t == 0) break;
        }
    }

    /// @dev reverse of _allocateLoss: apply a recovery against booked losses, senior-first
    ///      (A repaid before B before C — recoveries unwind the waterfall from the top).
    ///      Returns the amount actually applied (≤ recovery, capped at total booked loss).
    function _recoverLoss(uint256 recovery) internal returns (uint256 applied) {
        for (uint8 t = 0; t < 3; ++t) {
            uint256 booked = trancheLoss[t];
            uint256 take = recovery < booked ? recovery : booked;
            if (take > 0) {
                trancheLoss[t] -= take;
                recovery -= take;
                applied += take;
                emit LossAllocated(t, 0); // 0-amount marker; recovery detail in DefaultResolved
            }
            if (recovery == 0) break;
        }
    }
}
