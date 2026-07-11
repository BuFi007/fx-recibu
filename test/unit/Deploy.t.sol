// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {BINV} from "../../src/invoice/BINV.sol";
import {ReceivableCommitment} from "../../src/libraries/ReceivableCommitment.sol";
import {FactoringEvidenceV1} from "../../src/libraries/FactoringEvidenceV1.sol";
import {IInvoiceShelf} from "../../src/interfaces/IInvoiceShelf.sol";
import {IBUFIReputationRegistry} from "../../src/interfaces/IBUFIReputationRegistry.sol";

contract DeployUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

/// @notice M8 integration: deploy the full wired stack and drive an invoice from KYB →
///         score attestation (via HSM sig) → lock → repay through the rails → settle.
///         Proves the Deploy script's role wiring is correct and complete.
contract DeployIntegrationTest is Test {
    Deploy internal deployer;
    Deploy.Deployment internal d;
    DeployUSDC internal usdc;

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
        deployer = new Deploy();
        d = deployer.deploy(usdc, admin, hsm);
        assertEq(address(d.kybPolicy.CREDENTIALS()), address(d.attestation));
    }

    function _attestScore(uint256 agentId, uint8 s, uint8 dScore, uint256 nonce) internal {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(d.attestation.SCORE_TYPEHASH(), agentId, s, dScore, uint32(1), bytes32("root"), nonce, deadline)
        );
        bytes32 ds = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("BUAttestation")),
                keccak256(bytes("1")),
                block.chainid,
                address(d.attestation)
            )
        );
        (uint8 v, bytes32 r, bytes32 sg) = vm.sign(hsmKey, keccak256(abi.encodePacked("\x19\x01", ds, structHash)));
        d.attestation.attestScore(agentId, s, dScore, 1, bytes32("root"), nonce, deadline, abi.encodePacked(r, sg, v));
    }

    function _attestKyb(uint256 agentId, uint256 nonce) internal {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(abi.encode(d.attestation.KYB_TYPEHASH(), agentId, true, nonce, deadline));
        bytes32 ds = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("BUAttestation")),
                keccak256(bytes("1")),
                block.chainid,
                address(d.attestation)
            )
        );
        (uint8 v, bytes32 r, bytes32 sg) = vm.sign(hsmKey, keccak256(abi.encodePacked("\x19\x01", ds, structHash)));
        d.attestation.attestKyb(agentId, true, nonce, deadline, abi.encodePacked(r, sg, v));
    }

    function test_fullStack_kybToSettlement() public {
        // admin (holds ISSUER + SERVICER + KEEPER after deploy wiring) registers workspaces
        vm.startPrank(admin);
        seller = d.identity.registerWorkspace(keccak256("seller"), sellerOwner);
        debtor = d.identity.registerWorkspace(keccak256("debtor"), makeAddr("dOwner"));
        vm.stopPrank();

        // KYB + scores flow through the HSM-signed attestation path (nonces: kyb=0, score=1)
        _attestKyb(seller, 0);
        _attestScore(seller, 74, 74, 1);
        _attestKyb(debtor, 0);
        _attestScore(debtor, 74, 87, 1);
        assertTrue(d.identity.kybApproved(seller));
        assertTrue(d.tiers.eligible(seller));

        // LP funds the junior tranche
        address lp = makeAddr("lp");
        usdc.mint(lp, 1_000_000e6);
        vm.startPrank(lp);
        usdc.approve(address(d.shelf), type(uint256).max);
        d.shelf.depositTranche(2, 1_000_000e6);
        vm.stopPrank();

        // servicer (admin) locks the accepted invoice
        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        vm.prank(admin);
        uint256 inv = d.shelf
            .lockInvoice(
                seller,
                debtor,
                500e6,
                2,
                firstMaturity,
                30 days,
                _terms(keccak256("ARCA:deploy:invoice"), firstMaturity),
                _evidence(keccak256("ARCA:deploy:invoice")),
                _bundle()
            );
        assertEq(d.shelf.BINV_TOKEN().ownerOf(inv), sellerOwner);
        assertEq(usdc.balanceOf(sellerOwner), 425e6); // 85% advance

        // debtor repays through the Memo router → escrow → settlement → shelf
        usdc.mint(debtorPayer, 1_000_000e6);
        vm.startPrank(debtorPayer);
        usdc.approve(address(d.router), type(uint256).max);
        d.router.pay(inv, 0, 250e6);
        vm.stopPrank();
        assertEq(d.escrow.escrowedOf(inv), 250e6);

        vm.prank(admin); // KEEPER on settlement
        d.settlement.settle(inv);
        assertEq(d.reputation.paidOnTimeCumulative(seller), 1); // on-time booked
        assertTrue(d.tiers.hasPairHistory(seller, debtor));

        // second installment completes face → settle, holdback to seller, bINV burnt
        vm.warp(block.timestamp + 30 days);
        vm.startPrank(debtorPayer);
        d.router.pay(inv, 1, 250e6);
        vm.stopPrank();
        vm.prank(admin);
        d.settlement.settle(inv);

        assertEq(uint8(d.shelf.invoiceStatus(inv)), uint8(IInvoiceShelf.Status.Settled));
        assertEq(usdc.balanceOf(sellerOwner), 425e6 + 75e6); // advance + holdback
        // junior NAV back to par (no loss)
        assertEq(d.oracleC.price(), 1e24);
    }

    function _bundle() internal pure returns (BINV.DocBundle memory) {
        return BINV.DocBundle(bytes32("i"), bytes32("a"), bytes32("p"), bytes32("s"), bytes32("d"));
    }

    function _terms(bytes32 authorityId, uint64 firstMaturity)
        internal
        view
        returns (ReceivableCommitment.Terms memory)
    {
        return ReceivableCommitment.Terms({
            canonicalInvoiceCommitmentHash: authorityId,
            issuedAt: uint64(block.timestamp),
            dueAt: firstMaturity + 30 days
        });
    }

    function _evidence(bytes32 seed) internal pure returns (FactoringEvidenceV1 memory) {
        return FactoringEvidenceV1({
            featureRootHash: keccak256(abi.encode("FEATURE_ROOT", seed)),
            currentSnapshotHash: keccak256(abi.encode("CURRENT_SNAPSHOT", seed)),
            privateTermsHash: keccak256(abi.encode("PRIVATE_TERMS", seed))
        });
    }
}
