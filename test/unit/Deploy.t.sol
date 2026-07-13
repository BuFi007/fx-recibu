// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {BUFIIdentityRegistry} from "../../src/identity/BUFIIdentityRegistry.sol";
import {BUFIReputationRegistry} from "../../src/identity/BUFIReputationRegistry.sol";
import {BUAttestation} from "../../src/identity/BUAttestation.sol";
import {KybWorkspacePolicy} from "../../src/identity/KybWorkspacePolicy.sol";
import {IKybCredentialReader} from "../../src/interfaces/IKybCredentialReader.sol";
import {IBUFIIdentityRegistry} from "../../src/interfaces/IBUFIIdentityRegistry.sol";
import {IBUFIReputationRegistry} from "../../src/interfaces/IBUFIReputationRegistry.sol";
import {IInvoiceShelf} from "../../src/interfaces/IInvoiceShelf.sol";
import {WorkspaceTierRegistry} from "../../src/credit/WorkspaceTierRegistry.sol";
import {BUFIOracle} from "../../src/invoice/BUFIOracle.sol";
import {BINV} from "../../src/invoice/BINV.sol";
import {WorkspaceOperatingReserve} from "../../src/rails/WorkspaceOperatingReserve.sol";
import {ReceivableEscrow} from "../../src/rails/ReceivableEscrow.sol";
import {InvoiceMemoRouter} from "../../src/rails/InvoiceMemoRouter.sol";
import {RecibuMemoRouter} from "../../src/rails/RecibuMemoRouter.sol";
import {InvoiceSettlement} from "../../src/rails/InvoiceSettlement.sol";
import {
    FactoringSettlementExtractor,
    IInvoiceShelfTarget,
    IInvoiceSettlementTarget
} from "../../src/rails/FactoringSettlementExtractor.sol";
import {ReceivableCommitment} from "../../src/libraries/ReceivableCommitment.sol";
import {StrictAuthorityFixture, StrictAuthorityInvoiceVerifier} from "../utils/StrictAuthorityInvoiceVerifier.sol";

contract DeployUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Test-only exposure of source-internal wiring. It creates no production
///      deployment path and never imports a mock into script/ or src/.
contract DeployHarness is Deploy {
    function wireAndHandoff(Deployment memory deployment, address admin, address boot) external {
        _wireRoles(deployment);
        _handoff(deployment, admin, boot);
    }
}

