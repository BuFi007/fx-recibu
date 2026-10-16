// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReceivableEscrow} from "../src/rails/ReceivableEscrow.sol";
import {RecibuMemoRouter} from "../src/rails/RecibuMemoRouter.sol";
import {IInvoiceShelf} from "../src/interfaces/IInvoiceShelf.sol";

/// @title DeployRecibuMemoRouterMainnet — per-token ReceivableEscrow + RecibuMemoRouter on MAINNET.
/// @notice Allowlist: ARC 5042 and AVALANCHE C-Chain 43114. Every other chain reverts.
///
///  - Admin of every contract = env ROUTER_ADMIN (the BUFI Safe), set IN THE CONSTRUCTOR.
///    The deployer never holds a role, so there is nothing to renounce or transfer.
///  - One ReceivableEscrow per settlement token (USDC, EURC; Circle FiatToken v2.2 with
///    ERC-3009 + ERC-2612, probed 2026-10-16). No token is hardcoded in a contract: each
///    escrow is constructed with its token, the router is token-agnostic (setToken).
///  - RecibuMemoRouter needs an InvoiceShelf (env INVOICE_SHELF). There is no mainnet
///    InvoiceShelf yet; when INVOICE_SHELF is unset/empty the router step is SKIPPED and only
///    the escrows are deployed. See the handoff for the gap.
///  - Wiring is a Safe batch (admin-only): router.setToken(token, true, 3, escrow) and
///    escrow.grantRole(ROUTER_ROLE, router) for each token.
///  - Deterministic CREATE2 via the Arachnid deployer; re-running is a no-op.
contract DeployRecibuMemoRouterMainnet is Script {
    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 public constant ESCROW_SALT = keccak256("bufi.receivable-escrow.mainnet.v1");
    bytes32 public constant ROUTER_SALT = keccak256("bufi.recibu-memo-router.mainnet.v1");
    uint8 public constant CAPS = 3; // CAP_3009 | CAP_PERMIT

    address public constant USDC_ARC = 0x3600000000000000000000000000000000000000;
    address public constant EURC_ARC = 0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1;
    address public constant USDC_AVAX = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address public constant EURC_AVAX = 0xC891EB4cbdEFf6e073e859e987815Ed1505c2ACD;

    error ChainNotAllowed(uint256 chainId);
    error AdminMustBeContract(address admin);
    error DependencyMissing(address dep);
    error DeployFailed(address predicted);

    struct Result {
        address[] tokens;
        address[] escrows;
        address router; // zero when skipped
    }

    function tokensFor(uint256 chainId) public pure returns (address[] memory t) {
        t = new address[](2);
        if (chainId == 5042) (t[0], t[1]) = (USDC_ARC, EURC_ARC);
        else if (chainId == 43114) (t[0], t[1]) = (USDC_AVAX, EURC_AVAX);
        else revert ChainNotAllowed(chainId);
    }

    function escrowInitCode(address token, address admin) public pure returns (bytes memory) {
        return abi.encodePacked(type(ReceivableEscrow).creationCode, abi.encode(IERC20(token), admin));
    }

    function routerInitCode(address shelf, address admin) public pure returns (bytes memory) {
        return abi.encodePacked(type(RecibuMemoRouter).creationCode, abi.encode(IInvoiceShelf(shelf), admin));
    }

    function predict(bytes32 salt, bytes memory initCode) public pure returns (address) {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, keccak256(initCode)))))
        );
    }

    function run() external returns (Result memory r) {
        address admin = vm.envAddress("ROUTER_ADMIN");
        address shelf = vm.envOr("INVOICE_SHELF", address(0));
        return deployAll(admin, shelf);
    }

    function deployAll(address admin, address shelf) public returns (Result memory r) {
        r.tokens = tokensFor(block.chainid); // reverts off-allowlist
        if (admin.code.length == 0) revert AdminMustBeContract(admin);
        if (CREATE2_DEPLOYER.code.length == 0) revert DependencyMissing(CREATE2_DEPLOYER);
        console2.log("chainId", block.chainid);
        console2.log("admin", admin);

        r.escrows = new address[](r.tokens.length);
        for (uint256 i; i < r.tokens.length; ++i) {
            if (r.tokens[i].code.length == 0) revert DependencyMissing(r.tokens[i]);
            r.escrows[i] = _create2(ESCROW_SALT, escrowInitCode(r.tokens[i], admin));
            console2.log("token", r.tokens[i]);
            console2.log("  ReceivableEscrow", r.escrows[i]);
        }

        if (shelf == address(0) || shelf.code.length == 0) {
            console2.log("INVOICE_SHELF unset or has no code: RecibuMemoRouter SKIPPED");
            return r;
        }
        r.router = _create2(ROUTER_SALT, routerInitCode(shelf, admin));
        console2.log("RecibuMemoRouter", r.router);
    }

    function _create2(bytes32 salt, bytes memory initCode) internal returns (address predicted) {
        predicted = predict(salt, initCode);
        if (predicted.code.length != 0) return predicted;
        vm.startBroadcast();
        (bool ok, bytes memory ret) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
        vm.stopBroadcast();
        if (!ok || ret.length != 20 || address(bytes20(ret)) != predicted) revert DeployFailed(predicted);
    }
}
