// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {BUFIIdentityRegistry} from "../src/identity/BUFIIdentityRegistry.sol";
import {BUFIReputationRegistry} from "../src/identity/BUFIReputationRegistry.sol";
import {BUAttestation} from "../src/identity/BUAttestation.sol";
import {KybWorkspacePolicy} from "../src/identity/KybWorkspacePolicy.sol";
import {IKybCredentialReader} from "../src/interfaces/IKybCredentialReader.sol";
import {WorkspaceTierRegistry} from "../src/credit/WorkspaceTierRegistry.sol";
import {InvoiceShelf} from "../src/invoice/InvoiceShelf.sol";
import {BUFIOracle} from "../src/invoice/BUFIOracle.sol";
import {WorkspaceOperatingReserve} from "../src/rails/WorkspaceOperatingReserve.sol";
import {ReceivableEscrow} from "../src/rails/ReceivableEscrow.sol";
import {InvoiceMemoRouter} from "../src/rails/InvoiceMemoRouter.sol";
import {InvoiceSettlement} from "../src/rails/InvoiceSettlement.sol";
import {IInvoiceShelf} from "../src/interfaces/IInvoiceShelf.sol";
import {IBUFIIdentityRegistry} from "../src/interfaces/IBUFIIdentityRegistry.sol";
import {IBUFIReputationRegistry} from "../src/interfaces/IBUFIReputationRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title Deploy — full fx-Recibú stack + role wiring (M8)
/// @notice The single source of truth for how the contracts connect. Reused by the
///         Deploy.t.sol integration test to prove the wired system settles an invoice
///         end-to-end. Env: DEPLOYER_PRIVATE_KEY, USDC, ADMIN, HSM_SIGNER, ARC_MEMO
///         (verified constants live in the fx-Recibú GATEMAN_AUDIT §6).
///
///  Arc constants (GATEMAN_AUDIT §6, use these — not memory):
///    USDC                0x3600000000000000000000000000000000000000
///    Arc Memo predeploy  0x5294E9927c3306DcBaDb03fe70b92e01cCede505
///    canonical MorphoBlue 0x65f435eB4FF05f1481618694bC1ff7Ee4680c0A4
///    Morpho Vault V2 factory 0x6b7F638B64539F83810A1f6ea81C703b561C3Be6 (BUFICreditVault, M6)
///    FxReserveYieldRouter (USYC, entitled) 0x623d0DAfA24B59809a9fBfa3a60148F69aaB8b06
contract Deploy is Script {
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
        InvoiceSettlement settlement;
    }

    function run() external returns (Deployment memory d) {
        address usdc = vm.envAddress("USDC");
        address admin = vm.envAddress("ADMIN");
        address hsmSigner = vm.envAddress("HSM_SIGNER");
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(pk);
        d = deploy(IERC20(usdc), admin, hsmSigner, vm.addr(pk));
        vm.stopBroadcast();
        _log(d);
    }

    /// @notice pure wiring, broadcast-agnostic so tests can call it directly.
    /// @dev bootstraps every AccessControl contract with THIS contract as admin so it can
    ///      wire inter-contract roles, then hands DEFAULT_ADMIN + operational roles to the
    ///      real `admin` and renounces its own — the deploy contract holds no power after.
    function deploy(IERC20 usdc, address admin, address hsmSigner) public returns (Deployment memory d) {
        return deploy(usdc, admin, hsmSigner, address(this)); // tests: the script contract boots
    }

    function deploy(IERC20 usdc, address admin, address hsmSigner, address boot)
        public
        returns (Deployment memory d)
    {
        // ── identity + reputation + attestation (M1) ──
        d.identity = new BUFIIdentityRegistry(boot);
        d.reputation = new BUFIReputationRegistry(boot, IBUFIIdentityRegistry(address(d.identity)));
        d.attestation = new BUAttestation(
            boot, hsmSigner, IBUFIIdentityRegistry(address(d.identity)), IBUFIReputationRegistry(address(d.reputation))
        );
        // ACE PolicyEngine registration is owner/EA-gated; deploy the policy
        // now so the same deterministic stack can attach it at promotion.
        d.kybPolicy = new KybWorkspacePolicy(IKybCredentialReader(address(d.attestation)));
        // ── credit (M2) ──
        d.tiers = new WorkspaceTierRegistry(
            IBUFIIdentityRegistry(address(d.identity)), IBUFIReputationRegistry(address(d.reputation))
        );
        // ── invoice core (M3) ──
        d.shelf = new InvoiceShelf(
            usdc, IBUFIIdentityRegistry(address(d.identity)), IBUFIReputationRegistry(address(d.reputation)), d.tiers, boot
        );
        d.oracleA = new BUFIOracle(d.shelf, 0, boot);
        d.oracleB = new BUFIOracle(d.shelf, 1, boot);
        d.oracleC = new BUFIOracle(d.shelf, 2, boot);
        // ── defaults (M4) ──
        d.reserve = new WorkspaceOperatingReserve(usdc, boot);
        // ── rails (M5) ──
        d.escrow = new ReceivableEscrow(usdc, boot);
        d.router = new InvoiceMemoRouter(usdc, IInvoiceShelf(address(d.shelf)), d.escrow);
        d.settlement = new InvoiceSettlement(usdc, IInvoiceShelf(address(d.shelf)), d.escrow, boot);

        _wireRoles(d);
        _handoff(d, admin, boot);
    }

    /// @dev inter-contract role grants (deploy contract is admin here).
    function _wireRoles(Deployment memory d) internal {
        d.reputation.grantRole(d.reputation.ATTESTOR_ROLE(), address(d.attestation));
        d.identity.grantRole(d.identity.ISSUER_ROLE(), address(d.attestation));
        d.reputation.grantRole(d.reputation.SETTLEMENT_ROLE(), address(d.shelf));
        d.reputation.grantRole(d.reputation.OPS_ROLE(), address(d.shelf)); // resolveDefault
        d.shelf.grantRole(d.shelf.SETTLEMENT_ROLE(), address(d.settlement));
        d.escrow.grantRole(d.escrow.ROUTER_ROLE(), address(d.router));
        d.escrow.grantRole(d.escrow.SETTLEMENT_ROLE(), address(d.settlement));
        d.shelf.setReserve(d.reserve);
        d.shelf.setEscrow(address(d.escrow));
        d.reserve.grantRole(d.reserve.SHELF_ROLE(), address(d.shelf));
    }

    /// @dev grant the real admin DEFAULT_ADMIN + operational roles, then renounce boot power.
    ///      In prod the admin is a multisig; it later splits SERVICER/OPS/KEEPER to service
    ///      accounts + ops multisig (SPEC §8.2/§8.3). ISSUER also stays admin-held for the
    ///      KYB service; ATTESTOR is via BUAttestation only.
    function _handoff(Deployment memory d, address admin, address boot) internal {
        // operational roles the admin needs
        d.identity.grantRole(d.identity.ISSUER_ROLE(), admin);
        d.attestation.grantRole(d.attestation.SIGNER_ADMIN_ROLE(), admin);
        d.shelf.grantRole(d.shelf.SERVICER_ROLE(), admin);
        d.shelf.grantRole(d.shelf.OPS_ROLE(), admin);
        d.escrow.grantRole(d.escrow.ARBITER_ROLE(), admin);
        d.settlement.grantRole(d.settlement.KEEPER_ROLE(), admin);
        d.oracleA.grantRole(d.oracleA.OPS_ROLE(), admin);
        d.oracleB.grantRole(d.oracleB.OPS_ROLE(), admin);
        d.oracleC.grantRole(d.oracleC.OPS_ROLE(), admin);

        // transfer DEFAULT_ADMIN to the real admin, then renounce boot's
        _rotateAdmin(d.identity, admin, boot);
        _rotateAdmin(d.reputation, admin, boot);
        _rotateAdmin(d.attestation, admin, boot);
        _rotateAdmin(d.shelf, admin, boot);
        _rotateAdmin(d.reserve, admin, boot);
        _rotateAdmin(d.escrow, admin, boot);
        _rotateAdmin(d.settlement, admin, boot);
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

    function _log(Deployment memory d) internal pure {
        console2.log("identity     ", address(d.identity));
        console2.log("reputation   ", address(d.reputation));
        console2.log("attestation  ", address(d.attestation));
        console2.log("kyb policy   ", address(d.kybPolicy));
        console2.log("tiers        ", address(d.tiers));
        console2.log("shelf        ", address(d.shelf));
        console2.log("oracleC (jr) ", address(d.oracleC));
        console2.log("reserve      ", address(d.reserve));
        console2.log("escrow       ", address(d.escrow));
        console2.log("router       ", address(d.router));
        console2.log("settlement   ", address(d.settlement));
    }
}