/// @notice Local integration harness: strict verifier-first prediction, full
///         role wiring, and KYB-to-settlement lifecycle. Production run stays disabled.
contract DeployIntegrationTest is StrictAuthorityFixture {
    uint64 internal constant ARC_CHAIN_SELECTOR = 5_040_923_346_571_241_210;
    DeployHarness internal deployer;
    Deploy.Deployment internal d;
    DeployUSDC internal usdc;
    StrictAuthorityInvoiceVerifier internal authorityVerifier;

    address internal admin = makeAddr("admin");
    uint256 internal hsmKey = 0xA11CE;
    address internal hsm;

    address internal sellerOwner = makeAddr("sellerOwner");
    address internal debtorPayer = makeAddr("debtorPayer");
    uint256 internal seller;
    uint256 internal debtor;

    function setUp() public {
        hsm = vm.addr(hsmKey);
        usdc = new DeployUSDC();
        deployer = new DeployHarness();
        address boot = address(deployer);

        d.identity = new BUFIIdentityRegistry(boot);
        d.reputation = new BUFIReputationRegistry(boot, IBUFIIdentityRegistry(address(d.identity)));
        d.attestation = new BUAttestation(
            boot, hsm, IBUFIIdentityRegistry(address(d.identity)), IBUFIReputationRegistry(address(d.reputation))
        );
        d.kybPolicy = new KybWorkspacePolicy(IKybCredentialReader(address(d.attestation)));
        d.tiers = new WorkspaceTierRegistry(
            IBUFIIdentityRegistry(address(d.identity)), IBUFIReputationRegistry(address(d.reputation))
        );
        (d.shelf, authorityVerifier) = _deployStrictShelf(
            usdc,
            IBUFIIdentityRegistry(address(d.identity)),
            IBUFIReputationRegistry(address(d.reputation)),
            d.tiers,
            boot
        );
        d.oracleA = new BUFIOracle(d.shelf, 0, boot);
        d.oracleB = new BUFIOracle(d.shelf, 1, boot);
        d.oracleC = new BUFIOracle(d.shelf, 2, boot);
        d.reserve = new WorkspaceOperatingReserve(usdc, boot);
        d.escrow = new ReceivableEscrow(usdc, boot);
        vm.prank(boot);
        d.shelf.setEscrow(address(d.escrow));
        d.router = new InvoiceMemoRouter(usdc, IInvoiceShelf(address(d.shelf)), d.escrow);
        d.memoRouter = new RecibuMemoRouter(IInvoiceShelf(address(d.shelf)), boot);
        vm.prank(boot);
        d.memoRouter.setToken(address(usdc), true, 0, d.escrow);
        d.settlement = new InvoiceSettlement(usdc, IInvoiceShelf(address(d.shelf)), d.escrow, boot);
        d.extractor = new FactoringSettlementExtractor(
            admin,
            makeAddr("cre-forwarder"),
            bytes32(0),
            ARC_CHAIN_SELECTOR,
            IInvoiceShelfTarget(address(d.shelf)),
            IInvoiceSettlementTarget(address(d.settlement))
        );

        deployer.wireAndHandoff(d, admin, boot);
        assertEq(address(d.kybPolicy.CREDENTIALS()), address(d.attestation));
    }

    function test_runRevertsBeforeEnvironmentReadOrBroadcast() public {
        vm.expectRevert(Deploy.ProductionActivationDisabled.selector);
        deployer.run();
    }

    function test_testOnlyHarnessPredictsVerifierAndShelfAndWiresRoles() public view {
        assertEq(address(d.shelf.AUTHORITY_VERIFIER()), address(authorityVerifier));
        assertEq(d.shelf.AUTHORITY_VERIFIER_CODEHASH(), address(authorityVerifier).codehash);
        assertEq(d.shelf.AUTHORITY_VERIFIER_SCHEMA_VERSION(), ReceivableCommitment.VERSION);
        assertEq(d.shelf.AUTHORITY_VERIFIER_CONFIG_ID(), TEST_VERIFIER_CONFIG_ID);
        assertEq(authorityVerifier.approvedShelf(), address(d.shelf));
        assertTrue(d.shelf.hasRole(d.shelf.SERVICER_ROLE(), admin));
        assertTrue(d.settlement.hasRole(d.settlement.KEEPER_ROLE(), admin));
        assertTrue(d.memoRouter.hasRole(d.memoRouter.MEMO_RELAYER_ROLE(), admin));
        assertTrue(d.settlement.hasRole(d.settlement.KEEPER_ROLE(), address(d.extractor)));
        assertTrue(d.shelf.hasRole(d.shelf.SERVICER_ROLE(), address(d.extractor)));
        assertFalse(d.shelf.hasRole(d.shelf.SETTLEMENT_ROLE(), address(d.extractor)));
        assertEq(d.extractor.owner(), admin);
        address boot = address(deployer);
        assertFalse(d.attestation.hasRole(d.attestation.SIGNER_ADMIN_ROLE(), boot));
        assertFalse(d.settlement.hasRole(d.settlement.KEEPER_ROLE(), boot));
        assertFalse(d.oracleA.hasRole(d.oracleA.OPS_ROLE(), boot));
        assertFalse(d.oracleB.hasRole(d.oracleB.OPS_ROLE(), boot));
        assertFalse(d.oracleC.hasRole(d.oracleC.OPS_ROLE(), boot));
        assertFalse(d.memoRouter.hasRole(d.memoRouter.DEFAULT_ADMIN_ROLE(), address(deployer)));
        assertFalse(d.shelf.hasRole(d.shelf.DEFAULT_ADMIN_ROLE(), address(deployer)));
    }

    function _attestScore(uint256 agentId, uint8 sellerScore, uint8 debtorScore, uint256 nonce) internal {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                d.attestation.SCORE_TYPEHASH(),
                agentId,
                sellerScore,
                debtorScore,
                uint32(1),
                bytes32("root"),
                nonce,
                deadline
            )
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("BUAttestation")),
                keccak256(bytes("1")),
                block.chainid,
                address(d.attestation)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(hsmKey, keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash)));
        d.attestation
            .attestScore(
                agentId, sellerScore, debtorScore, 1, bytes32("root"), nonce, deadline, abi.encodePacked(r, s, v)
            );
    }

    function _attestKyb(uint256 agentId, uint256 nonce) internal {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(abi.encode(d.attestation.KYB_TYPEHASH(), agentId, true, nonce, deadline));
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("BUAttestation")),
                keccak256(bytes("1")),
                block.chainid,
                address(d.attestation)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(hsmKey, keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash)));
        d.attestation.attestKyb(agentId, true, nonce, deadline, abi.encodePacked(r, s, v));
    }

    function test_fullStack_kybToSettlement() public {
        vm.startPrank(admin);
        seller = d.identity.registerWorkspace(keccak256("seller"), sellerOwner);
        debtor = d.identity.registerWorkspace(keccak256("debtor"), debtorPayer);
        vm.stopPrank();

        _attestKyb(seller, 0);
        _attestScore(seller, 74, 74, 1);
        _attestKyb(debtor, 0);
        _attestScore(debtor, 74, 87, 1);
        assertTrue(d.identity.kybApproved(seller));
        assertTrue(d.tiers.eligible(seller));

        address lp = makeAddr("lp");
        usdc.mint(lp, 1_000_000e6);
        vm.startPrank(lp);
        usdc.approve(address(d.shelf), type(uint256).max);
        d.shelf.depositTranche(2, 1_000_000e6);
        vm.stopPrank();
        vm.prank(admin);
        d.oracleC.observe();

        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        ReceivableCommitment.FundingTerms memory terms =
            _newApprovedTerms(authorityVerifier, seller, debtor, address(usdc), 500e6, 2, firstMaturity, 30 days);
        vm.prank(admin);
        uint256 invoiceId = d.shelf.lockInvoice(seller, debtor, 500e6, 2, firstMaturity, 30 days, terms, _bundle());
        assertEq(d.shelf.BINV_TOKEN().ownerOf(invoiceId), sellerOwner);
        assertEq(usdc.balanceOf(sellerOwner), 425e6);

        vm.warp(firstMaturity);
        usdc.mint(debtorPayer, 1_000_000e6);
        vm.startPrank(debtorPayer);
        usdc.approve(address(d.router), type(uint256).max);
        d.router.pay(invoiceId, 0, 250e6);
        vm.stopPrank();
        assertEq(d.escrow.escrowedOf(invoiceId), 250e6);

        vm.prank(admin);
        d.settlement.settle(invoiceId);
        assertEq(d.reputation.paidOnTimeCumulative(seller), 1);
        assertFalse(d.tiers.hasPairHistory(seller, debtor));

        vm.warp(uint256(firstMaturity) + 30 days);
        vm.prank(debtorPayer);
        d.router.pay(invoiceId, 1, 250e6);
        vm.prank(admin);
        d.settlement.settle(invoiceId);

        assertEq(uint8(d.shelf.invoiceStatus(invoiceId)), uint8(IInvoiceShelf.Status.Settled));
        assertEq(d.reputation.paidOnTimeCumulative(seller), 2);
        assertTrue(d.tiers.hasPairHistory(seller, debtor));
        assertEq(usdc.balanceOf(sellerOwner), 500e6);
        assertEq(d.oracleC.price(), 1e24);
    }

    function _bundle() internal pure returns (BINV.DocBundle memory) {
        return BINV.DocBundle(bytes32("i"), bytes32("a"), bytes32("p"), bytes32("s"), bytes32("d"));
    }
}
