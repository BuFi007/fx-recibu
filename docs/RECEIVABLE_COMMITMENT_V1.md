# Receivable commitment V1

`ReceivableCommitment` is the permanent anti-double-financing identity for one
economic receivable. It is distinct from a CRE operation ID (delivery replay
key), a PDF hash (one rendition), and the complete document bundle (audit
evidence).

The V1 commitment is:

```text
keccak256(abi.encode(
  keccak256("BUFI_FX_RECIBU_RECEIVABLE_COMMITMENT_V1"),
  uint16(1),
  uint256(chainId),
  uint256(sellerAgentId),
  uint256(debtorAgentId),
  bytes32(authorityInvoiceId),
  address(currency),
  uint128(faceAmount),
  uint64(issuedAt),
  uint64(dueAt),
  bytes32(assignmentHash)
))
```

`chainId` is the chain where the advance is funded. `currency` is the shelf's
denomination token. `dueAt` is the final contractual due timestamp and must
equal `firstMaturity + (nInstallments - 1) * interval` for the shelf's current
regular schedule.

For Argentina Factura E, the authority ID is not caller-selected. Fantasmita,
CRE, and the shelf use this exact derivation:

```text
canonicalInvoiceCommitmentHash = keccak256(bytes(invoiceCommitment))
authorityInvoiceId = keccak256(abi.encode(
  keccak256("BUFI_ARCA_FACTURA_E_AUTHORITY_INVOICE_ID_V1"),
  uint16(1),
  bytes32(canonicalInvoiceCommitmentHash)
))
```

Fantasmita signs the restricted canonical commitment plus both public digests.
CRE recomputes them, and the shelf receives only
`canonicalInvoiceCommitmentHash`, independently derives `authorityInvoiceId`,
and permanently consumes it. The raw HMAC-scoped commitment does not go
on-chain. A PDF hash, assignment hash, CRE operation ID, or local database ID
must never substitute for this derivation.

### Golden vector

The schema test pins this vector so an encoder change cannot silently rewrite
V1:

| Field | Value |
|---|---|
| `chainId` | `42161` |
| `sellerAgentId` | `101` |
| `debtorAgentId` | `202` |
| canonical invoice commitment | `hmac-sha256:v1:` followed by 64 `1` characters |
| `canonicalInvoiceCommitmentHash` | `0x3d979a1a760497ac02f1e95b48336d2546923073af0640a875b1afc526a3e69a` |
| `authorityInvoiceId` | `0xa40638045e4d986bcfb019ec8816fea2713a8a808ac7687eed9517bb4f2b8b66` |
| `currency` | `0x1111111111111111111111111111111111111111` |
| `faceAmount` | `12345678` |
| `issuedAt` | `1700000000` |
| `dueAt` | `1702592000` |
| `assignmentHash` | `keccak256("assignment-v1")` |
| commitment | `0x716a92ecdb4bbfa083738f6b6679749e8abd99fa47103140e7cd682f98411243` |

The separate full-document binding is:

```text
keccak256(abi.encode(
  keccak256("BUFI_FX_RECIBU_DOCUMENT_BUNDLE_V1"),
  uint16(1),
  bytes32(invoiceDocHash),
  bytes32(assignmentHash),
  bytes32(paymentInstructionHash),
  bytes32(servicingPolicyHash),
  bytes32(disputePolicyHash)
))
```

Changing payment instructions, servicing policy, or dispute policy changes
the evidence bundle but does not make the same receivable financeable again.

## Invariants

- A commitment is consumed forever after the first successful funding.
- The namespaced `authorityInvoiceId` is independently consumed forever, so
  changing assignment or economic fields cannot re-finance the same authority
  invoice on this shelf.
- Settlement, default, restructure, bINV burn, and document deletion never
  clear consumption.
- Changing the CRE operation ID does not change the commitment.
- A failed downstream mint or transfer rolls back consumption atomically.
- Raw authority identifiers must not expose PII.
- Changing any V1 field, type, order, domain, or meaning requires a new schema
  version and migration review.

Both indices are local to one deployed shelf and chain. Cross-chain
single-consumption requires an authenticated external registry/coordination
gate; V1 does not claim cross-chain uniqueness.

## CRE LOCK payload

The signed `FactoringSettlementExtractor` LOCK action payload is:

```text
abi.encode(
  address token,
  uint256 sellerAgentId,
  uint256 debtorAgentId,
  uint128 face,
  uint8 nInstallments,
  uint64 firstMaturity,
  uint32 interval,
  ReceivableCommitment.Terms terms,
  FactoringEvidenceV1 evidence,
  BINV.DocBundle docs
)
```

where `Terms` is `(bytes32 canonicalInvoiceCommitmentHash, uint64 issuedAt,
uint64 dueAt)`. The shelf derives the authority ID; it never trusts one from the
caller.
`FactoringEvidenceV1` is `(bytes32 featureRootHash, bytes32
currentSnapshotHash, bytes32 privateTermsHash)`. The CRE DON workflow must
authenticate and freshness-check those Fantasmita projection values before it
signs the report; the shelf permanently binds them to the funded invoice.
There is no legacy LOCK path without these terms.
