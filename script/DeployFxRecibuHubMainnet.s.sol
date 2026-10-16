// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {BUFIIdentityRegistry} from "../src/identity/BUFIIdentityRegistry.sol";
import {BUFIReputationRegistry} from "../src/identity/BUFIReputationRegistry.sol";
import {WorkspaceTierRegistry} from "../src/credit/WorkspaceTierRegistry.sol";
import {InvoiceShelf} from "../src/invoice/InvoiceShelf.sol";
import {MultiTokenReceivableEscrow} from "../src/rails/MultiTokenReceivableEscrow.sol";
import {RecibuMemoRouter} from "../src/rails/RecibuMemoRouter.sol";
import {IInvoiceShelf} from "../src/interfaces/IInvoiceShelf.sol";
import {IBUFIIdentityRegistry} from "../src/interfaces/IBUFIIdentityRegistry.sol";
import {IBUFIReputationRegistry} from "../src/interfaces/IBUFIReputationRegistry.sol";

/// @title DeployFxRecibuHubMainnet — the fx-Recibú HUB on Arc mainnet (5042 ONLY).
/// @notice Hub-and-spoke: Arc = hub (Morpho Midnight pool, InvoiceShelf registry, multi-token
///         escrow, RecibuMemoRouter). Avalanche = spoke (MemoConduit CCTP only; see PR #7).
///
///  Deploys (Arachnid CREATE2, deterministic, idempotent), every admin = ROUTER_ADMIN (the Safe)
///  IN THE CONSTRUCTOR; the deployer EOA never holds a role:
///    BUFIIdentityRegistry(Safe) · BUFIReputationRegistry(Safe, identity)
///    WorkspaceTierRegistry(identity, reputation)          (no admin)
///    InvoiceShelf(USDC denomination, …, Safe, midnightMode=true)  registry only, tranches off
///    MultiTokenReceivableEscrow(Safe) · RecibuMemoRouter(shelf, escrow, Safe)
///  Wiring = one Safe batch, see `safeBatch()` and the handoff JSON.
contract DeployFxRecibuHubMainnet is Script {
    uint256 public constant HUB_CHAIN_ID = 5042;
    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address public constant USDC = 0x3600000000000000000000000000000000000000;
    address public constant EURC = 0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1;
    uint8 public constant CAPS = 3; // CAP_3009 | CAP_PERMIT (FiatToken v2.2, probed)

    bytes32 public constant SALT_IDENTITY = keccak256("bufi.hub.identity.v1");
    bytes32 public constant SALT_REPUTATION = keccak256("bufi.hub.reputation.v1");
    bytes32 public constant SALT_TIERS = keccak256("bufi.hub.tiers.v1");
    bytes32 public constant SALT_SHELF = keccak256("bufi.hub.invoice-shelf.midnight.v1");
    bytes32 public constant SALT_ESCROW = keccak256("bufi.hub.receivable-escrow.multi.v1");
    bytes32 public constant SALT_ROUTER = keccak256("bufi.hub.recibu-memo-router.v1");

    struct Hub {
        address identity;
        address reputation;
        address tiers;
        address shelf;
        address escrow;
        address router;
    }

    error ChainNotAllowed(uint256 chainId);
    error AdminMustBeContract(address admin);
    error DependencyMissing(address dep);
    error DeployFailed(address predicted);

    function run() external returns (Hub memory h) {
        return deployAll(vm.envAddress("ROUTER_ADMIN"));
    }

    function predictAll(address admin) public pure returns (Hub memory h) {
        h.identity = _predict(SALT_IDENTITY, _identityCode(admin));
        h.reputation = _predict(SALT_REPUTATION, _reputationCode(admin, h.identity));
        h.tiers = _predict(SALT_TIERS, _tiersCode(h.identity, h.reputation));
        h.shelf = _predict(SALT_SHELF, _shelfCode(admin, h));
        h.escrow = _predict(SALT_ESCROW, _escrowCode(admin));
        h.router = _predict(SALT_ROUTER, _routerCode(admin, h.shelf, h.escrow));
    }

    function deployAll(address admin) public returns (Hub memory h) {
        if (block.chainid != HUB_CHAIN_ID) revert ChainNotAllowed(block.chainid);
        if (admin.code.length == 0) revert AdminMustBeContract(admin);
        if (CREATE2_DEPLOYER.code.length == 0) revert DependencyMissing(CREATE2_DEPLOYER);
        if (USDC.code.length == 0) revert DependencyMissing(USDC);
        if (EURC.code.length == 0) revert DependencyMissing(EURC);
        h = predictAll(admin);
        _create2(SALT_IDENTITY, _identityCode(admin), h.identity);
        _create2(SALT_REPUTATION, _reputationCode(admin, h.identity), h.reputation);
        _create2(SALT_TIERS, _tiersCode(h.identity, h.reputation), h.tiers);
        _create2(SALT_SHELF, _shelfCode(admin, h), h.shelf);
        _create2(SALT_ESCROW, _escrowCode(admin), h.escrow);
        _create2(SALT_ROUTER, _routerCode(admin, h.shelf, h.escrow), h.router);
        console2.log("admin (Safe)", admin);
        console2.log("BUFIIdentityRegistry", h.identity);
        console2.log("BUFIReputationRegistry", h.reputation);
        console2.log("WorkspaceTierRegistry", h.tiers);
        console2.log("InvoiceShelf (midnight)", h.shelf);
        console2.log("MultiTokenReceivableEscrow", h.escrow);
        console2.log("RecibuMemoRouter", h.router);
    }

    /// @notice the Safe wiring batch (in order), DATA-ONLY launch mode.
    ///  - wiring: reputation SETTLEMENT_ROLE -> shelf (on-time scoring), shelf.setEscrow,
    ///    escrow tokens USDC/EURC, escrow ROUTER_ROLE -> router, router tokens USDC/EURC;
    ///  - data roles to the SAFE (never an EOA): identity ISSUER, reputation ATTESTOR,
    ///    shelf SERVICER / OPS / ADVANCE, so the Safe can register workspaces, lock invoices,
    ///    bindAdvance and record repayments (events only, no cash moves on the Midnight path);
    ///  - escrow SETTLEMENT_ROLE / ARBITER_ROLE are deliberately NOT granted: funds paid into the
    ///    escrow cannot leave it until a reviewed repay adapter / dispute process exists.
    function safeBatch(address admin) public pure returns (address[] memory to, bytes[] memory data) {
        Hub memory h = predictAll(admin);
        to = new address[](12);
        data = new bytes[](12);
        (to[0], data[0]) =
        (h.reputation, abi.encodeCall(IAccessControl.grantRole, (keccak256("SETTLEMENT_ROLE"), h.shelf)));
        (to[1], data[1]) = (h.shelf, abi.encodeCall(InvoiceShelf.setEscrow, (h.escrow)));
        (to[2], data[2]) = (h.escrow, abi.encodeCall(MultiTokenReceivableEscrow.setToken, (USDC, true)));
        (to[3], data[3]) = (h.escrow, abi.encodeCall(MultiTokenReceivableEscrow.setToken, (EURC, true)));
        (to[4], data[4]) = (h.escrow, abi.encodeCall(IAccessControl.grantRole, (keccak256("ROUTER_ROLE"), h.router)));
        (to[5], data[5]) = (h.router, abi.encodeCall(RecibuMemoRouter.setToken, (USDC, true, CAPS)));
        (to[6], data[6]) = (h.router, abi.encodeCall(RecibuMemoRouter.setToken, (EURC, true, CAPS)));
        (to[7], data[7]) = (h.identity, abi.encodeCall(IAccessControl.grantRole, (keccak256("ISSUER_ROLE"), admin)));
        (to[8], data[8]) = (h.reputation, abi.encodeCall(IAccessControl.grantRole, (keccak256("ATTESTOR_ROLE"), admin)));
        (to[9], data[9]) = (h.shelf, abi.encodeCall(IAccessControl.grantRole, (keccak256("SERVICER_ROLE"), admin)));
        (to[10], data[10]) = (h.shelf, abi.encodeCall(IAccessControl.grantRole, (keccak256("OPS_ROLE"), admin)));
        (to[11], data[11]) = (h.shelf, abi.encodeCall(IAccessControl.grantRole, (keccak256("ADVANCE_ROLE"), admin)));
    }

    // ── init codes ──
    function _identityCode(address admin) internal pure returns (bytes memory) {
        return abi.encodePacked(type(BUFIIdentityRegistry).creationCode, abi.encode(admin));
    }

    function _reputationCode(address admin, address identity) internal pure returns (bytes memory) {
        return abi.encodePacked(type(BUFIReputationRegistry).creationCode, abi.encode(admin, identity));
    }

    function _tiersCode(address identity, address reputation) internal pure returns (bytes memory) {
        return abi.encodePacked(type(WorkspaceTierRegistry).creationCode, abi.encode(identity, reputation));
    }

    function _shelfCode(address admin, Hub memory h) internal pure returns (bytes memory) {
        return abi.encodePacked(
            type(InvoiceShelf).creationCode,
            abi.encode(
                IERC20(USDC),
                IBUFIIdentityRegistry(h.identity),
                IBUFIReputationRegistry(h.reputation),
                WorkspaceTierRegistry(h.tiers),
                admin,
                true
            )
        );
    }

    function _escrowCode(address admin) internal pure returns (bytes memory) {
        return abi.encodePacked(type(MultiTokenReceivableEscrow).creationCode, abi.encode(admin));
    }

    function _routerCode(address admin, address shelf, address escrow) internal pure returns (bytes memory) {
        return abi.encodePacked(
            type(RecibuMemoRouter).creationCode,
            abi.encode(IInvoiceShelf(shelf), MultiTokenReceivableEscrow(escrow), admin)
        );
    }

    function _predict(bytes32 salt, bytes memory initCode) internal pure returns (address) {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, keccak256(initCode)))))
        );
    }

    function _create2(bytes32 salt, bytes memory initCode, address predicted) internal {
        if (predicted.code.length != 0) return;
        vm.startBroadcast();
        (bool ok, bytes memory ret) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
        vm.stopBroadcast();
        if (!ok || ret.length != 20 || address(bytes20(ret)) != predicted) revert DeployFailed(predicted);
    }
}
