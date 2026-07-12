// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IBUFIIdentityRegistry} from "../interfaces/IBUFIIdentityRegistry.sol";
import {IBUFIReputationRegistry} from "../interfaces/IBUFIReputationRegistry.sol";
import {IAuthorityInvoiceVerifier} from "../interfaces/IAuthorityInvoiceVerifier.sol";
import {IReceivableDomainView} from "../interfaces/IReceivableDomainView.sol";
import {WorkspaceTierRegistry} from "../credit/WorkspaceTierRegistry.sol";
import {BINV} from "./BINV.sol";
import {BIFTranche} from "./BIFTranche.sol";
import {WorkspaceOperatingReserve} from "../rails/WorkspaceOperatingReserve.sol";
import {Params} from "../libraries/Params.sol";
import {ReceivableCommitment} from "../libraries/ReceivableCommitment.sol";

/// @dev Minimal view into ReceivableEscrow so markDefaulted can detect an unsettled
///      debtor payment (deposited via InvoiceMemoRouter.pay) before writing off the
///      receivable. Full escrow behaviour lives in src/rails/ReceivableEscrow.sol.
interface IReceivableEscrowView {
    function escrowedOf(uint256 invoiceId) external view returns (uint256);
}

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
contract InvoiceShelf is AccessControl, ReentrancyGuard, IReceivableDomainView {
    using SafeERC20 for IERC20;

    bytes32 public constant SERVICER_ROLE = keccak256("SERVICER_ROLE");
    bytes32 public constant OPS_ROLE = keccak256("OPS_ROLE");
    bytes32 public constant SETTLEMENT_ROLE = keccak256("SETTLEMENT_ROLE");
    uint8 internal constant TRANCHE_COUNT = 3;
    uint256 internal constant USDC_TO_SHARE_SCALE = 1e12;

    enum Status {
        None,
        Funded,
        Settled,
        Defaulted
    }

    enum DefaultResolution {
        Unresolved,
        Restructured,
        Fraud
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
    IAuthorityInvoiceVerifier public immutable AUTHORITY_VERIFIER;
    uint16 public immutable AUTHORITY_VERIFIER_SCHEMA_VERSION;
    bytes32 public immutable AUTHORITY_VERIFIER_CONFIG_ID;
    uint256 public immutable AUTHORITY_VERIFIER_CHAIN_ID;
    bytes32 public immutable AUTHORITY_VERIFIER_CODEHASH;
    BINV public immutable BINV_TOKEN;
    BIFTranche[3] internal _tranches; // [A, B, C]
    /// @dev M4: seller first-loss capital (waterfall layer 2). Set once post-deploy.
    WorkspaceOperatingReserve public reserve;
    /// @dev M5: the receivable escrow, so markDefaulted can detect an unsettled debtor
    ///      payment sitting in escrow before defaulting. Set once post-deploy.
    IReceivableEscrowView public escrow;

    uint256 public nextInvoiceId = 1;
    mapping(uint256 => Invoice) public invoices;
    /// @notice Cash credited toward the earliest incomplete installment.
    /// @dev Kept outside Invoice so the existing public invoices getter retains its ABI.
    mapping(uint256 => uint128) public installmentProgress;

    mapping(bytes32 authorityInvoiceId => uint256 invoiceId) public override invoiceIdOfAuthorityInvoiceId;
    mapping(uint256 invoiceId => bytes32 authorityInvoiceId) public authorityInvoiceIdOf;
    mapping(bytes32 receivableCommitment => uint256 invoiceId) public override invoiceIdOfReceivableCommitment;
    mapping(uint256 invoiceId => bytes32 receivableCommitment) public receivableCommitmentOf;
    mapping(uint256 invoiceId => bytes32 documentCommitment) public documentCommitmentOf;
    mapping(uint256 invoiceId => bytes32 authorityEvidenceCommitment) public authorityEvidenceCommitmentOf;
    mapping(uint256 invoiceId => bytes32 verifierConfigId) public verifierConfigIdOf;
    mapping(uint256 invoiceId => bool recourse) public recourseOf;
    mapping(uint256 invoiceId => uint16 advanceRateBps) public advanceRateBpsOf;

    /// @dev I1 accounting: per-seller aggregate outstanding + per-(seller,debtor) outstanding
    mapping(uint256 => uint256) public outstandingOf;
    mapping(uint256 => mapping(uint256 => uint256)) public debtorOutstandingOf;
    /// @dev velocity: advances started per epoch (SPEC §3.5)
    mapping(uint256 => mapping(uint256 => uint256)) public advancesInEpoch;
    /// @dev Cross-default gate. It may only reopen after every default for the seller
    ///      has been resolved as legitimate distress; fraud keeps it terminally frozen.
    mapping(uint256 => bool) public workspaceFrozen;
    /// @dev Resolution is invoice-scoped so an authorized caller cannot replay an
    ///      ops decision or mutate seller-level accounting twice.
    mapping(uint256 invoiceId => DefaultResolution resolution) public defaultResolutionOf;
    /// @dev A seller remains cross-default frozen until all of its defaults have an
    ///      explicit ops resolution. This prevents one restructure from masking another.
    mapping(uint256 sellerAgentId => uint256 count) public unresolvedDefaultCountOf;
    /// @dev Cash recovery claims are explicit at both invoice and seller scope. A
    ///      resolution decision does not forgive principal that LPs have already lost.
    mapping(uint256 invoiceId => uint256 amount) public unrecoveredLossOf;
    mapping(uint256 sellerAgentId => uint256 amount) public sellerUnrecoveredLossOf;
    uint256 public totalUnrecoveredLoss;

    /// @dev SHARED-POOL tranche model (SPEC §6.2). Tranches are risk layers over one pool;
    ///      cash is fungible for funding, but LOSSES fill junior→senior (C→B→A).
    ///        NAV(T) = trancheDeposits[T] − trancheLoss[T]     (accrued/reserveCredit = future)
    ///      Pool identity: totalLiquid + totalPrincipal == Σ deposits − Σ loss.
    uint256 public totalLiquid; // shared fundable cash (LP capital, undeployed)
    uint256 public totalPrincipal; // shared outstanding advances (deployed, expected back)
    /// @dev Principal reserved against the tranche selected at origination. Shared
    ///      cash remains fungible, but a junior-selected receivable cannot borrow
    ///      against senior-only capital.
    uint256[3] public tranchePrincipal;
    uint256[3] public trancheDeposits; // live LP gross basis per tranche (assets + loss claim)
    uint256[3] public trancheLoss; // realized loss still borne by live shares (C fills first)
    uint256 public totalHoldbackHeld; // collected holdback cash owed to sellers (liability, not tranche capital)
    /// @dev residual holdback of a settled invoice whose workspace is frozen — custodied,
    ///      pending M4 recourse netting (part of totalHoldbackHeld; per-workspace slice)
    mapping(uint256 => uint256) public frozenHoldbackOf;

    event InvoiceLocked(
        uint256 indexed invoiceId,
        uint256 indexed sellerAgentId,
        uint256 indexed debtorAgentId,
        uint128 face,
        uint128 advance,
        uint8 tranche
    );
    event AuthorityInvoiceConsumed(
        bytes32 indexed authorityInvoiceId,
        bytes32 indexed receivableCommitment,
        uint256 indexed invoiceId,
        bytes32 authorityEvidenceCommitment,
        bytes32 documentCommitment,
        bytes32 verifierConfigId
    );
    event InstallmentPaymentApplied(
        uint256 indexed invoiceId,
        uint8 indexed index,
        uint256 amount,
        uint256 cumulativeProgress,
        uint256 installmentAmount
    );
    event InstallmentPaid(uint256 indexed invoiceId, uint8 index, uint256 amount, bool creditedOnTime);
    event InvoiceSettled(uint256 indexed invoiceId, uint256 holdbackReleased, uint256 holdbackContested);
    event InvoiceDefaulted(uint256 indexed invoiceId, uint256 lossAfterHoldback);
    event LossAllocated(uint8 indexed tranche, uint256 amount);
    event TrancheDeposit(uint8 indexed tranche, address indexed lp, uint256 assets, uint256 shares);
    event TrancheRedemption(uint8 indexed tranche, address indexed lp, uint256 assets, uint256 shares);
    event ReserveSurplusWithdrawn(uint256 indexed agentId, address indexed owner, uint256 amount);
    event WorkspaceFrozen(uint256 indexed agentId);
    event DefaultResolved(uint256 indexed invoiceId, bool fraud);
    event ContestedHoldbackRecovered(
        uint256 indexed invoiceId, uint256 indexed sellerAgentId, uint256 applied, uint256 retainedExcess
    );
    event LossRecovered(
        uint256 indexed invoiceId, uint256 indexed sellerAgentId, uint8 indexed tranche, uint256 amount, address source
    );

    error NotEligible(uint256 agentId);
    error Frozen(uint256 agentId);
    error ExposureCapExceeded(uint256 agentId, uint256 requested, uint256 headroom);
    error ConcentrationCapExceeded(uint256 debtorAgentId);
    error SelfDealingReceivable(uint256 agentId);
    error VelocityCapExceeded(uint256 agentId);
    error BadSchedule();
    error BadStatus(uint256 invoiceId);
    error UnknownInvoice(uint256 invoiceId);
    error BadInstallmentIndex(uint256 invoiceId, uint8 index);
    error NoCurrentInstallment(uint256 invoiceId, Status status);
    error InstallmentAccountingMismatch(
        uint256 invoiceId, uint8 paidInstallments, uint8 expectedInstallments, uint256 progress
    );
    error InsufficientTrancheLiquidity(uint8 tranche);
    error NotPastGrace();
    error ZeroAmount();
    error ReserveAlreadySet();
    error EscrowAlreadySet();
    error EscrowPendingSettlement(uint256 invoiceId);
    error DirectPaymentDisabled();
    error BondNotPosted(uint256 required, uint256 posted);
    error UnsupportedAuthoritySchema(uint16 received, uint16 expected);
    error UnsupportedAuthorityVoucherType(uint8 received);
    error VerifierConfigMismatch(bytes32 received, bytes32 expected);
    error VerifierDeploymentMismatch(address verifier, bytes32 receivedCodehash, bytes32 expectedCodehash);
    error WrongVerifierChain(uint256 received, uint256 expected);
    error VerifierShelfMismatch(address received, address expected);
    error AuthorityInvoiceNotVerified(bytes32 authorityInvoiceId);
    error AuthorityInvoiceAlreadyConsumed(bytes32 authorityInvoiceId, uint256 originalInvoiceId);
    error ReceivableCommitmentAlreadyConsumed(bytes32 commitment, uint256 originalInvoiceId);
    error InvalidAuthorityDates(uint64 issuedAt, uint64 authorityPaymentDueAt);
    error MissingRequiredDocumentHash(uint8 fieldIndex);
    error NonRecourseNotEnabled();
    error UnknownFundingEvidence(uint256 invoiceId);
    error DefaultAlreadyResolved(uint256 invoiceId);
    error InvalidTranche(uint8 tranche);
    error InsolventTranche(uint8 tranche);
    error RedemptionRoundsToZero();
    error InsufficientTrancheShares(uint256 requested, uint256 available);
    error InsufficientRedemptionLiquidity(uint256 requested, uint256 available);
    error PoolNotIdle(uint256 principal, uint256 bookedLoss);
    error PoolHasUnresolvedLoss(uint256 bookedLoss, uint256 unrecoveredLoss);
    error RecoveryExceedsUnrecoveredLoss(uint256 requested, uint256 available);
    error LossAccountingMismatch(uint256 requested, uint256 applied);
    error ReserveNotSet();
    error NotWorkspaceOwner(uint256 agentId, address caller);
    error OutstandingExposure(uint256 agentId, uint256 outstanding);
    error ReserveFloorActive(uint256 agentId, uint256 required);

    constructor(
        IERC20 usdc,
        IBUFIIdentityRegistry identity_,
        IBUFIReputationRegistry reputation_,
        WorkspaceTierRegistry tiers_,
        IAuthorityInvoiceVerifier authorityVerifier_,
        uint16 authorityVerifierSchemaVersion,
        bytes32 authorityVerifierConfigId,
        uint256 authorityVerifierChainId,
        bytes32 authorityVerifierCodehash,
        address admin
    ) {
        if (authorityVerifierSchemaVersion != ReceivableCommitment.VERSION) {
            revert UnsupportedAuthoritySchema(authorityVerifierSchemaVersion, ReceivableCommitment.VERSION);
        }
        if (block.chainid != authorityVerifierChainId) {
            revert WrongVerifierChain(block.chainid, authorityVerifierChainId);
        }
        bytes32 receivedCodehash = address(authorityVerifier_).codehash;
        if (address(authorityVerifier_).code.length == 0 || receivedCodehash != authorityVerifierCodehash) {
            revert VerifierDeploymentMismatch(address(authorityVerifier_), receivedCodehash, authorityVerifierCodehash);
        }
        uint16 receivedSchema = authorityVerifier_.supportedSchemaVersion();
        if (receivedSchema != authorityVerifierSchemaVersion) {
            revert UnsupportedAuthoritySchema(receivedSchema, authorityVerifierSchemaVersion);
        }
        bytes32 receivedConfig = authorityVerifier_.verifierConfigId();
        if (authorityVerifierConfigId == bytes32(0) || receivedConfig != authorityVerifierConfigId) {
            revert VerifierConfigMismatch(receivedConfig, authorityVerifierConfigId);
        }
        uint256 receivedChain = authorityVerifier_.approvedChainId();
        if (receivedChain != block.chainid) revert WrongVerifierChain(receivedChain, block.chainid);
        address receivedShelf = authorityVerifier_.approvedShelf();
        if (receivedShelf != address(this)) revert VerifierShelfMismatch(receivedShelf, address(this));

        USDC = usdc;
        IDENTITY = identity_;
        REPUTATION = reputation_;
        TIERS = tiers_;
        AUTHORITY_VERIFIER = authorityVerifier_;
        AUTHORITY_VERIFIER_SCHEMA_VERSION = authorityVerifierSchemaVersion;
        AUTHORITY_VERIFIER_CONFIG_ID = authorityVerifierConfigId;
        AUTHORITY_VERIFIER_CHAIN_ID = authorityVerifierChainId;
        AUTHORITY_VERIFIER_CODEHASH = authorityVerifierCodehash;
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

    /// @notice one-time wiring of the receivable escrow (M5). Lets markDefaulted see an
    ///         unsettled debtor payment before writing off the receivable.
    function setEscrow(address escrow_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(escrow) != address(0)) revert EscrowAlreadySet();
        escrow = IReceivableEscrowView(escrow_);
    }

    function tranches(uint8 tranche) public view returns (BIFTranche) {
        _requireValidTranche(tranche);
        return _tranches[tranche];
    }

    function fundingEvidence(uint256 invoiceId) external view override returns (FundingEvidence memory evidence) {
        bytes32 authorityInvoiceId = authorityInvoiceIdOf[invoiceId];
        if (authorityInvoiceId == bytes32(0)) revert UnknownFundingEvidence(invoiceId);
        evidence = FundingEvidence({
            schemaVersion: AUTHORITY_VERIFIER_SCHEMA_VERSION,
            verifierConfigId: verifierConfigIdOf[invoiceId],
            authorityInvoiceId: authorityInvoiceId,
            authorityEvidenceCommitment: authorityEvidenceCommitmentOf[invoiceId],
            receivableCommitment: receivableCommitmentOf[invoiceId],
            documentCommitment: documentCommitmentOf[invoiceId],
            consumed: invoiceIdOfAuthorityInvoiceId[authorityInvoiceId] == invoiceId
        });
    }

    // ── LP side (M3: deposits/redemptions at live NAV) ──

    function depositTranche(uint8 tranche, uint256 assets) external nonReentrant returns (uint256 shares) {
        _requireValidTranche(tranche);
        if (assets == 0) revert ZeroAmount();
        uint256 bookedLoss = _totalBookedLoss();
        if (bookedLoss != 0 || totalUnrecoveredLoss != 0) {
            revert PoolHasUnresolvedLoss(bookedLoss, totalUnrecoveredLoss);
        }

        BIFTranche trancheToken = _tranches[tranche];
        uint256 supply = trancheToken.totalSupply();
        if (supply == 0) {
            shares = Math.mulDiv(assets, USDC_TO_SHARE_SCALE, 1);
        } else {
            uint256 nav = trancheAssets(tranche);
            // Recapitalizing a fully wiped live share class would transfer the new
            // depositor's cash to the old zero-NAV shares. It requires an explicit
            // restructuring path, not the ordinary deposit entry point.
            if (nav == 0) revert InsolventTranche(tranche);
            shares = Math.mulDiv(assets, supply, nav);
            if (shares == 0) revert ZeroAmount();
        }

        USDC.safeTransferFrom(msg.sender, address(this), assets);
        totalLiquid += assets;
        trancheDeposits[tranche] += assets;
        trancheToken.mint(msg.sender, shares);
        emit TrancheDeposit(tranche, msg.sender, assets, shares);
    }

    /// @notice Burn tranche shares and return their proportional NAV from an idle,
    ///         lossless pool.
    /// @dev v1 has no lender-cohort recovery snapshots. Exits therefore fail closed
    ///      while any principal is deployed or any tranche carries a booked loss.
    ///      Redemptions never consume collected seller holdbacks.
    function redeemTranche(uint8 tranche, uint256 shares) external nonReentrant returns (uint256 assets) {
        _requireValidTranche(tranche);
        if (shares == 0) revert ZeroAmount();
        uint256 bookedLoss = _totalBookedLoss();
        if (totalPrincipal != 0 || bookedLoss != 0) revert PoolNotIdle(totalPrincipal, bookedLoss);

        BIFTranche trancheToken = _tranches[tranche];
        uint256 balance = trancheToken.balanceOf(msg.sender);
        if (shares > balance) revert InsufficientTrancheShares(shares, balance);

        uint256 supply = trancheToken.totalSupply();
        uint256 grossBasis = Math.mulDiv(shares, trancheDeposits[tranche], supply);
        assets = Math.mulDiv(shares, trancheAssets(tranche), supply);
        if (assets == 0) revert RedemptionRoundsToZero();
        if (totalLiquid < assets) revert InsufficientRedemptionLiquidity(assets, totalLiquid);

        trancheDeposits[tranche] -= grossBasis;
        totalLiquid -= assets;
        trancheToken.burn(msg.sender, shares);
        USDC.safeTransfer(msg.sender, assets);
        emit TrancheRedemption(tranche, msg.sender, assets, shares);
    }

    /// @notice Return a workspace's idle operating reserve to its current identity owner.
    /// @dev The recipient is deliberately not caller-supplied. No reserve capital can
    ///      leave while the workspace has exposure, is frozen, or retains a shelf floor.
    function withdrawReserveSurplus(uint256 agentId, uint256 amount) external nonReentrant {
        WorkspaceOperatingReserve reserve_ = reserve;
        if (address(reserve_) == address(0)) revert ReserveNotSet();
        if (amount == 0) revert ZeroAmount();

        address owner = IDENTITY.ownerOf(agentId);
        if (msg.sender != owner) revert NotWorkspaceOwner(agentId, msg.sender);
        uint256 outstanding = outstandingOf[agentId];
        if (outstanding != 0) revert OutstandingExposure(agentId, outstanding);
        if (workspaceFrozen[agentId]) revert Frozen(agentId);
        uint256 required = reserve_.requiredOf(agentId);
        if (required != 0) revert ReserveFloorActive(agentId, required);

        reserve_.withdrawSurplus(agentId, owner, amount);
        emit ReserveSurplusWithdrawn(agentId, owner, amount);
    }

    // ── Lock (SPEC §3) ──────────────────────────────────────────────────

    function lockInvoice(
        uint256 sellerAgentId,
        uint256 debtorAgentId,
        uint128 face,
        uint8 nInstallments,
        uint64 firstMaturity,
        uint32 interval,
        ReceivableCommitment.FundingTerms calldata terms,
        BINV.DocBundle calldata docs
    ) external onlyRole(SERVICER_ROLE) nonReentrant returns (uint256 invoiceId) {
        if (sellerAgentId == debtorAgentId) revert SelfDealingReceivable(sellerAgentId);
        _validateAuthorityFunding(
            terms, docs, sellerAgentId, debtorAgentId, face, nInstallments, firstMaturity, interval
        );
        uint256 originalInvoiceId = invoiceIdOfAuthorityInvoiceId[terms.authority.authorityInvoiceId];
        if (originalInvoiceId != 0) {
            revert AuthorityInvoiceAlreadyConsumed(terms.authority.authorityInvoiceId, originalInvoiceId);
        }

        // v2v hard gate: KYB'd + not defaulted, both sides (SPEC §1)
        if (!TIERS.eligible(sellerAgentId)) revert NotEligible(sellerAgentId);
        if (!TIERS.eligible(debtorAgentId)) revert NotEligible(debtorAgentId);
        if (workspaceFrozen[sellerAgentId]) revert Frozen(sellerAgentId);
        if (
            nInstallments < Params.MIN_INSTALLMENTS || nInstallments > Params.MAX_INSTALLMENTS
                || interval < Params.MIN_INSTALLMENT_INTERVAL || firstMaturity <= block.timestamp
                || uint256(face) < nInstallments
        ) revert BadSchedule();

        bool pair = TIERS.hasPairHistory(sellerAgentId, debtorAgentId);
        IBUFIReputationRegistry.ScoreSnapshot memory sellerS = REPUTATION.scoreOf(sellerAgentId);
        IBUFIReputationRegistry.ScoreSnapshot memory debtorS = REPUTATION.scoreOf(debtorAgentId);

        uint16 advanceRateBps = TIERS.advanceRateBps(debtorS.debtorScore, pair);
        uint128 advance = uint128((uint256(face) * advanceRateBps) / Params.BPS);
        uint128 holdback = face - advance;
        uint8 tranche = uint8(TIERS.trancheEligibility(sellerS.sellerScore, debtorS.debtorScore, pair));
        uint32 grace = TIERS.tierOf(sellerS.sellerScore) >= WorkspaceTierRegistry.Tier.Strong
            ? Params.GRACE_STRONG
            : Params.GRACE_WEAK;
        ReceivableCommitment.ScheduleTerms memory schedule = ReceivableCommitment.ScheduleTerms({
            nInstallments: nInstallments, firstMaturity: firstMaturity, interval: interval, grace: grace
        });
        ReceivableCommitment.ComputedFundingTerms memory computed = ReceivableCommitment.ComputedFundingTerms({
            advanceRateBps: advanceRateBps, advanceAmount: advance, holdbackAmount: holdback, tranche: tranche
        });
        bytes32 receivableCommitment = ReceivableCommitment.hashReceivable(
            block.chainid,
            address(this),
            sellerAgentId,
            debtorAgentId,
            address(USDC),
            face,
            terms,
            schedule,
            computed,
            docs.assignmentHash
        );
        originalInvoiceId = invoiceIdOfReceivableCommitment[receivableCommitment];
        if (originalInvoiceId != 0) {
            revert ReceivableCommitmentAlreadyConsumed(receivableCommitment, originalInvoiceId);
        }
        bytes32 documentCommitment = ReceivableCommitment.hashDocumentBundle(terms.authority, docs, terms.recourse);

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
            uint256 requiredFloor = ((current + advance) * TIERS.reserveRatioBps(sellerS.sellerScore) / Params.BPS)
                * bondShare / Params.BPS;
            if (bondShare > 0 && reserve.balanceOf(sellerAgentId) < requiredFloor) {
                revert BondNotPosted(requiredFloor, reserve.balanceOf(sellerAgentId));
            }
            reserve.setRequired(sellerAgentId, requiredFloor);
        }

        // Tranche placement (SPEC §3.4): cash custody is shared, but risk capacity is
        // not. The selected tranche must itself have net unencumbered NAV, preventing
        // a Junior-C receivable from funding against senior-only capital.
        if (totalLiquid < advance || trancheCapacity(tranche) < advance) {
            revert InsufficientTrancheLiquidity(tranche);
        }

        invoiceId = nextInvoiceId++;
        invoices[invoiceId] = Invoice({
            sellerAgentId: sellerAgentId,
            debtorAgentId: debtorAgentId,
            face: face,
            advance: advance,
            outstanding: advance,
            holdback: holdback,
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
        tranchePrincipal[tranche] += advance;

        invoiceIdOfAuthorityInvoiceId[terms.authority.authorityInvoiceId] = invoiceId;
        authorityInvoiceIdOf[invoiceId] = terms.authority.authorityInvoiceId;
        invoiceIdOfReceivableCommitment[receivableCommitment] = invoiceId;
        receivableCommitmentOf[invoiceId] = receivableCommitment;
        documentCommitmentOf[invoiceId] = documentCommitment;
        authorityEvidenceCommitmentOf[invoiceId] = terms.authority.authorityEvidenceCommitment;
        verifierConfigIdOf[invoiceId] = terms.authority.verifierConfigId;
        recourseOf[invoiceId] = terms.recourse;
        advanceRateBpsOf[invoiceId] = advanceRateBps;

        emit AuthorityInvoiceConsumed(
            terms.authority.authorityInvoiceId,
            receivableCommitment,
            invoiceId,
            terms.authority.authorityEvidenceCommitment,
            documentCommitment,
            terms.authority.verifierConfigId
        );

        BINV_TOKEN.mint(IDENTITY.ownerOf(sellerAgentId), invoiceId, docs);
        USDC.safeTransfer(IDENTITY.ownerOf(sellerAgentId), advance);
        emit InvoiceLocked(invoiceId, sellerAgentId, debtorAgentId, face, advance, tranche);
    }

    function _validateAuthorityFunding(
        ReceivableCommitment.FundingTerms calldata terms,
        BINV.DocBundle calldata docs,
        uint256 sellerAgentId,
        uint256 debtorAgentId,
        uint128 face,
        uint8 nInstallments,
        uint64 firstMaturity,
        uint32 interval
    ) internal view {
        ReceivableCommitment.AuthorityRef calldata authority = terms.authority;
        if (authority.schemaVersion != AUTHORITY_VERIFIER_SCHEMA_VERSION) {
            revert UnsupportedAuthoritySchema(authority.schemaVersion, AUTHORITY_VERIFIER_SCHEMA_VERSION);
        }
        if (authority.verifierConfigId == bytes32(0) || authority.verifierConfigId != AUTHORITY_VERIFIER_CONFIG_ID) {
            revert VerifierConfigMismatch(authority.verifierConfigId, AUTHORITY_VERIFIER_CONFIG_ID);
        }
        if (authority.authorityVoucherType != 19) {
            revert UnsupportedAuthorityVoucherType(authority.authorityVoucherType);
        }
        if (docs.invoiceDocHash == bytes32(0)) revert MissingRequiredDocumentHash(0);
        if (docs.assignmentHash == bytes32(0)) revert MissingRequiredDocumentHash(1);
        if (docs.paymentInstructionHash == bytes32(0)) revert MissingRequiredDocumentHash(2);
        if (docs.servicingPolicyHash == bytes32(0)) revert MissingRequiredDocumentHash(3);
        if (docs.disputePolicyHash == bytes32(0)) revert MissingRequiredDocumentHash(4);
        if (!terms.recourse) revert NonRecourseNotEnabled();
        if (authority.authorityInvoiceId == bytes32(0) || authority.authorityEvidenceCommitment == bytes32(0)) {
            revert AuthorityInvoiceNotVerified(authority.authorityInvoiceId);
        }
        if (
            authority.issuedAt == 0 || authority.authorityPaymentDueAt == 0
                || authority.authorityPaymentDueAt < authority.issuedAt || authority.issuedAt > block.timestamp
        ) {
            revert InvalidAuthorityDates(authority.issuedAt, authority.authorityPaymentDueAt);
        }

        _assertVerifierBinding();
        bool verified = AUTHORITY_VERIFIER.isVerified(
            authority,
            sellerAgentId,
            debtorAgentId,
            address(USDC),
            face,
            terms.recourse,
            nInstallments,
            firstMaturity,
            interval
        );
        if (!verified) revert AuthorityInvoiceNotVerified(authority.authorityInvoiceId);
    }

    function _assertVerifierBinding() internal view {
        if (block.chainid != AUTHORITY_VERIFIER_CHAIN_ID) {
            revert WrongVerifierChain(block.chainid, AUTHORITY_VERIFIER_CHAIN_ID);
        }
        bytes32 receivedCodehash = address(AUTHORITY_VERIFIER).codehash;
        if (receivedCodehash != AUTHORITY_VERIFIER_CODEHASH) {
            revert VerifierDeploymentMismatch(
                address(AUTHORITY_VERIFIER), receivedCodehash, AUTHORITY_VERIFIER_CODEHASH
            );
        }
        uint16 receivedSchema = AUTHORITY_VERIFIER.supportedSchemaVersion();
        if (receivedSchema != AUTHORITY_VERIFIER_SCHEMA_VERSION) {
            revert UnsupportedAuthoritySchema(receivedSchema, AUTHORITY_VERIFIER_SCHEMA_VERSION);
        }
        bytes32 receivedConfig = AUTHORITY_VERIFIER.verifierConfigId();
        if (receivedConfig != AUTHORITY_VERIFIER_CONFIG_ID) {
            revert VerifierConfigMismatch(receivedConfig, AUTHORITY_VERIFIER_CONFIG_ID);
        }
        uint256 receivedChain = AUTHORITY_VERIFIER.approvedChainId();
        if (receivedChain != AUTHORITY_VERIFIER_CHAIN_ID) {
            revert WrongVerifierChain(receivedChain, AUTHORITY_VERIFIER_CHAIN_ID);
        }
        address receivedShelf = AUTHORITY_VERIFIER.approvedShelf();
        if (receivedShelf != address(this)) revert VerifierShelfMismatch(receivedShelf, address(this));
    }

    // ── Repayment (SPEC §3.6 — earliest open installment; M5 wires the Memo router in front) ──

    /// @notice Legacy direct-payment harness, available only before canonical escrow wiring.
    /// @dev A production shelf must source repayment provenance from its debtor-bound
    ///      memo router and settlement contract. Once escrow is configured, a servicer
    ///      can never substitute its own cash for debtor payment history.
    function applyPayment(uint256 invoiceId, uint256 amount) external onlyRole(SERVICER_ROLE) nonReentrant {
        if (address(escrow) != address(0)) revert DirectPaymentDisabled();
        _applyPayment(invoiceId, amount, msg.sender);
    }

    /// @notice M5: the settlement orchestrator applies an escrowed inflow on the debtor's
    ///         behalf (payer = the escrow/settlement contract holding the funds).
    function applyPaymentFrom(uint256 invoiceId, uint256 amount, address payer)
        external
        onlyRole(SETTLEMENT_ROLE)
        nonReentrant
    {
        _applyPayment(invoiceId, amount, payer);
    }

    function _applyPayment(uint256 invoiceId, uint256 amount, address payer) internal {
        Invoice storage inv = invoices[invoiceId];
        if (inv.status != Status.Funded) revert BadStatus(invoiceId);
        if (amount == 0) revert ZeroAmount();
        USDC.safeTransferFrom(payer, address(this), amount);

        // split: tranche recovery first (outstanding), then the seller's holdback slice.
        // anything beyond face is rejected — the debtor owes face, no more.
        uint256 remainingFace = uint256(inv.outstanding) + uint256(inv.holdback - inv.holdbackCollected);
        if (amount > remainingFace) revert ZeroAmount();
        uint128 toOutstanding = amount >= inv.outstanding ? inv.outstanding : uint128(amount);
        uint128 remainder = uint128(amount) - toOutstanding;

        inv.outstanding -= toOutstanding;
        inv.holdbackCollected += remainder;
        if (toOutstanding > 0) {
            _reduceExposure(inv, toOutstanding);
            totalPrincipal -= toOutstanding; // receivable repaid → back to fundable cash
            totalLiquid += toOutstanding;
        }
        if (remainder > 0) totalHoldbackHeld += remainder; // seller's cash, held as liability

        _creditInstallments(invoiceId, inv, amount);

        if (inv.outstanding == 0 && inv.holdbackCollected == inv.holdback) {
            if (inv.paidInstallments != inv.nInstallments || installmentProgress[invoiceId] != 0) {
                revert InstallmentAccountingMismatch(
                    invoiceId, inv.paidInstallments, inv.nInstallments, installmentProgress[invoiceId]
                );
            }
            _settle(invoiceId, inv);
        }
    }

    /// @dev Allocate accepted cash to the earliest incomplete maturity. The loop is
    ///      bounded by Params.MAX_INSTALLMENTS (currently 12), including a payment
    ///      that spans every installment.
    function _creditInstallments(uint256 invoiceId, Invoice storage inv, uint256 amount) internal {
        uint256 remaining = amount;
        while (remaining > 0) {
            uint8 index = inv.paidInstallments;
            if (index >= inv.nInstallments) {
                revert InstallmentAccountingMismatch(
                    invoiceId, inv.paidInstallments, inv.nInstallments, installmentProgress[invoiceId]
                );
            }

            uint256 fullAmount = _installmentAmount(inv, index);
            uint256 progress = installmentProgress[invoiceId];
            uint256 openAmount = fullAmount - progress;
            uint256 applied = remaining < openAmount ? remaining : openAmount;
            uint256 cumulative = progress + applied;

            installmentProgress[invoiceId] = uint128(cumulative);
            emit InstallmentPaymentApplied(invoiceId, index, applied, cumulative, fullAmount);
            remaining -= applied;

            if (cumulative == fullAmount) {
                installmentProgress[invoiceId] = 0;
                inv.paidInstallments = index + 1;
                uint256 due = installmentDue(invoiceId, index);
                bool dueWindowOpened = block.timestamp >= due;
                bool creditedOnTime;
                if (
                    dueWindowOpened && block.timestamp <= due + inv.grace
                        && !REPUTATION.permanentDefault(inv.sellerAgentId)
                ) {
                    // The ONLY input that raises L(w): a fully realized installment
                    // whose due window has opened and whose value/epoch remains eligible
                    // in the registry. Future, dust, slope-capped and terminal payments
                    // settle cash but emit `creditedOnTime=false`.
                    creditedOnTime = REPUTATION.recordOnTimeInstallment(inv.sellerAgentId, fullAmount);
                }
                emit InstallmentPaid(invoiceId, index, fullAmount, creditedOnTime);
            }
        }
    }

    /// @notice flip a missed invoice (earliest open installment past grace) into default
    ///         and run the M3 waterfall slice: holdback first, then C→B→A.
    function markDefaulted(uint256 invoiceId) public nonReentrant {
        Invoice storage inv = invoices[invoiceId];
        if (inv.status != Status.Funded) revert BadStatus(invoiceId);
        uint256 due = installmentDue(invoiceId, inv.paidInstallments);
        if (block.timestamp <= due + inv.grace) revert NotPastGrace();

        // A debtor payment already deposited into escrow (via InvoiceMemoRouter.pay) has
        // NOT advanced the shelf — settlement applies it out-of-band (paidInstallments==0 is
        // not the same as unpaid). Defaulting now would book a phantom loss (tranche C→B→A),
        // freeze a paying seller, and strand the debtor's cash. Require the keeper to drain
        // the escrow via InvoiceSettlement.settle() before any default judgement.
        if (address(escrow) != address(0) && escrow.escrowedOf(invoiceId) > 0) {
            revert EscrowPendingSettlement(invoiceId);
        }

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

        // Once Defaulted, the invoice can never settle or accept another payment. Any
        // collected holdback left after the waterfall must therefore leave invoice-local
        // accounting and remain attributable to the frozen seller for ops resolution.
        // This is only a liability reclassification: totalHoldbackHeld and cash do not move.
        uint128 contestedRemainder = inv.holdbackCollected;
        if (contestedRemainder > 0) {
            inv.holdbackCollected = 0;
            frozenHoldbackOf[inv.sellerAgentId] += contestedRemainder;
        }

        // §4.8 layer 2: the SELLER's posted reserve burns before any LP tranche
        if (loss > 0 && address(reserve) != address(0)) {
            uint256 covered = reserve.sweepFor(inv.sellerAgentId, loss);
            totalLiquid += covered; // reserve cash enters the pool
            loss -= covered;
        }
        // (layer 3 recourse/inflow-diversion is custody-layer policy — SPEC §8.2)
        // layers 4–6: allocate the residual loss C → B → A over each tranche's capacity
        if (loss > 0) {
            unrecoveredLossOf[invoiceId] = loss;
            sellerUnrecoveredLossOf[inv.sellerAgentId] += loss;
            totalUnrecoveredLoss += loss;
            _allocateLoss(loss);
        }

        // one-way freeze: no new locks, no residual releases, pending M4 resolution
        // (PERMANENT_DEFAULT vs RESTRUCTURED is an ops decision via RestructureRouter —
        //  a legitimate credit default is not automatically identity-terminal, SPEC §3.3/§4.8)
        workspaceFrozen[inv.sellerAgentId] = true;
        unresolvedDefaultCountOf[inv.sellerAgentId] += 1;
        BINV_TOKEN.burn(invoiceId);
        emit WorkspaceFrozen(inv.sellerAgentId);
        emit InvoiceDefaulted(invoiceId, loss);
    }

    /// @notice M4 resolution (ops multisig): the PERMANENT_DEFAULT vs RESTRUCTURED split.
    /// @dev Resolution classifies the event; it does not forgive an LP loss. Frozen
    ///      recourse cash is first netted against the invoice's unrecovered balance on
    ///      either path. A legitimate seller reopens only after every default is resolved
    ///      and every dollar of seller loss has been recovered.
    function resolveDefault(uint256 invoiceId, bool fraud) external onlyRole(OPS_ROLE) nonReentrant {
        Invoice storage inv = invoices[invoiceId];
        if (inv.status != Status.Defaulted) revert BadStatus(invoiceId);
        if (defaultResolutionOf[invoiceId] != DefaultResolution.Unresolved) {
            revert DefaultAlreadyResolved(invoiceId);
        }

        uint256 sellerAgentId = inv.sellerAgentId;
        uint256 remainingDefaults = unresolvedDefaultCountOf[sellerAgentId] - 1;
        unresolvedDefaultCountOf[sellerAgentId] = remainingDefaults;
        defaultResolutionOf[invoiceId] = fraud ? DefaultResolution.Fraud : DefaultResolution.Restructured;

        if (fraud) {
            REPUTATION.setPermanentDefault(sellerAgentId);
        } else {
            bool terminal = REPUTATION.permanentDefault(sellerAgentId);
            if (!terminal) REPUTATION.markRestructured(sellerAgentId);
        }

        _netFrozenHoldback(invoiceId, inv);
        _finalizeSellerResolution(sellerAgentId);
        emit DefaultResolved(invoiceId, fraud);
    }

    /// @notice Apply already-custodied seller recourse to a specific default loss.
    /// @dev A different invoice can settle after this default has already received its
    ///      ops classification. Its residual then arrives in `frozenHoldbackOf` too late
    ///      for `resolveDefault` to consume it. This permissionless, cash-conserving path
    ///      lets keepers (or anyone) net that late recourse without a second ops decision.
    function applyFrozenHoldback(uint256 invoiceId) external nonReentrant returns (uint256 applied) {
        Invoice storage inv = invoices[invoiceId];
        if (inv.status != Status.Defaulted) revert BadStatus(invoiceId);

        applied = _netFrozenHoldback(invoiceId, inv);
        _finalizeSellerResolution(inv.sellerAgentId);
    }

    /// @notice Repay a defaulted invoice with new cash, capped at its unrecovered loss.
    /// @dev Permissionless funding lets a debtor, seller, guarantor or servicer cure the
    ///      loss. The transfer happens before accounting and the full transaction reverts
    ///      unless the booked-loss ledger can reverse the exact cash amount senior-first.
    function recoverDefault(uint256 invoiceId, uint256 amount) external nonReentrant {
        Invoice storage inv = invoices[invoiceId];
        if (inv.status != Status.Defaulted) revert BadStatus(invoiceId);
        if (amount == 0) revert ZeroAmount();

        uint256 available = unrecoveredLossOf[invoiceId];
        if (amount > available) revert RecoveryExceedsUnrecoveredLoss(amount, available);

        USDC.safeTransferFrom(msg.sender, address(this), amount);
        _applyLossRecovery(invoiceId, inv, amount, msg.sender);
        totalLiquid += amount;
        _finalizeSellerResolution(inv.sellerAgentId);
    }

    // ── Views ──────────────────────────────────────────────────────────

    function installmentDue(uint256 invoiceId, uint8 index) public view returns (uint256) {
        Invoice storage inv = invoices[invoiceId];
        return uint256(inv.firstMaturity) + uint256(index) * inv.interval;
    }

    /// @notice Deterministic face-value allocation for a fixed-maturity slot.
    /// @dev Floor division applies to every non-final slot; the final slot receives
    ///      the remainder so the schedule sums exactly to face.
    function installmentAmount(uint256 invoiceId, uint8 index) public view returns (uint256) {
        Invoice storage inv = invoices[invoiceId];
        if (inv.status == Status.None) revert UnknownInvoice(invoiceId);
        if (index >= inv.nInstallments) revert BadInstallmentIndex(invoiceId, index);
        return _installmentAmount(inv, index);
    }

    /// @notice Return the shelf-authoritative earliest incomplete installment.
    /// @dev This is a projection over the existing schedule and progress ledger; no
    ///      router, escrow or off-chain assertion can write or override these values.
    function currentInstallment(uint256 invoiceId)
        external
        view
        returns (uint8 index, uint256 fullAmount, uint256 paidAmount, uint256 maturity, uint256 graceEndsAt)
    {
        Invoice storage inv = invoices[invoiceId];
        if (inv.status != Status.Funded || inv.paidInstallments >= inv.nInstallments) {
            revert NoCurrentInstallment(invoiceId, inv.status);
        }

        index = inv.paidInstallments;
        fullAmount = _installmentAmount(inv, index);
        paidAmount = installmentProgress[invoiceId];
        maturity = uint256(inv.firstMaturity) + uint256(index) * inv.interval;
        graceEndsAt = maturity + inv.grace;
    }

    /// @notice rail-facing views (IInvoiceShelf)
    function invoiceStatus(uint256 invoiceId) external view returns (Status) {
        return invoices[invoiceId].status;
    }

    function sellerAgentIdOf(uint256 invoiceId) external view returns (uint256) {
        return invoices[invoiceId].sellerAgentId;
    }

    /// @notice Current authoritative payer for the debtor workspace recorded at lock.
    /// @dev Ownership rotation in the identity registry intentionally rotates payment
    ///      authority; the receivable remains bound to the immutable debtor agent id.
    function debtorPayerOf(uint256 invoiceId) external view returns (address) {
        Invoice storage inv = invoices[invoiceId];
        if (inv.status == Status.None) revert UnknownInvoice(invoiceId);
        return IDENTITY.ownerOf(inv.debtorAgentId);
    }

    /// @notice SPEC §6.2 NAV numerator per tranche: contributed capital minus allocated
    ///         loss (accrued yield / reserveCredit are future terms, 0 today). BUFIOracle
    ///         divides this by the tranche's share supply.
    function trancheAssets(uint8 tranche) public view returns (uint256) {
        _requireValidTranche(tranche);
        uint256 dep = trancheDeposits[tranche];
        uint256 loss = trancheLoss[tranche];
        return dep > loss ? dep - loss : 0;
    }

    /// @notice Net origination capacity in a tranche (NAV minus already selected principal).
    function trancheCapacity(uint8 tranche) public view returns (uint256) {
        uint256 assets = trancheAssets(tranche);
        uint256 principal = tranchePrincipal[tranche];
        return assets > principal ? assets - principal : 0;
    }

    // ── Internals ──────────────────────────────────────────────────────

    function _requireValidTranche(uint8 tranche) internal pure {
        if (tranche >= TRANCHE_COUNT) revert InvalidTranche(tranche);
    }

    function _installmentAmount(Invoice storage inv, uint8 index) internal view returns (uint256) {
        uint256 base = uint256(inv.face) / inv.nInstallments;
        if (index + 1 < inv.nInstallments) return base;
        return uint256(inv.face) - base * (inv.nInstallments - 1);
    }

    function _settle(uint256 invoiceId, Invoice storage inv) internal {
        inv.status = Status.Settled;
        uint256 residual = inv.holdbackCollected; // only CASH actually collected is releasable
        uint256 released;
        uint256 contested;
        inv.holdbackCollected = 0;
        if (residual > 0) {
            if (!workspaceFrozen[inv.sellerAgentId]) {
                totalHoldbackHeld -= residual;
                USDC.safeTransfer(IDENTITY.ownerOf(inv.sellerAgentId), residual);
                released = residual;
            } else {
                // Frozen (cross-default): the seller's residual is CONTESTED capital,
                // not released and not seized into the LP pool — it stays custodied in
                // totalHoldbackHeld and is netted against recourse when M4 resolveDefault
                // runs. Keeps both the pool identity and cash-backed invariants intact.
                frozenHoldbackOf[inv.sellerAgentId] += residual;
                contested = residual;
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
        // Pair history means a prior invoice completed, not merely that one slot on
        // a still-open invoice was paid. Dust invoices remain economically ineligible.
        if (inv.face >= Params.MIN_PAIR_SETTLEMENT_USDC && !REPUTATION.permanentDefault(inv.sellerAgentId)) {
            REPUTATION.recordPairSettlement(inv.sellerAgentId, inv.debtorAgentId);
        }
        emit InvoiceSettled(invoiceId, released, contested);
    }

    function _reduceExposure(Invoice storage inv, uint128 amount) internal {
        outstandingOf[inv.sellerAgentId] -= amount;
        debtorOutstandingOf[inv.sellerAgentId][inv.debtorAgentId] -= amount;
        tranchePrincipal[inv.tranche] -= amount;
    }

    /// @dev SPEC §4.8 layers 4–6 / §6.2: losses fill junior-first — C until its
    ///      capacity (deposits − loss) is exhausted, then B, then A. Senior NAV holds
    ///      par until junior+mezz are wiped (invariant_seniorNavParUnlessJuniorExhausted).
    ///      If loss exceeds all capacity (catastrophic), the remainder is unabsorbed —
    ///      pool insolvency, surfaced rather than silently mis-booked.
    function _allocateLoss(uint256 loss) internal {
        uint256 requested = loss;
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
        if (loss != 0) revert LossAccountingMismatch(requested, requested - loss);
    }

    /// @dev reverse of _allocateLoss: apply a recovery against booked losses, senior-first
    ///      (A repaid before B before C — recoveries unwind the waterfall from the top).
    ///      Returns the amount actually applied (≤ recovery, capped at total booked loss).
    function _recoverLoss(uint256 invoiceId, uint256 sellerAgentId, uint256 recovery, address source)
        internal
        returns (uint256 applied)
    {
        for (uint8 t = 0; t < 3; ++t) {
            uint256 booked = trancheLoss[t];
            uint256 take = recovery < booked ? recovery : booked;
            if (take > 0) {
                trancheLoss[t] -= take;
                recovery -= take;
                applied += take;
                emit LossRecovered(invoiceId, sellerAgentId, t, take, source);
            }
            if (recovery == 0) break;
        }
    }

    function _applyLossRecovery(uint256 invoiceId, Invoice storage inv, uint256 amount, address source) internal {
        unrecoveredLossOf[invoiceId] -= amount;
        sellerUnrecoveredLossOf[inv.sellerAgentId] -= amount;
        totalUnrecoveredLoss -= amount;
        uint256 applied = _recoverLoss(invoiceId, inv.sellerAgentId, amount, source);
        if (applied != amount) revert LossAccountingMismatch(amount, applied);
    }

    /// @dev Apply seller-attributed, already-custodied recourse cash against the
    ///      invoice being resolved. Accounting reclassifies cash from holdback
    ///      liability to pool liquidity; no token transfer is fabricated.
    function _netFrozenHoldback(uint256 invoiceId, Invoice storage inv) internal returns (uint256 applied) {
        uint256 sellerAgentId = inv.sellerAgentId;
        uint256 contested = frozenHoldbackOf[sellerAgentId];
        uint256 invoiceLoss = unrecoveredLossOf[invoiceId];
        applied = contested < invoiceLoss ? contested : invoiceLoss;
        if (applied == 0) return 0;

        frozenHoldbackOf[sellerAgentId] = contested - applied;
        totalHoldbackHeld -= applied;
        _applyLossRecovery(invoiceId, inv, applied, address(this));
        totalLiquid += applied;
        emit ContestedHoldbackRecovered(invoiceId, sellerAgentId, applied, contested - applied);
    }

    /// @dev Release only true excess holdback. A legitimate restructure reopens only
    ///      after every default has a resolution and the seller owes the pool nothing.
    ///      Fraud remains identity-terminal, but cannot justify seizing cash above loss.
    function _finalizeSellerResolution(uint256 sellerAgentId) internal {
        if (unresolvedDefaultCountOf[sellerAgentId] != 0 || sellerUnrecoveredLossOf[sellerAgentId] != 0) return;

        uint256 excess = frozenHoldbackOf[sellerAgentId];
        if (excess > 0) {
            frozenHoldbackOf[sellerAgentId] = 0;
            totalHoldbackHeld -= excess;
            USDC.safeTransfer(IDENTITY.ownerOf(sellerAgentId), excess);
        }

        if (REPUTATION.permanentDefault(sellerAgentId)) return;
        workspaceFrozen[sellerAgentId] = false;
        if (address(reserve) != address(0) && outstandingOf[sellerAgentId] == 0) {
            reserve.setRequired(sellerAgentId, 0);
        }
    }

    function _totalBookedLoss() internal view returns (uint256) {
        return trancheLoss[0] + trancheLoss[1] + trancheLoss[2];
    }
}
