// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BUFIIdentityRegistry} from "../../src/identity/BUFIIdentityRegistry.sol";
import {BUFIReputationRegistry} from "../../src/identity/BUFIReputationRegistry.sol";
import {BUAttestation} from "../../src/identity/BUAttestation.sol";
import {IBUFIReputationRegistry} from "../../src/interfaces/IBUFIReputationRegistry.sol";

contract BUAttestationTest is Test {
    BUFIIdentityRegistry internal identity;
    BUFIReputationRegistry internal reputation;
    BUAttestation internal attestation;

    address internal admin = makeAddr("admin");
    address internal issuer = makeAddr("issuer");
    address internal relayer = makeAddr("relayer");
    uint256 internal hsmKey = 0xA11CE;
    address internal hsm;

    uint256 internal agentId;

    function setUp() public {
        hsm = vm.addr(hsmKey);
        identity = new BUFIIdentityRegistry(admin);
        reputation = new BUFIReputationRegistry(admin, identity);
        attestation = new BUAttestation(admin, hsm, identity, reputation);

        vm.startPrank(admin);
        identity.grantRole(identity.ISSUER_ROLE(), issuer);
        identity.grantRole(identity.ISSUER_ROLE(), address(attestation)); // KYB writes via attestation
        reputation.grantRole(reputation.ATTESTOR_ROLE(), address(attestation));
        vm.stopPrank();

        vm.prank(issuer);
        agentId = identity.registerWorkspace(keccak256("ws"), makeAddr("wsOwner"));
    }

    function _scoreDigest(
        uint256 agentId_,
        uint8 sellerScore,
        uint8 debtorScore,
        uint32 modelVersion,
        bytes32 root,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                attestation.SCORE_TYPEHASH(), agentId_, sellerScore, debtorScore, modelVersion, root, nonce, deadline
            )
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("BUAttestation")),
                keccak256(bytes("1")),
                block.chainid,
                address(attestation)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _sign(bytes32 digest, uint256 key) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_attestScore_happyPath_writesReputation() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _scoreDigest(agentId, 74, 87, 1, bytes32("root"), 0, deadline);

        vm.prank(relayer); // relaying is permissionless — validity comes from the HSM sig
        attestation.attestScore(agentId, 74, 87, 1, bytes32("root"), 0, deadline, _sign(digest, hsmKey));

        IBUFIReputationRegistry.ScoreSnapshot memory s = reputation.scoreOf(agentId);
        assertEq(s.sellerScore, 74);
        assertEq(s.debtorScore, 87);
        assertEq(attestation.nonces(agentId), 1);
    }

    function test_attestScore_replayRejected() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _scoreDigest(agentId, 74, 87, 1, bytes32("root"), 0, deadline);
        bytes memory sig = _sign(digest, hsmKey);

        attestation.attestScore(agentId, 74, 87, 1, bytes32("root"), 0, deadline, sig);
        vm.expectRevert(abi.encodeWithSelector(BUAttestation.BadNonce.selector, 1, 0));
        attestation.attestScore(agentId, 74, 87, 1, bytes32("root"), 0, deadline, sig);
    }

    function test_attestScore_wrongSignerRejected() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _scoreDigest(agentId, 74, 87, 1, bytes32("root"), 0, deadline);
        vm.expectRevert(BUAttestation.BadSignature.selector);
        attestation.attestScore(agentId, 74, 87, 1, bytes32("root"), 0, deadline, _sign(digest, 0xBAD));
    }

    function test_attestScore_tamperedPayloadRejected() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _scoreDigest(agentId, 74, 87, 1, bytes32("root"), 0, deadline);
        bytes memory sig = _sign(digest, hsmKey);
        // signed 74/87, relayer submits 99/99 → digest mismatch → BadSignature
        vm.expectRevert(BUAttestation.BadSignature.selector);
        attestation.attestScore(agentId, 99, 99, 1, bytes32("root"), 0, deadline, sig);
    }

    function test_attestScore_expiredRejected() public {
        uint256 deadline = block.timestamp + 1;
        bytes32 digest = _scoreDigest(agentId, 74, 87, 1, bytes32("root"), 0, deadline);
        bytes memory sig = _sign(digest, hsmKey);
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(BUAttestation.Expired.selector, deadline));
        attestation.attestScore(agentId, 74, 87, 1, bytes32("root"), 0, deadline, sig);
    }

    function test_attestKyb_flipsIdentityFlag() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(abi.encode(attestation.KYB_TYPEHASH(), agentId, true, uint256(0), deadline));
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("BUAttestation")),
                keccak256(bytes("1")),
                block.chainid,
                address(attestation)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        attestation.attestKyb(agentId, true, 0, deadline, _sign(digest, hsmKey));
        assertTrue(identity.kybApproved(agentId));
    }

    function test_setSigner_rotation() public {
        uint256 newKey = 0xB0B;
        vm.prank(admin);
        attestation.setSigner(vm.addr(newKey));

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _scoreDigest(agentId, 50, 50, 2, bytes32(0), 0, deadline);
        // old key no longer valid
        vm.expectRevert(BUAttestation.BadSignature.selector);
        attestation.attestScore(agentId, 50, 50, 2, bytes32(0), 0, deadline, _sign(digest, hsmKey));
        // new key works
        attestation.attestScore(agentId, 50, 50, 2, bytes32(0), 0, deadline, _sign(digest, newKey));
        assertEq(reputation.scoreOf(agentId).modelVersion, 2);
    }

    function test_donTeamKybCredential_happyPathAndExpiry() public {
        address forwarder = makeAddr("don-forwarder");
        bytes32 workflowId = keccak256("workflow-kyb-credential");
        uint64 chainSelector = 3_034_092_155_422_581_607;
        vm.prank(admin);
        attestation.setDonConfig(forwarder, workflowId, chainSelector);

        bytes32 teamKey = keccak256("team-kyb");
        uint64 validUntil = uint64(block.timestamp + 1 days);
        bytes32 operationId = keccak256("operation-1");
        bytes memory report = abi.encode(
            attestation.TEAM_KYB_KIND(),
            uint256(teamKey),
            true,
            validUntil,
            uint64(1),
            operationId,
            workflowId,
            chainSelector,
            uint64(block.timestamp + 1 hours)
        );

        vm.prank(forwarder);
        attestation.onReport(bytes(""), report);
        assertTrue(attestation.teamKybApproved(teamKey));
        (bool approved, , uint64 storedValidUntil, uint64 version, bytes32 storedOp) = attestation.teamKybState(teamKey);
        assertTrue(approved);
        assertEq(storedValidUntil, validUntil);
        assertEq(version, 1);
        assertEq(storedOp, operationId);

        vm.warp(validUntil + 1);
        assertFalse(attestation.teamKybApproved(teamKey));
    }

    function test_donTeamKybRevocationAndReplayProtection() public {
        address forwarder = makeAddr("don-forwarder");
        bytes32 workflowId = keccak256("workflow-kyb-credential");
        uint64 chainSelector = 3_034_092_155_422_581_607;
        vm.prank(admin);
        attestation.setDonConfig(forwarder, workflowId, chainSelector);

        bytes32 teamKey = keccak256("team-kyb");
        bytes32 operationId = keccak256("operation-revoke");
        bytes memory report = abi.encode(
            attestation.TEAM_KYB_KIND(),
            uint256(teamKey),
            false,
            uint64(0),
            uint64(1),
            operationId,
            workflowId,
            chainSelector,
            uint64(block.timestamp + 1 hours)
        );

        vm.prank(forwarder);
        attestation.onReport(bytes(""), report);
        assertFalse(attestation.teamKybApproved(teamKey));

        vm.expectRevert(abi.encodeWithSelector(BUAttestation.DonReplay.selector, operationId));
        vm.prank(forwarder);
        attestation.onReport(bytes(""), report);

        bytes memory stale = abi.encode(
            attestation.TEAM_KYB_KIND(),
            uint256(teamKey),
            true,
            uint64(block.timestamp + 1 days),
            uint64(1),
            keccak256("operation-stale"),
            workflowId,
            chainSelector,
            uint64(block.timestamp + 1 hours)
        );
        vm.expectRevert(abi.encodeWithSelector(BUAttestation.StaleTeamKybVersion.selector, uint64(1), uint64(1)));
        vm.prank(forwarder);
        attestation.onReport(bytes(""), stale);
    }

    function test_donTeamKybRejectsWrongForwarderKindAndExpiry() public {
        address forwarder = makeAddr("don-forwarder");
        bytes32 workflowId = keccak256("workflow-kyb-credential");
        uint64 chainSelector = 3_034_092_155_422_581_607;
        vm.prank(admin);
        attestation.setDonConfig(forwarder, workflowId, chainSelector);

        bytes32 teamKey = keccak256("team-kyb");
        bytes memory report = abi.encode(
            uint8(2),
            uint256(teamKey),
            true,
            uint64(block.timestamp + 1 days),
            uint64(1),
            keccak256("operation-kind"),
            workflowId,
            chainSelector,
            uint64(block.timestamp + 1 hours)
        );

        vm.expectRevert(BUAttestation.NotDonForwarder.selector);
        attestation.onReport(bytes(""), report);

        vm.expectRevert(BUAttestation.DonMalformedReport.selector);
        vm.prank(forwarder);
        attestation.onReport(bytes(""), report);

        report = abi.encode(
            attestation.TEAM_KYB_KIND(),
            uint256(teamKey),
            true,
            uint64(block.timestamp),
            uint64(1),
            keccak256("operation-expired"),
            workflowId,
            chainSelector,
            uint64(block.timestamp + 1 hours)
        );
        vm.expectRevert(BUAttestation.DonInvalidExpiry.selector);
        vm.prank(forwarder);
        attestation.onReport(bytes(""), report);
    }

    function test_donScoreReportWritesReputationWithoutHsm() public {
        address forwarder = makeAddr("don-forwarder");
        bytes32 workflowId = keccak256("workflow-score-attest");
        uint64 chainSelector = 3_034_092_155_422_581_607;
        vm.startPrank(admin);
        attestation.setDonConfig(forwarder, workflowId, chainSelector);
        vm.stopPrank();

        bytes32 operationId = keccak256("score-operation");
        bytes memory inner = abi.encode(
            agentId,
            uint8(74),
            uint8(87),
            uint32(2),
            bytes32("feature-root"),
            operationId,
            workflowId,
            chainSelector,
            uint64(block.timestamp + 1 hours)
        );
        bytes memory report = abi.encode(attestation.DON_SCORE_KIND(), inner);

        vm.prank(forwarder);
        attestation.onReport(bytes(""), report);

        IBUFIReputationRegistry.ScoreSnapshot memory snapshot = reputation.scoreOf(agentId);
        assertEq(snapshot.sellerScore, 74);
        assertEq(snapshot.debtorScore, 87);
        assertEq(snapshot.modelVersion, 2);
        vm.expectRevert(abi.encodeWithSelector(BUAttestation.DonReplay.selector, operationId));
        vm.prank(forwarder);
        attestation.onReport(bytes(""), report);
    }
}
