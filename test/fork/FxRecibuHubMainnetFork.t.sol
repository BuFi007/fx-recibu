// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {InvoiceShelf} from "../../src/invoice/InvoiceShelf.sol";
import {MultiTokenReceivableEscrow} from "../../src/rails/MultiTokenReceivableEscrow.sol";
import {RecibuMemoRouter} from "../../src/rails/RecibuMemoRouter.sol";
import {DeployFxRecibuHubMainnet} from "../../script/DeployFxRecibuHubMainnet.s.sol";
import {BUFIIdentityRegistry} from "../../src/identity/BUFIIdentityRegistry.sol";
import {BUFIReputationRegistry} from "../../src/identity/BUFIReputationRegistry.sol";
import {BINV} from "../../src/invoice/BINV.sol";
import {ReceivableCommitment} from "../../src/libraries/ReceivableCommitment.sol";
import {FactoringEvidenceV1} from "../../src/libraries/FactoringEvidenceV1.sol";

/// @notice Arc mainnet fork (skips when https://rpc.mainnet.arc.io / ARC_MAINNET_RPC_URL is down).
contract FxRecibuHubMainnetForkTest is Test {
    address internal constant SAFE = 0x47Dc7D18A6E3a79F696714E7D47456a49B430D09;
    address internal constant DEPLOYER = 0x09Ce8E2B3Fede2727dA4392Ea8Fe618305ba0474;
    address internal constant MIDNIGHT = 0x208786922BE56fDE2D1Fa60e6b9eC5D723e8d7b0;

    function _fork() internal returns (bool) {
        try vm.createSelectFork(vm.envOr("ARC_MAINNET_RPC_URL", string("https://rpc.mainnet.arc.io"))) {
            return true;
        } catch {
            return false;
        }
    }

    function test_fork_arcHub_deploy_safeOnly_and_batch() public {
        if (!_fork()) return vm.skip(true);
        assertEq(block.chainid, 5042);
        assertGt(SAFE.code.length, 0);
        assertGt(MIDNIGHT.code.length, 0, "Midnight on Arc");
        DeployFxRecibuHubMainnet s = new DeployFxRecibuHubMainnet();
        DeployFxRecibuHubMainnet.Hub memory h = s.deployAll(SAFE);
        DeployFxRecibuHubMainnet.Hub memory p = s.predictAll(SAFE);
        assertEq(h.router, p.router);
        assertEq(s.deployAll(SAFE).shelf, h.shelf); // idempotent

        address[4] memory admined = [h.identity, h.reputation, h.shelf, h.escrow];
        for (uint256 i; i < admined.length; ++i) {
            assertTrue(IAccessControl(admined[i]).hasRole(bytes32(0), SAFE));
            assertFalse(IAccessControl(admined[i]).hasRole(bytes32(0), DEPLOYER));
            assertFalse(IAccessControl(admined[i]).hasRole(bytes32(0), address(s)));
        }
        assertTrue(IAccessControl(h.router).hasRole(bytes32(0), SAFE));
        assertTrue(InvoiceShelf(h.shelf).MIDNIGHT_MODE());
        assertEq(InvoiceShelf(h.shelf).crossChainBuffer(), 6 hours);
        assertEq(address(RecibuMemoRouter(h.router).ESCROW()), h.escrow);

        (address[] memory to, bytes[] memory data) = s.safeBatch(SAFE);
        vm.startPrank(SAFE);
        for (uint256 i; i < to.length; ++i) {
            (bool ok,) = to[i].call(data[i]);
            assertTrue(ok);
        }
        vm.stopPrank();
        MultiTokenReceivableEscrow e = MultiTokenReceivableEscrow(h.escrow);
        assertTrue(e.supportedToken(s.USDC()) && e.supportedToken(s.EURC()));
        assertTrue(e.hasRole(e.ROUTER_ROLE(), h.router));
        (bool allowed, uint8 caps) = RecibuMemoRouter(h.router).tokenConfig(s.EURC());
        assertTrue(allowed);
        assertEq(caps, 3);
        assertEq(address(InvoiceShelf(h.shelf).escrow()), h.escrow);

        // escrow fund-release roles stay unassigned (data-only launch)
        assertFalse(e.hasRole(e.SETTLEMENT_ROLE(), SAFE));
        assertFalse(e.hasRole(e.ARBITER_ROLE(), SAFE));
        assertFalse(e.hasRole(e.SETTLEMENT_ROLE(), DEPLOYER));
        _dataOnlyFlow(h);
    }

    /// @dev the data-only runbook, executed by the Safe: register -> KYB -> score -> lock ->
    ///      bindAdvance -> record repayment. Emits events only; no token moves.
    function _dataOnlyFlow(DeployFxRecibuHubMainnet.Hub memory h) internal {
        BUFIIdentityRegistry id = BUFIIdentityRegistry(h.identity);
        BUFIReputationRegistry rep = BUFIReputationRegistry(h.reputation);
        InvoiceShelf shelf = InvoiceShelf(h.shelf);
        vm.startPrank(SAFE);
        uint256 seller = id.registerWorkspace(keccak256("ws:seller"), makeAddr("sellerOwner"));
        uint256 debtor = id.registerWorkspace(keccak256("ws:debtor"), makeAddr("debtorOwner"));
        id.setKybStatus(seller, true);
        id.setKybStatus(debtor, true);
        rep.setScore(seller, 74, 74, 1, bytes32("r"));
        rep.setScore(debtor, 74, 87, 1, bytes32("r"));
        uint64 first = uint64(block.timestamp + 30 days);
        uint256 inv = shelf.lockInvoice(
            seller,
            debtor,
            500e6,
            2,
            first,
            30 days,
            ReceivableCommitment.Terms({
                canonicalInvoiceCommitmentHash: keccak256("auth-fork-1"),
                issuedAt: uint64(block.timestamp),
                dueAt: first + 30 days
            }),
            FactoringEvidenceV1({
                featureRootHash: bytes32("f"), currentSnapshotHash: bytes32("c"), privateTermsHash: bytes32("p")
            }),
            BINV.DocBundle(bytes32("inv"), bytes32("assign"), bytes32("pay"), bytes32("svc"), bytes32("disp"))
        );
        uint64 maturity = uint64(shelf.dueDate(inv) + shelf.graceOf(inv) + shelf.crossChainBuffer());
        shelf.bindAdvance(inv, makeAddr("account"), keccak256("market"), maturity, 400e6, 396e6, 11000, bytes32("s"));
        shelf.recordRepaymentSettled(inv, 100e6, 100e6, 1, keccak256("cctp msg"), keccak256("memo"));
        shelf.recordAdvanceRepaid(inv, 50e6, keccak256("memo2"));
        shelf.applyPayment(inv, 150e6); // record-only on the Midnight path
        vm.stopPrank();
        assertEq(uint8(shelf.invoiceStatus(inv)), 1);
        (,,,, uint128 repaid) = shelf.advanceOf(inv);
        assertEq(repaid, 150e6);
    }

    function test_guard_rejectsOtherChains() public {
        DeployFxRecibuHubMainnet s = new DeployFxRecibuHubMainnet();
        uint256[3] memory bad = [uint256(43114), 5042002, 1];
        for (uint256 i; i < bad.length; ++i) {
            vm.chainId(bad[i]);
            vm.expectRevert(abi.encodeWithSelector(DeployFxRecibuHubMainnet.ChainNotAllowed.selector, bad[i]));
            s.deployAll(SAFE);
        }
    }
}
