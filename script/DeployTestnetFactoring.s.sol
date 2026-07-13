// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Deploy} from "./Deploy.s.sol";
import {BUFIIdentityRegistry} from "../src/identity/BUFIIdentityRegistry.sol";
import {BUFIReputationRegistry} from "../src/identity/BUFIReputationRegistry.sol";
import {BUAttestation} from "../src/identity/BUAttestation.sol";
import {KybWorkspacePolicy} from "../src/identity/KybWorkspacePolicy.sol";
import {KybAttestationExtractor, IKybReportReceiver} from "../src/identity/KybAttestationExtractor.sol";
import {IKybCredentialReader} from "../src/interfaces/IKybCredentialReader.sol";
import {IBUFIIdentityRegistry} from "../src/interfaces/IBUFIIdentityRegistry.sol";
import {IBUFIReputationRegistry} from "../src/interfaces/IBUFIReputationRegistry.sol";
import {IInvoiceShelf} from "../src/interfaces/IInvoiceShelf.sol";
import {IAuthorityInvoiceVerifier} from "../src/interfaces/IAuthorityInvoiceVerifier.sol";
import {WorkspaceTierRegistry} from "../src/credit/WorkspaceTierRegistry.sol";
import {InvoiceShelf} from "../src/invoice/InvoiceShelf.sol";
import {BUFIOracle} from "../src/invoice/BUFIOracle.sol";
import {WorkspaceOperatingReserve} from "../src/rails/WorkspaceOperatingReserve.sol";
import {ReceivableEscrow} from "../src/rails/ReceivableEscrow.sol";
import {InvoiceMemoRouter} from "../src/rails/InvoiceMemoRouter.sol";
import {RecibuMemoRouter} from "../src/rails/RecibuMemoRouter.sol";
import {InvoiceSettlement} from "../src/rails/InvoiceSettlement.sol";
import {
    FactoringSettlementExtractor,
    IInvoiceShelfTarget,
    IInvoiceSettlementTarget
} from "../src/rails/FactoringSettlementExtractor.sol";
import {ReceivableCommitment} from "../src/libraries/ReceivableCommitment.sol";
import {StrictAuthorityInvoiceVerifier} from "../test/utils/StrictAuthorityInvoiceVerifier.sol";

