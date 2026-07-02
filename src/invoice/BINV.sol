// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @title BINV — the BUFI Invoice Standard token (SPEC §9, v0.1)
/// @notice One ERC-721 per ACCEPTED invoice, minted by InvoiceShelf at lock, burnt at
///         final settlement or write-off. SOULBOUND in v1 (mint+burn only): the invoice
///         itself never trades — the bIF tranches are the fungible DeFi surface.
///         Supersedes desk-v1 `BuInvoiceRecibo.sol` (struct-ledger ancestor) on Arc;
///         adopts its document-hash binding convention.
contract BINV is ERC721 {
    address public immutable SHELF;

    /// @dev the legal-boundary bundle (LEGAL_BOUNDARIES.md): content hashes of the
    ///      off-chain documents that make the on-chain state meaningful.
    struct DocBundle {
        bytes32 invoiceDocHash;
        bytes32 assignmentHash;
        bytes32 paymentInstructionHash;
        bytes32 servicingPolicyHash;
        bytes32 disputePolicyHash;
    }

    mapping(uint256 => DocBundle) internal _docs;

    error OnlyShelf();
    error Soulbound();

    modifier onlyShelf() {
        if (msg.sender != SHELF) revert OnlyShelf();
        _;
    }

    constructor(address shelf) ERC721("BUFI Invoice", "bINV") {
        SHELF = shelf;
    }

    function mint(address to, uint256 invoiceId, DocBundle calldata docs) external onlyShelf {
        _docs[invoiceId] = docs;
        _safeMint(to, invoiceId);
    }

    function burn(uint256 invoiceId) external onlyShelf {
        _burn(invoiceId);
        delete _docs[invoiceId];
    }

    function docBundleOf(uint256 invoiceId) external view returns (DocBundle memory) {
        return _docs[invoiceId];
    }

    /// @dev soulbound v1: only mint (from == 0) and burn (to == 0) may move the token.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) revert Soulbound();
        return super._update(to, tokenId, auth);
    }
}
