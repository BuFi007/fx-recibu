// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BUFIIdentityRegistry} from "../../src/identity/BUFIIdentityRegistry.sol";
import {BUFIReputationRegistry} from "../../src/identity/BUFIReputationRegistry.sol";
import {WorkspaceTierRegistry} from "../../src/credit/WorkspaceTierRegistry.sol";
import {Params} from "../../src/libraries/Params.sol";

contract WorkspaceTierRegistryTest is Test {
    BUFIIdentityRegistry internal identity;
    BUFIReputationRegistry internal reputation;
    WorkspaceTierRegistry internal tiers;

    address internal admin = makeAddr("admin");
    address internal issuer = makeAddr("issuer");
    address internal attestor = makeAddr("attestor");
    address internal settlement = makeAddr("settlement");
    address internal ops = makeAddr("ops");

    uint256 internal agentId;

    function setUp() public {
        identity = new BUFIIdentityRegistry(admin);
        reputation = new BUFIReputationRegistry(admin, identity);
        tiers = new WorkspaceTierRegistry(identity, reputation);

        vm.startPrank(admin);
        identity.grantRole(identity.ISSUER_ROLE(), issuer);
        reputation.grantRole(reputation.ATTESTOR_ROLE(), attestor);
        reputation.grantRole(reputation.SETTLEMENT_ROLE(), settlement);
        reputation.grantRole(reputation.OPS_ROLE(), ops);
        vm.stopPrank();

        vm.prank(issuer);
        agentId = identity.registerWorkspace(keccak256("ws"), makeAddr("o"));
    }

    // ── SPEC §3.0 tier bands (table-driven, matches desk-v1 bands) ──

    function test_tierBands_matchSpec() public view {
        assertEq(uint8(tiers.tierOf(100)), uint8(WorkspaceTierRegistry.Tier.Excellent));
        assertEq(uint8(tiers.tierOf(85)), uint8(WorkspaceTierRegistry.Tier.Excellent));
        assertEq(uint8(tiers.tierOf(84)), uint8(WorkspaceTierRegistry.Tier.Strong));
        assertEq(uint8(tiers.tierOf(70)), uint8(WorkspaceTierRegistry.Tier.Strong));
        assertEq(uint8(tiers.tierOf(69)), uint8(WorkspaceTierRegistry.Tier.Moderate));
        assertEq(uint8(tiers.tierOf(50)), uint8(WorkspaceTierRegistry.Tier.Moderate));
        assertEq(uint8(tiers.tierOf(49)), uint8(WorkspaceTierRegistry.Tier.Developing));
        assertEq(uint8(tiers.tierOf(0)), uint8(WorkspaceTierRegistry.Tier.Developing));
    }

    // ── SPEC §3.1 advance rates (debtor prices the money) ──

    function test_advanceRates_matchSpecMatrix() public view {
        assertEq(tiers.advanceRateBps(90, true), 9000);
        assertEq(tiers.advanceRateBps(75, true), 8500);
        assertEq(tiers.advanceRateBps(55, true), 7500);
        assertEq(tiers.advanceRateBps(30, true), 6000);
        // no pair history → −500bps and forced-junior elsewhere
        assertEq(tiers.advanceRateBps(90, false), 8500);
        assertEq(tiers.advanceRateBps(30, false), 5500);
    }

    // ── SPEC §3.2 reserve + bond (seller prices the trust) ──

    function test_reserveAndBond_matchSpecMatrix() public view {
        assertEq(tiers.reserveRatioBps(90), 1000);
        assertEq(tiers.reserveRatioBps(75), 1500);
        assertEq(tiers.reserveRatioBps(55), 2000);
        assertEq(tiers.reserveRatioBps(10), 2500);
        assertEq(tiers.bondShareBps(10), 10_000); // Developing: full posted bond
        assertEq(tiers.bondShareBps(55), 5_000); // Moderate: half
        assertEq(tiers.bondShareBps(75), 0); // Strong+: accrued, capital-light
        assertEq(tiers.bondShareBps(90), 0);
    }

    // ── SPEC §3.3 / §3.4 recourse + tranche ──

    function test_nonRecourse_bothStrongWithHistoryOnly() public view {
        assertTrue(tiers.nonRecourseEligible(70, 70, true));
        assertFalse(tiers.nonRecourseEligible(70, 70, false));
        assertFalse(tiers.nonRecourseEligible(69, 90, true));
        assertFalse(tiers.nonRecourseEligible(90, 69, true));
    }

    function test_trancheEligibility_matchesSpec() public view {
        assertEq(uint8(tiers.trancheEligibility(90, 75, true)), uint8(WorkspaceTierRegistry.TrancheEligibility.SeniorA));
        assertEq(uint8(tiers.trancheEligibility(90, 55, true)), uint8(WorkspaceTierRegistry.TrancheEligibility.MezzB));
        assertEq(uint8(tiers.trancheEligibility(55, 90, true)), uint8(WorkspaceTierRegistry.TrancheEligibility.MezzB));
        assertEq(uint8(tiers.trancheEligibility(90, 30, true)), uint8(WorkspaceTierRegistry.TrancheEligibility.JuniorC));
        assertEq(
            uint8(tiers.trancheEligibility(90, 90, false)), uint8(WorkspaceTierRegistry.TrancheEligibility.JuniorC)
        );
    }

    // ── SPEC §3.5 / §4.9: THE invariant — L(w) moves only on realized repayment ──

    function test_limit_coldStartAndRamp() public {
        assertEq(tiers.limitOf(agentId), Params.L0_USDC);
        vm.startPrank(settlement);
        reputation.recordOnTimeInstallment(agentId);
        reputation.recordOnTimeInstallment(agentId);
        reputation.recordOnTimeInstallment(agentId);
        vm.stopPrank();
        assertEq(tiers.limitOf(agentId), Params.L0_USDC + 3 * Params.RAMP_STEP_USDC);
    }

    function test_limit_zeroOnPermanentDefault() public {
        vm.prank(settlement);
        reputation.recordOnTimeInstallment(agentId);
        vm.prank(ops);
        reputation.setPermanentDefault(agentId);
        assertEq(tiers.limitOf(agentId), 0);
        assertFalse(tiers.eligible(agentId));
    }

    /// @dev fuzz: a score attestation ALONE never moves L(w) — the §4.9 invariant.
    function testFuzz_scoreAttestationNeverMovesLimit(uint8 sellerScore, uint8 debtorScore, uint32 modelVersion)
        public
    {
        sellerScore = uint8(bound(sellerScore, 0, 100));
        debtorScore = uint8(bound(debtorScore, 0, 100));
        uint256 before = tiers.limitOf(agentId);
        vm.prank(attestor);
        reputation.setScore(agentId, sellerScore, debtorScore, modelVersion, bytes32("r"));
        assertEq(tiers.limitOf(agentId), before, "score attestation moved L(w)");
    }

    /// @dev fuzz: L(w) is monotone non-decreasing in realized on-time installments, capped at L_MAX.
    function testFuzz_limitMonotoneAndCapped(uint16 installments) public {
        installments = uint16(bound(installments, 0, 2000));
        uint256 prev = tiers.limitOf(agentId);
        for (uint256 i = 0; i < installments; ++i) {
            vm.prank(settlement);
            reputation.recordOnTimeInstallment(agentId);
            uint256 cur = tiers.limitOf(agentId);
            assertGe(cur, prev, "L(w) decreased");
            assertLe(cur, Params.L_MAX_USDC, "L(w) exceeded cap");
            prev = cur;
        }
    }

    function test_eligible_requiresKyb() public {
        assertFalse(tiers.eligible(agentId)); // registered but not KYB'd
        vm.prank(issuer);
        identity.setKybStatus(agentId, true);
        assertTrue(tiers.eligible(agentId));
    }

    function test_pairHistory_fromRealizedSettlementsOnly() public {
        vm.prank(issuer);
        uint256 debtor = identity.registerWorkspace(keccak256("debtor"), makeAddr("d"));
        assertFalse(tiers.hasPairHistory(agentId, debtor));
        vm.prank(settlement);
        reputation.recordPairSettlement(agentId, debtor);
        assertTrue(tiers.hasPairHistory(agentId, debtor));
    }
}