/// @title DeployTestnetFactoring — TESTNET-ONLY full-stack fx-Recibu factoring deployment.
/// @notice Production `Deploy.run()` stays disabled. This script pins the TESTNET authority
///         verifier (StrictAuthorityInvoiceVerifier) + canonical origination domain per chain,
///         aligned with the fx-telaraña hub topology:
///           • Avalanche Fuji (43113)  — money-market hub
///           • Arc testnet     (5042002) — trading hub
///
/// admin == boot == deployer(keeper): the keeper keeps DEFAULT_ADMIN on every contract and
/// receives the operational roles via `_handoff`. Placeholders (all rotatable):
///   • forwarder             = keeper (CRE KeystoneForwarder unknown until Early Access)
///   • extractor workflow id = non-zero placeholder (setExpectedWorkflowId owner setter)
///   • BUAttestation signer  = keeper (rotatable via SIGNER_ADMIN_ROLE)
contract DeployTestnetFactoring is Script, Deploy {
    uint256 internal constant FUJI = 43_113;
    uint256 internal constant ARC = 5_042_002;

    // CCIP/CRE chain selectors.
    uint64 internal constant FUJI_CHAIN_SELECTOR = 14_767_482_510_784_806_043;
    uint64 internal constant ARC_CHAIN_SELECTOR = 5_040_923_346_571_241_210;

    // Circle USDC (both 6-dec, native ERC-3009 + ERC-2612 verified on-chain).
    address internal constant FUJI_USDC = 0x5425890298aed601595a70AB815c96711a31Bc65;
    address internal constant ARC_USDC = 0x3600000000000000000000000000000000000000;

    // Circle DCW gasless-relayer SCA (deterministic across EVM chains; LIVE on AVAX-FUJI,
    // resolved via Circle API from wallet db087acc-…-9cadf5196cc8). Arc has no Circle relayer
    // wallet (5042002 absent from GASLESS_RELAYER_CIRCLE_WALLET_IDS) → keeper is interim relayer.
    address internal constant RELAYER_SCA = 0x46821B8b74CbC0a48A5c6c7BfFe93f392E907103;

    bytes32 internal constant PLACEHOLDER_WORKFLOW_ID = keccak256("fx-recibu-testnet-factoring-placeholder-v1");
    uint8 internal constant USDC_CAPS = 3; // CAP_3009 | CAP_PERMIT

    function deploy() external {
        address deployer = msg.sender;
        (address usdcAddr, uint64 chainSelector, bytes32 configId, address relayer) = _chainConfig();
        IERC20 usdc = IERC20(usdcAddr);

        vm.startBroadcast();

        Deployment memory d;

        // ── identity + credentials ────────────────────────────────────────
        d.identity = new BUFIIdentityRegistry(deployer);
        d.reputation = new BUFIReputationRegistry(deployer, IBUFIIdentityRegistry(address(d.identity)));
        d.attestation = new BUAttestation(
            deployer,
            deployer, // HSM signer placeholder — rotatable via SIGNER_ADMIN_ROLE
            IBUFIIdentityRegistry(address(d.identity)),
            IBUFIReputationRegistry(address(d.reputation))
        );
        d.kybPolicy = new KybWorkspacePolicy(IKybCredentialReader(address(d.attestation)));
        d.tiers = new WorkspaceTierRegistry(
            IBUFIIdentityRegistry(address(d.identity)), IBUFIReputationRegistry(address(d.reputation))
        );

        // ── verifier-first shelf construction (mutual bind via CREATE prediction) ──
        bytes32 verifierCodehash = keccak256(type(StrictAuthorityInvoiceVerifier).runtimeCode);
        uint64 nonce = vm.getNonce(deployer);
        address predictedShelf = vm.computeCreateAddress(deployer, nonce + 1);
        StrictAuthorityInvoiceVerifier verifier =
            new StrictAuthorityInvoiceVerifier(ReceivableCommitment.VERSION, configId, block.chainid, predictedShelf);
        d.shelf = new InvoiceShelf(
            usdc,
            IBUFIIdentityRegistry(address(d.identity)),
            IBUFIReputationRegistry(address(d.reputation)),
            d.tiers,
            IAuthorityInvoiceVerifier(address(verifier)),
            ReceivableCommitment.VERSION,
            configId,
            block.chainid,
            verifierCodehash,
            deployer
        );
        require(address(d.shelf) == predictedShelf, "shelf CREATE prediction mismatch");

        // ── tranche NAV oracles (A=senior, B=mezz, C=junior) ──────────────
        d.oracleA = new BUFIOracle(d.shelf, 0, deployer);
        d.oracleB = new BUFIOracle(d.shelf, 1, deployer);
        d.oracleC = new BUFIOracle(d.shelf, 2, deployer);

        // ── rails ─────────────────────────────────────────────────────────
        d.reserve = new WorkspaceOperatingReserve(usdc, deployer);
        d.escrow = new ReceivableEscrow(usdc, deployer);
        d.shelf.setEscrow(address(d.escrow)); // must precede memo router / settlement / extractor
        d.router = new InvoiceMemoRouter(usdc, IInvoiceShelf(address(d.shelf)), d.escrow);
        d.memoRouter = new RecibuMemoRouter(IInvoiceShelf(address(d.shelf)), deployer);
        d.memoRouter.setToken(usdcAddr, true, USDC_CAPS, d.escrow);
        d.settlement = new InvoiceSettlement(usdc, IInvoiceShelf(address(d.shelf)), d.escrow, deployer);
        d.extractor = new FactoringSettlementExtractor(
            deployer, // owner
            deployer, // forwarder placeholder — setForwarder when Early Access grants real address
            PLACEHOLDER_WORKFLOW_ID,
            chainSelector,
            IInvoiceShelfTarget(address(d.shelf)),
            IInvoiceSettlementTarget(address(d.settlement))
        );

        // ── KYB attestation CRE receiver (forwards signed reports to BUAttestation) ──
        KybAttestationExtractor kybExtractor = new KybAttestationExtractor(
            deployer,
            deployer, // forwarder placeholder — setForwarder when Early Access grants real address
            chainSelector,
            IKybReportReceiver(address(d.attestation))
        );

        // ── role wiring + admin handoff (deployer stays admin: admin == boot) ──
        _wireRoles(d);
        _handoff(d, deployer, deployer);

        // ── grant the Circle gasless-relayer SCA the ERC-3009 memo ingress role ──
        // Arc has no dedicated Circle relayer wallet; the keeper (already MEMO_RELAYER via
        // _handoff) is the interim relayer there, so `relayer` is zero and this is skipped.
        if (relayer != address(0) && relayer != deployer) {
            d.memoRouter.grantRole(d.memoRouter.MEMO_RELAYER_ROLE(), relayer);
        }

        vm.stopBroadcast();

        _log(d, verifier, kybExtractor, relayer);
    }

    function _chainConfig()
        internal
        view
        returns (address usdc, uint64 selector, bytes32 configId, address relayer)
    {
        if (block.chainid == FUJI) {
            return (FUJI_USDC, FUJI_CHAIN_SELECTOR, keccak256("BUFI_FUJI_TESTNET_AUTHORITY_V1"), RELAYER_SCA);
        }
        if (block.chainid == ARC) {
            // Arc: no Circle relayer wallet -> keeper interim (relayer == 0 signals skip).
            return (ARC_USDC, ARC_CHAIN_SELECTOR, keccak256("BUFI_ARC_TESTNET_AUTHORITY_V1"), address(0));
        }
        revert("unsupported chain: expected 43113 (fuji) or 5042002 (arc)");
    }

    function _log(
        Deployment memory d,
        StrictAuthorityInvoiceVerifier verifier,
        KybAttestationExtractor kybExtractor,
        address relayer
    ) internal view {
        console.log("chainId", block.chainid);
        console.log("deployer", msg.sender);
        console.log("relayerGranted", relayer == address(0) ? msg.sender : relayer);
        console.log("BUFIIdentityRegistry", address(d.identity));
        console.log("BUFIReputationRegistry", address(d.reputation));
        console.log("BUAttestation", address(d.attestation));
        console.log("KybWorkspacePolicy", address(d.kybPolicy));
        console.log("KybAttestationExtractor", address(kybExtractor));
        console.log("WorkspaceTierRegistry", address(d.tiers));
        console.log("StrictAuthorityInvoiceVerifier", address(verifier));
        console.log("InvoiceShelf", address(d.shelf));
        console.log("BINV_TOKEN", address(d.shelf.BINV_TOKEN()));
        console.log("BUFIOracleSenior", address(d.oracleA));
        console.log("BUFIOracleMezz", address(d.oracleB));
        console.log("BUFIOracleJunior", address(d.oracleC));
        console.log("WorkspaceOperatingReserve", address(d.reserve));
        console.log("ReceivableEscrow", address(d.escrow));
        console.log("InvoiceMemoRouter", address(d.router));
        console.log("RecibuMemoRouter", address(d.memoRouter));
        console.log("InvoiceSettlement", address(d.settlement));
        console.log("FactoringSettlementExtractor", address(d.extractor));
        console.logBytes32(d.shelf.AUTHORITY_VERIFIER_CONFIG_ID());
    }
}
