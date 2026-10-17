// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {BUFIIdentityRegistry} from "../../src/identity/BUFIIdentityRegistry.sol";
import {DocumentReceivableRegistry} from "../../src/invoice/DocumentReceivableRegistry.sol";
import {IDocumentReceivableRegistry} from "../../src/interfaces/IDocumentReceivableRegistry.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Handler
// ─────────────────────────────────────────────────────────────────────────────

/// @notice Ghost-variable handler.  Drives the registry through all four write
///         paths and maintains mirror state so the invariant harness can verify
///         the registry's storage without re-deriving it from Solidity.
///
///         C1: principal is fuzzed per register (bound [1, 1e30]).
///         C2: ghost owner per evidence + evidence invariant.
///         C3: independent paidUnits mirror + id-sequencing + nextReceivableId.
///         C4: termsHash history + ghostAmends counter.
///         C5: adversarial attack() action — any unexpected success counted.
///         C6: ghostUnPaid counter for reversals that move a receivable out of Paid.
contract DRRHandler is Test {
    // ── registry under test ───────────────────────────────────────────────────
    DocumentReceivableRegistry internal registry;

    // ── non-writer address for adversarial attacks ────────────────────────────
    address internal _nonWriter = makeAddr("nonWriter");

    // ── ghost: registered ids ────────────────────────────────────────────────
    uint256[] internal _ids;

    // ── ghost: per-id payment evidence list ──────────────────────────────────
    mapping(uint256 => bytes32[]) internal _evidences;

    // ── ghost: call counters (non-vacuousness, C6) ────────────────────────────
    uint256 public ghostRegisters;
    uint256 public ghostPayments;
    uint256 public ghostReversals;
    uint256 public ghostAmends;
    uint256 public ghostAttacks; // C5
    uint256 public ghostUnPaid; // C6: reversals that moved a Paid receivable out of Paid
    uint256 public ghostUnexpectedSuccess; // C5: adversarial calls that did NOT revert

    // ── ghost: gross and reversed per id (C3 mirror) ──────────────────────────
    mapping(uint256 => uint128) public ghostGrossApplied;
    mapping(uint256 => uint128) public ghostReversedById;

    // ── ghost: per-evidence applied & reversed (C2) ───────────────────────────
    mapping(bytes32 => uint128) public ghostEvidenceApplied;
    mapping(bytes32 => uint128) public ghostEvidenceReversed;
    mapping(bytes32 => uint256) public ghostEvidenceOwner; // C2: receivableId that owns the evidence

    // ── ghost: used evidence set ──────────────────────────────────────────────
    bytes32[] internal _allEvidences;
    mapping(bytes32 => bool) internal _evidenceUsed;

    // ── ghost: per-id original terms hash (C4) ────────────────────────────────
    mapping(uint256 => bytes32) public ghostOriginalTermsHash;
    mapping(uint256 => uint256) public ghostAmendCount; // C4: number of amendments per id

    // ── ghost: per-id principal (C1) ──────────────────────────────────────────
    mapping(uint256 => uint128) public ghostPrincipal;

    // ── internal sequence counters ────────────────────────────────────────────
    uint256 internal _docNonce;
    uint256 internal _evidenceNonce;

    // ── creditor (pre-registered) ──────────────────────────────────────────────
    uint256 internal _creditorAgentId;

    uint64 internal constant ISSUED_AT = 1_700_000_000;
    uint64 internal constant DUE_AT = ISSUED_AT + 30 days;

    constructor(DocumentReceivableRegistry reg, uint256 creditorAgentId) {
        registry = reg;
        _creditorAgentId = creditorAgentId;
        vm.warp(ISSUED_AT + 1);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Actions
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Register a new receivable with a fuzzed principal (C1: bound [1, 1e30]).
    function register(uint8 installments, uint128 principalSeed) external {
        installments = uint8(bound(installments, 1, 10));
        uint128 principal = uint128(bound(principalSeed, 1, 1e30));

        _docNonce++;
        bytes32 docCommitment = keccak256(abi.encodePacked("doc", _docNonce));
        bytes32 termsHash = keccak256(abi.encodePacked("terms", _docNonce));

        IDocumentReceivableRegistry.RegisterArgs memory a = IDocumentReceivableRegistry.RegisterArgs({
            documentCommitment: docCommitment,
            creditorAgentId: _creditorAgentId,
            debtorCommitment: keccak256(abi.encodePacked("debtor", _docNonce)),
            principal: principal,
            unit: keccak256("USDC"),
            issuedAt: ISSUED_AT,
            dueAt: DUE_AT,
            installments: installments,
            termsHash: termsHash,
            destinationDigest: keccak256(abi.encodePacked("dest", _docNonce))
        });

        uint256 id = registry.register(a);
        _ids.push(id);
        ghostPrincipal[id] = principal;
        ghostOriginalTermsHash[id] = termsHash;
        ghostRegisters++;
    }

    /// @dev Record a payment on an existing receivable.
    function recordPayment(uint256 idSeed, uint128 amount) external {
        if (_ids.length == 0) return;

        uint256 id = _ids[idSeed % _ids.length];
        IDocumentReceivableRegistry.Receivable memory r = registry.receivableOf(id);

        uint128 remaining = r.principal - r.paidUnits;
        if (remaining == 0) return; // already paid

        amount = uint128(bound(amount, 1, remaining));

        _evidenceNonce++;
        bytes32 evidence = keccak256(abi.encodePacked("ev", _evidenceNonce));
        uint8 installment = uint8(bound(_evidenceNonce, 1, r.installments));

        registry.recordPayment(id, installment, amount, evidence, keccak256(abi.encodePacked("legs", _evidenceNonce)));

        // Update ghosts.
        _evidences[id].push(evidence);
        _allEvidences.push(evidence);
        _evidenceUsed[evidence] = true;
        ghostGrossApplied[id] += amount;
        ghostEvidenceApplied[evidence] = amount;
        ghostEvidenceOwner[evidence] = id; // C2
        ghostPayments++;
    }

    /// @dev Record a reversal on a previously recorded payment.
    function recordReversal(uint256 idSeed, uint256 evidenceSeed, uint128 units) external {
        if (_ids.length == 0) return;

        uint256 id = _ids[idSeed % _ids.length];
        bytes32[] storage evs = _evidences[id];
        if (evs.length == 0) return;

        bytes32 evidence = evs[evidenceSeed % evs.length];
        uint128 reversible = ghostEvidenceApplied[evidence] - ghostEvidenceReversed[evidence];
        if (reversible == 0) return;

        units = uint128(bound(units, 1, reversible));

        // Check if receivable is currently Paid (for C6 counter).
        bool wasPaid = registry.receivableOf(id).status == IDocumentReceivableRegistry.Status.Paid;

        registry.recordReversal(id, evidence, units, keccak256(abi.encodePacked("reason", _evidenceNonce)));

        // C6: count reversals that moved a Paid receivable out of Paid.
        if (wasPaid && registry.receivableOf(id).status != IDocumentReceivableRegistry.Status.Paid) {
            ghostUnPaid++;
        }

        // Update ghosts.
        ghostReversedById[id] += units;
        ghostEvidenceReversed[evidence] += units;
        ghostReversals++;
    }

    /// @dev Amend the terms of an existing, non-Paid receivable.
    function amendTerms(uint256 idSeed) external {
        if (_ids.length == 0) return;

        uint256 id = _ids[idSeed % _ids.length];
        IDocumentReceivableRegistry.Receivable memory r = registry.receivableOf(id);

        if (r.status == IDocumentReceivableRegistry.Status.Paid) return;

        uint32 newVersion = r.termsVersion + 1;
        bytes32 newTermsHash = keccak256(abi.encodePacked("terms", id, newVersion));

        registry.amendTerms(id, newTermsHash, newVersion, keccak256(abi.encodePacked("auth", id, newVersion)));
        ghostAmendCount[id]++; // C4
        ghostAmends++;
    }

    /// @dev Adversarial action (C5): try operations that MUST revert.
    ///      Uses try/catch — any call that does NOT revert increments ghostUnexpectedSuccess.
    function attack(uint256 seed) external {
        ghostAttacks++;

        uint8 kind = uint8(seed % 8);

        if (kind == 0) {
            // Duplicate register of an existing documentCommitment.
            if (_ids.length == 0) return;
            uint256 id = _ids[seed % _ids.length];
            bytes32 existingDoc = registry.receivableOf(id).documentCommitment;
            IDocumentReceivableRegistry.RegisterArgs memory a = IDocumentReceivableRegistry.RegisterArgs({
                documentCommitment: existingDoc,
                creditorAgentId: _creditorAgentId,
                debtorCommitment: keccak256("x"),
                principal: 1,
                unit: keccak256("USDC"),
                issuedAt: ISSUED_AT,
                dueAt: DUE_AT,
                installments: 1,
                termsHash: keccak256("t"),
                destinationDigest: keccak256("d")
            });
            try registry.register(a) {
                ghostUnexpectedSuccess++;
            } catch {}
        } else if (kind == 1) {
            // Reuse an existing evidence on a different id.
            if (_allEvidences.length == 0 || _ids.length < 2) return;
            bytes32 ev = _allEvidences[seed % _allEvidences.length];
            uint256 ownerIdx = (seed >> 8) % _ids.length;
            uint256 otherId = _ids[ownerIdx];
            // Pick any id — may or may not be the owner, both should revert.
            _evidenceNonce++;
            bytes32 freshEv = keccak256(abi.encodePacked("attack-ev", _evidenceNonce));
            // Use the existing evidence (must fail EvidenceAlreadyUsed).
            try registry.recordPayment(otherId, 1, 1, ev, keccak256("legs")) {
                ghostUnexpectedSuccess++;
            } catch {}
            // Use fresh evidence on id 0 (must fail UnknownReceivable).
            try registry.recordPayment(0, 1, 1, freshEv, keccak256("legs")) {
                ghostUnexpectedSuccess++;
            } catch {}
        } else if (kind == 2) {
            // Overpay.
            if (_ids.length == 0) return;
            uint256 id = _ids[seed % _ids.length];
            IDocumentReceivableRegistry.Receivable memory r = registry.receivableOf(id);
            // Exactly one unit past the REMAINING capacity (not past principal), so a
            // check that compared against principal instead of remaining would be caught.
            uint128 overpay = (r.principal - r.paidUnits) + 1;
            _evidenceNonce++;
            bytes32 freshEv = keccak256(abi.encodePacked("ov-ev", _evidenceNonce));
            try registry.recordPayment(id, 1, overpay, freshEv, keccak256("legs")) {
                ghostUnexpectedSuccess++;
            } catch (bytes memory err) {
                if (bytes4(err) != IDocumentReceivableRegistry.Overpayment.selector) ghostUnexpectedSuccess++;
            }
        } else if (kind == 3) {
            // Reverse evidence on the wrong id.
            if (_allEvidences.length == 0 || _ids.length < 2) return;
            bytes32 ev = _allEvidences[seed % _allEvidences.length];
            (uint256 ownerId,,) = registry.paymentOf(ev);
            uint256 wrongId = _ids[(seed >> 4) % _ids.length];
            if (wrongId == ownerId) return;
            try registry.recordReversal(wrongId, ev, 1, keccak256("reason")) {
                ghostUnexpectedSuccess++;
            } catch {}
        } else if (kind == 4) {
            // Reverse more than reversible.
            if (_allEvidences.length == 0) return;
            bytes32 ev = _allEvidences[seed % _allEvidences.length];
            (uint256 ownerId, uint128 applied, uint128 alreadyRev) = registry.paymentOf(ev);
            if (ownerId == 0) return;
            uint128 excess = applied - alreadyRev + 1;
            try registry.recordReversal(ownerId, ev, excess, keccak256("reason")) {
                ghostUnexpectedSuccess++;
            } catch {}
        } else if (kind == 5) {
            // Amend with wrong version.
            if (_ids.length == 0) return;
            uint256 id = _ids[seed % _ids.length];
            IDocumentReceivableRegistry.Receivable memory r = registry.receivableOf(id);
            uint32 badVersion = r.termsVersion + 2; // skip a version
            try registry.amendTerms(id, keccak256("t"), badVersion, keccak256("a")) {
                ghostUnexpectedSuccess++;
            } catch {}
        } else if (kind == 6) {
            // Amend a Paid receivable.
            if (_ids.length == 0) return;
            uint256 id = _ids[seed % _ids.length];
            IDocumentReceivableRegistry.Receivable memory r = registry.receivableOf(id);
            if (r.status != IDocumentReceivableRegistry.Status.Paid) return;
            try registry.amendTerms(id, keccak256("t"), r.termsVersion + 1, keccak256("a")) {
                ghostUnexpectedSuccess++;
            } catch {}
        } else {
            // Write from a non-writer address.
            if (_ids.length == 0) return;
            uint256 id = _ids[seed % _ids.length];
            _evidenceNonce++;
            bytes32 freshEv = keccak256(abi.encodePacked("nw-ev", _evidenceNonce));
            vm.prank(_nonWriter);
            try registry.recordPayment(id, 1, 1, freshEv, keccak256("legs")) {
                ghostUnexpectedSuccess++;
            } catch {}
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers for invariant assertions
    // ─────────────────────────────────────────────────────────────────────────

    function idCount() external view returns (uint256) {
        return _ids.length;
    }

    function idAt(uint256 index) external view returns (uint256) {
        return _ids[index];
    }

    function allEvidences(uint256 index) external view returns (bytes32) {
        return _allEvidences[index];
    }

    function allEvidencesLength() external view returns (uint256) {
        return _allEvidences.length;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Invariant harness
// ─────────────────────────────────────────────────────────────────────────────
contract DocumentReceivableRegistryInvariants is StdInvariant, Test {
    BUFIIdentityRegistry internal identity;
    DocumentReceivableRegistry internal registry;
    DRRHandler internal handler;

    address internal admin = makeAddr("admin");
    uint256 internal creditorAgentId;

    function setUp() public {
        // Deploy identity registry and register one creditor.
        address identityAdmin = makeAddr("identityAdmin");
        identity = new BUFIIdentityRegistry(identityAdmin);

        vm.prank(identityAdmin);
        identity.grantRole(keccak256("ISSUER_ROLE"), identityAdmin);
        vm.prank(identityAdmin);
        creditorAgentId = identity.registerWorkspace(keccak256("ws-handler"), identityAdmin);

        // Deploy registry.
        registry = new DocumentReceivableRegistry(admin, address(identity));

        // Deploy handler and grant it WRITER_ROLE.
        handler = new DRRHandler(registry, creditorAgentId);
        vm.prank(admin);
        registry.grantRole(keccak256("WRITER_ROLE"), address(handler));

        // Tell forge to target only the handler.
        targetContract(address(handler));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Invariants
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice For every registered receivable: paidUnits == grossAppliedUnits - reversedUnits.
    function invariant_paidUnitsConsistency() public view {
        uint256 count = handler.idCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 id = handler.idAt(i);
            IDocumentReceivableRegistry.Receivable memory r = registry.receivableOf(id);
            assertEq(r.paidUnits, r.grossAppliedUnits - r.reversedUnits, "paid != gross - reversed");
        }
    }

    /// @notice paidUnits <= principal for every receivable.
    function invariant_paidNeverExceedsPrincipal() public view {
        uint256 count = handler.idCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 id = handler.idAt(i);
            IDocumentReceivableRegistry.Receivable memory r = registry.receivableOf(id);
            assertLe(r.paidUnits, r.principal, "paid > principal");
        }
    }

    /// @notice Status is consistent with paidUnits and principal.
    function invariant_statusConsistency() public view {
        uint256 count = handler.idCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 id = handler.idAt(i);
            IDocumentReceivableRegistry.Receivable memory r = registry.receivableOf(id);

            IDocumentReceivableRegistry.Status expected;
            if (r.paidUnits == 0) {
                expected = IDocumentReceivableRegistry.Status.Open;
            } else if (r.paidUnits < r.principal) {
                expected = IDocumentReceivableRegistry.Status.PartiallyPaid;
            } else {
                expected = IDocumentReceivableRegistry.Status.Paid;
            }

            assertEq(uint8(r.status), uint8(expected), "status inconsistent");
        }
    }

    /// @notice idOfCommitment(receivableOf(id).documentCommitment) == id (bijection).
    function invariant_commitmentBijection() public view {
        uint256 count = handler.idCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 id = handler.idAt(i);
            IDocumentReceivableRegistry.Receivable memory r = registry.receivableOf(id);
            assertEq(registry.idOfCommitment(r.documentCommitment), id, "bijection broken");
        }
    }

    /// @notice outstandingUnits(id) == principal - paidUnits.
    function invariant_outstandingUnits() public view {
        uint256 count = handler.idCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 id = handler.idAt(i);
            IDocumentReceivableRegistry.Receivable memory r = registry.receivableOf(id);
            assertEq(registry.outstandingUnits(id), r.principal - r.paidUnits, "outstanding wrong");
        }
    }

    /// @notice address(registry).balance == 0 always.
    function invariant_noEtherBalance() public view {
        assertEq(address(registry).balance, 0, "registry holds ETH");
    }

    /// @notice termsVersion >= 1 for all registered receivables.
    function invariant_termsVersionAtLeastOne() public view {
        uint256 count = handler.idCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 id = handler.idAt(i);
            IDocumentReceivableRegistry.Receivable memory r = registry.receivableOf(id);
            assertGe(r.termsVersion, 1, "termsVersion < 1");
        }
    }

    /// @notice Per-evidence: reversedUnits <= appliedUnits.
    function invariant_evidenceReversedNeverExceedsApplied() public view {
        uint256 evLen = handler.allEvidencesLength();
        for (uint256 i = 0; i < evLen; i++) {
            bytes32 ev = handler.allEvidences(i);
            (, uint128 applied, uint128 reversed) = registry.paymentOf(ev);
            assertLe(reversed, applied, "evidence reversed > applied");
        }
    }

    /// @notice Sum of per-evidence applied equals grossAppliedUnits per receivable,
    ///         and sum of per-evidence reversed equals reversedUnits per receivable.
    function invariant_evidenceSumsMatchReceivable() public view {
        uint256 count = handler.idCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 id = handler.idAt(i);
            IDocumentReceivableRegistry.Receivable memory r = registry.receivableOf(id);
            assertEq(handler.ghostGrossApplied(id), r.grossAppliedUnits, "grossApplied mismatch");
            assertEq(handler.ghostReversedById(id), r.reversedUnits, "reversedUnits mismatch");
        }
    }

    /// @notice C2: For every evidence paymentOf matches ghost and evidenceUsed is true.
    function invariant_evidenceOwnership() public view {
        uint256 evLen = handler.allEvidencesLength();
        for (uint256 i = 0; i < evLen; i++) {
            bytes32 ev = handler.allEvidences(i);
            (uint256 rid, uint128 applied, uint128 reversed) = registry.paymentOf(ev);
            assertEq(rid, handler.ghostEvidenceOwner(ev), "C2: owner mismatch");
            assertEq(applied, handler.ghostEvidenceApplied(ev), "C2: applied mismatch");
            assertEq(reversed, handler.ghostEvidenceReversed(ev), "C2: reversed mismatch");
            assertTrue(registry.evidenceUsed(ev), "C2: evidenceUsed false");
        }
    }

    /// @notice C3: paidUnits == ghostGross - ghostReversed (independent mirror);
    ///             ids are sequential (idAt(i) == i+1);
    ///             nextReceivableId() == idCount() + 1.
    function invariant_mirrorAndSequencing() public view {
        uint256 count = handler.idCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 id = handler.idAt(i);
            // Sequential ids start at 1.
            assertEq(id, i + 1, "C3: id not sequential");
            IDocumentReceivableRegistry.Receivable memory r = registry.receivableOf(id);
            uint128 mirrorPaid = handler.ghostGrossApplied(id) - handler.ghostReversedById(id);
            assertEq(r.paidUnits, mirrorPaid, "C3: mirror paid mismatch");
        }
        assertEq(registry.nextReceivableId(), count + 1, "C3: nextReceivableId wrong");
    }

    /// @notice C4: termsHashAt(id, r.termsVersion) == r.termsHash;
    ///             termsHashAt(id, 1) == ghostOriginalTermsHash;
    ///             r.termsVersion == 1 + ghostAmendCount(id).
    function invariant_termsHistory() public view {
        uint256 count = handler.idCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 id = handler.idAt(i);
            IDocumentReceivableRegistry.Receivable memory r = registry.receivableOf(id);
            // Current hash at current version matches live state.
            assertEq(registry.termsHashAt(id, r.termsVersion), r.termsHash, "C4: current hash mismatch");
            // Version 1 hash == original.
            assertEq(registry.termsHashAt(id, 1), handler.ghostOriginalTermsHash(id), "C4: original hash mismatch");
            // Version == 1 + number of amendments.
            assertEq(r.termsVersion, 1 + uint32(handler.ghostAmendCount(id)), "C4: termsVersion mismatch");
        }
    }

    /// @notice C5: No adversarial call unexpectedly succeeded.
    function invariant_noAdversarialSuccess() public view {
        assertEq(handler.ghostUnexpectedSuccess(), 0, "C5: adversarial call succeeded unexpectedly");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Non-vacuousness (C6 + existing)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice afterInvariant asserts every action kind was exercised at least once.
    function afterInvariant() public view {
        assertTrue(handler.ghostRegisters() > 0, "no registers");
        assertTrue(handler.ghostPayments() > 0, "no payments");
        assertTrue(handler.ghostReversals() > 0, "no reversals");
        assertTrue(handler.ghostAmends() > 0, "no amends");
        assertTrue(handler.ghostAttacks() > 0, "no attacks (C5)");
    }
}
