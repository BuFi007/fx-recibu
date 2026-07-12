// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {BUFIIdentityRegistry} from "../src/identity/BUFIIdentityRegistry.sol";
import {BUFIReputationRegistry} from "../src/identity/BUFIReputationRegistry.sol";
import {BUAttestation} from "../src/identity/BUAttestation.sol";
import {KybWorkspacePolicy} from "../src/identity/KybWorkspacePolicy.sol";
import {WorkspaceTierRegistry} from "../src/credit/WorkspaceTierRegistry.sol";
import {InvoiceShelf} from "../src/invoice/InvoiceShelf.sol";
import {BUFIOracle} from "../src/invoice/BUFIOracle.sol";
import {WorkspaceOperatingReserve} from "../src/rails/WorkspaceOperatingReserve.sol";
import {ReceivableEscrow} from "../src/rails/ReceivableEscrow.sol";
import {InvoiceMemoRouter} from "../src/rails/InvoiceMemoRouter.sol";
import {RecibuMemoRouter} from "../src/rails/RecibuMemoRouter.sol";
import {InvoiceSettlement} from "../src/rails/InvoiceSettlement.sol";
import {FactoringSettlementExtractor} from "../src/rails/FactoringSettlementExtractor.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title Deploy — production-disabled local-conformance surface
/// @notice The production entrypoint is intentionally unavailable until an
///         accepted authority artifact and owner-reviewed deployment manifest
///         pin the verifier and canonical origination domain. Tests define the
///         verifier-first construction harness under test/ only and reuse the
///         internal role-wiring helpers below.
contract Deploy {
    struct Deployment {
        BUFIIdentityRegistry identity;
        BUFIReputationRegistry reputation;
        BUAttestation attestation;
        KybWorkspacePolicy kybPolicy;
        WorkspaceTierRegistry tiers;
        InvoiceShelf shelf;
        BUFIOracle oracleA;
        BUFIOracle oracleB;
        BUFIOracle oracleC;
        WorkspaceOperatingReserve reserve;
        ReceivableEscrow escrow;
        InvoiceMemoRouter router;
        RecibuMemoRouter memoRouter;
        InvoiceSettlement settlement;
        FactoringSettlementExtractor extractor;
    }

    error ProductionActivationDisabled();
    error MissingExtractor();
    error ExtractorOwnerMismatch(address received, address expected);

    function run() external pure returns (Deployment memory) {
        revert ProductionActivationDisabled();
    }

    /// @dev inter-contract role grants (deploy contract is admin here).
    function _wireRoles(Deployment memory d) internal {
        if (address(d.extractor) == address(0)) revert MissingExtractor();
        d.reputation.grantRole(d.reputation.ATTESTOR_ROLE(), address(d.attestation));
        d.identity.grantRole(d.identity.ISSUER_ROLE(), address(d.attestation));
        d.reputation.grantRole(d.reputation.SETTLEMENT_ROLE(), address(d.shelf));
        d.reputation.grantRole(d.reputation.OPS_ROLE(), address(d.shelf)); // resolveDefault
        d.shelf.grantRole(d.shelf.SETTLEMENT_ROLE(), address(d.settlement));
        d.shelf.grantRole(d.shelf.SERVICER_ROLE(), address(d.extractor));
        d.escrow.grantRole(d.escrow.ROUTER_ROLE(), address(d.router));
        d.escrow.grantRole(d.escrow.ROUTER_ROLE(), address(d.memoRouter));
        d.escrow.grantRole(d.escrow.SETTLEMENT_ROLE(), address(d.settlement));
        d.settlement.grantRole(d.settlement.KEEPER_ROLE(), address(d.extractor));
        d.shelf.setReserve(d.reserve);
        if (address(d.shelf.escrow()) == address(0)) d.shelf.setEscrow(address(d.escrow));
        d.reserve.grantRole(d.reserve.SHELF_ROLE(), address(d.shelf));
    }

    /// @dev grant the real admin DEFAULT_ADMIN + operational roles, then renounce boot power.
    ///      In prod the admin is a multisig; it later splits SERVICER/OPS/KEEPER to service
    ///      accounts + ops multisig (SPEC §8.2/§8.3). ISSUER also stays admin-held for the
    ///      KYB service; ATTESTOR is via BUAttestation only.
    function _handoff(Deployment memory d, address admin, address boot) internal {
        address extractorOwner = d.extractor.owner();
        if (extractorOwner != admin) revert ExtractorOwnerMismatch(extractorOwner, admin);
        // operational roles the admin needs
        d.identity.grantRole(d.identity.ISSUER_ROLE(), admin);
        d.attestation.grantRole(d.attestation.SIGNER_ADMIN_ROLE(), admin);
        d.shelf.grantRole(d.shelf.SERVICER_ROLE(), admin);
        d.shelf.grantRole(d.shelf.OPS_ROLE(), admin);
        d.escrow.grantRole(d.escrow.ARBITER_ROLE(), admin);
        d.settlement.grantRole(d.settlement.KEEPER_ROLE(), admin);
        // Admin starts as the trusted DCW/CRE ERC-3009 memo ingress and can split
        // this role to a dedicated relayer before production activation.
        d.memoRouter.grantRole(d.memoRouter.MEMO_RELAYER_ROLE(), admin);
        d.oracleA.grantRole(d.oracleA.OPS_ROLE(), admin);
        d.oracleB.grantRole(d.oracleB.OPS_ROLE(), admin);
        d.oracleC.grantRole(d.oracleC.OPS_ROLE(), admin);

        // Constructors grant boot both DEFAULT_ADMIN and a small set of operational
        // roles. Remove the named capabilities before boot renounces admin authority.
        if (admin != boot) {
            d.attestation.revokeRole(d.attestation.SIGNER_ADMIN_ROLE(), boot);
            d.settlement.revokeRole(d.settlement.KEEPER_ROLE(), boot);
            d.oracleA.revokeRole(d.oracleA.OPS_ROLE(), boot);
            d.oracleB.revokeRole(d.oracleB.OPS_ROLE(), boot);
            d.oracleC.revokeRole(d.oracleC.OPS_ROLE(), boot);
        }

        // transfer DEFAULT_ADMIN to the real admin, then renounce boot's
        _rotateAdmin(d.identity, admin, boot);
        _rotateAdmin(d.reputation, admin, boot);
        _rotateAdmin(d.attestation, admin, boot);
        _rotateAdmin(d.shelf, admin, boot);
        _rotateAdmin(d.reserve, admin, boot);
        _rotateAdmin(d.escrow, admin, boot);
        _rotateAdmin(d.settlement, admin, boot);
        _rotateAdmin(d.memoRouter, admin, boot);
        _rotateAdmin(d.oracleA, admin, boot);
        _rotateAdmin(d.oracleB, admin, boot);
        _rotateAdmin(d.oracleC, admin, boot);
    }

    /// @dev grant DEFAULT_ADMIN to the real admin, renounce the boot contract's.
    function _rotateAdmin(IAccessControl ac, address admin, address boot) internal {
        bytes32 da = 0x00; // DEFAULT_ADMIN_ROLE
        ac.grantRole(da, admin);
        if (admin != boot) ac.renounceRole(da, boot);
    }
}
