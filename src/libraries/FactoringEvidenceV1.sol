// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

/// @notice DON-attested Fantasmita projection bindings for one funding decision.
/// @dev The Shelf persists these values but does not itself verify signatures or
///      freshness. Production SERVICER authority must be restricted to the CRE
///      extractor whose DON workflow verifies those properties before delivery.
struct FactoringEvidenceV1 {
    bytes32 featureRootHash;
    bytes32 currentSnapshotHash;
    bytes32 privateTermsHash;
}
