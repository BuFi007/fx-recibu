Status: Implemented
Local conformance status: Complete
Production enabled: false
Authority source mode: OPAQUE_VERIFIER_OUTPUT
Local verifier mode: DETERMINISTIC_STRICT_MOCK
Official deployment entrypoint: DISABLED_REVERTS_BEFORE_ENV_OR_BROADCAST
Production verifier configured: false
Production origination domain configured: false

# fx-Recibú receivable commitment v1

This document fixes the local consumer contract for a verified Argentine
Factura E receivable. It is an engineering schema and does not approve a
production authority identity, proof system, verifier, proof provider,
deployment, origination domain, or legal policy. Local tests use explicit
synthetic opaque identifiers and a deterministic strict mock. Those fixtures
are test machinery, not privacy claims or authority evidence.

## Official ARCA basis

The off-chain authority layer owns canonicalization of this raw identity
tuple:

```text
ARCA environment
+ WSFEXV1
+ issuer CUIT
+ voucher type
+ point of sale
+ voucher number
```

This tuple is an engineering inference from official lookup and numbering
behavior; ARCA does not formally name it a global invoice key. Factura E
voucher type 19 is the only originatable invoice. Voucher types 20 and 21 are
debit and credit adjustments associated with the original type-19 identity;
they are not separately financeable identities. CAE is authorization
evidence, not invoice identity. CAEA is rejected for this adapter. WSFEX
request `Id` is a client retry identifier and is never an identity.

Official references:

- [WSFEXV1 developer manual](https://www.arca.gob.ar/ws/documentacion/manuales/WSFEX-Manualparaeldesarrollador_V3.1.1_ARCA.pdf)
- [RG 4290 numbering rules](https://biblioteca.arca.gob.ar/search/query/norma.aspx?p=t%3ARAG%7Cn%3A4290%7Co%3A3%7Ca%3A2018%7Cf%3A02%2F08%2F2018)
- [Factura E RG 4401](https://biblioteca.arca.gob.ar/search/query/norma.aspx?p=t%3ARAG%7Cn%3A4401%7Co%3A3%7Ca%3A2019%7Cf%3A21%2F01%2F2019)
- [CAEA RG 2926](https://biblioteca.arca.gob.ar/search/query/norma.aspx?p=t%3ARAG%7Cn%3A2926%7Co%3A3%7Ca%3A2010%7Cf%3A24%2F09%2F2010)
- [Official QR schema](https://www.afip.gob.ar/fe/qr/documentos/QRespecificaciones.pdf)

## Canonical raw tuple owner

BU-318/BU-319 own raw-tuple canonicalization, proof generation, verifier/key
governance, rotation, and revocation. Their independently reviewed production
artifact is `docs/ARCA_AUTHORITY_IDENTITY_V1.md`. The on-chain shelf never
receives or reconstructs raw CUIT, CAE, buyer data, voucher numbers, ARCA
responses, or enumerable-field hashes.

## Opaque authority invoice ID

`authorityInvoiceId` is a stable, chain-independent, opaque verifier output.
The shelf treats it only as the permanent anti-duplicate key. It must not be
derived from a Desk UUID, shelf or operation counter, operation ID, CAE,
document hash, PDF, mutable database row, or arbitrary caller salt.

Production requires an independently approved keyed-PRF/ZK nullifier design.
This local implementation deliberately selects no algorithm. Synthetic test
IDs are namespaced explicit inputs; they are not approved derivations and do
not establish privacy.

## Authority reference and evidence

The fixed-width v1 authority reference is:

```solidity
struct AuthorityRef {
    uint16 schemaVersion;
    bytes32 authorityInvoiceId;
    bytes32 authorityEvidenceCommitment;
    bytes32 verifierConfigId;
    uint8 authorityVoucherType;
    uint64 issuedAt;
    uint64 authorityPaymentDueAt;
}
```

`schemaVersion` is exactly 1. `authorityVoucherType` is exactly 19 for
origination. `issuedAt` and `authorityPaymentDueAt` are nonzero, and the latter
cannot precede the former. `authorityPaymentDueAt` represents WSFEX
`Fecha_pago`; it is not CAE expiry and need not equal the financing schedule's
final maturity.

`authorityEvidenceCommitment` separately binds the complete off-chain
authority evidence: canonical identity tuple, voucher/payment dates,
export-operation type, total, currency and FX rate, buyer/country commitments,
CAE value and expiry, result and observations, adjustment identities,
canonical response/item root, and schema/verifier/environment versions.

The production authority policy must pin:

```text
Origination voucher type: 19; adjustments: 20,21 only
Factura E authorization policy: CAE_ONLY; CAEA_REJECTED
```

## Verifier and key rotation boundary

The read-only verifier approves the opaque authority reference together with
seller and debtor IDs, currency, face amount, recourse election, and complete
schedule. It also reports its supported schema, configuration identifier,
approved chain, and approved shelf. The shelf pins the expected verifier
address, runtime codehash, schema, configuration, chain, and shelf at
construction and rechecks the complete reported tuple immediately before each
funding verification. A nonzero ID or matching codehash alone is never proof.

Local tests use a strict stateful mock with explicit approval and revocation.
The mock's storage-drift hooks prove that same runtime bytecode with a different
configuration fails closed. Production v1 requires an independently audited,
immutable, non-proxy verifier with no administrator. Any key rotation,
revocation, verifier upgrade, proxy, or multi-domain policy needs independently
approved evidence and a versioned configuration; this document chooses none.

## Chain/domain-specific receivable commitment

The semantic constants are fixed:

```text
RECEIVABLE_DOMAIN = keccak256("BUFI_FX_RECIBU_RECEIVABLE_V1")
                  = 0x49385b4266c49996eacbc5bd06bca8c63684a02c863914baaa554513aa983a3f
VERSION           = 1
```

The shelf computes the commitment with `abi.encode`, never packed encoding:

```text
keccak256(abi.encode(
  RECEIVABLE_DOMAIN,
  uint16(1),
  uint256(block.chainid),
  address(invoiceShelf),
  uint256(sellerAgentId),
  uint256(debtorAgentId),
  bytes32(authorityInvoiceId),
  bytes32(authorityEvidenceCommitment),
  bytes32(verifierConfigId),
  uint8(authorityVoucherType),
  address(currency),
  uint128(faceAmount),
  bool(recourse),
  uint16(advanceRateBps),
  uint128(advanceAmount),
  uint128(holdbackAmount),
  uint64(issuedAt),
  uint64(authorityPaymentDueAt),
  uint8(nInstallments),
  uint64(firstMaturity),
  uint32(interval),
  uint32(grace),
  uint8(tranche),
  bytes32(assignmentHash)
))
```

The shelf derives the advance rate, advance, holdback, grace, and tranche from
live canonical policy before hashing. It stores those projections and requires
advance plus holdback to equal face. V1 requires `recourse == true`.
Non-recourse remains production-disabled until differentiated pricing,
insurance, recovery, and loss allocation are implemented and approved.

## Full document-bundle commitment

The five `BINV.DocBundle` content hashes remain distinct from the separately
stored legal `recourse` election. Every hash is required and nonzero. The
document commitment is chain-independent evidence binding:

```text
DOCUMENT_DOMAIN = keccak256("BUFI_FX_RECIBU_DOCUMENT_BUNDLE_V1")
                = 0x29e20b268db4ae20ab8646be4f1d600213a14a7defce68fda440e2e93d4d05f0

keccak256(abi.encode(
  DOCUMENT_DOMAIN,
  uint16(1),
  bytes32(authorityInvoiceId),
  uint8(authorityVoucherType),
  bytes32(invoiceDocHash),
  bytes32(assignmentHash),
  bytes32(paymentInstructionHash),
  bytes32(servicingPolicyHash),
  bytes32(disputePolicyHash),
  bool(recourse)
))
```

The assignment hash intentionally appears in both document and receivable
commitments. The other ancillary hashes change only the document commitment.

## Permanent consumption

After all schema, verifier, duplicate, eligibility, exposure, reserve,
tranche, and liquidity checks pass, the shelf permanently records the first
funded invoice for both the authority ID and receivable commitment before
minting bINV or transferring the advance. A downstream revert rolls all writes
back. Settlement, default, resolution, restructuring, and bINV burn never
clear these records.

This establishes exactly-once consumption only inside the configured canonical
origination shelf/domain. It does not establish global cross-chain uniqueness.

## CRE LOCK encoding

The v1 action payload is exact and uses standard ABI encoding:

```solidity
abi.encode(
    address token,
    uint256 sellerAgentId,
    uint256 debtorAgentId,
    uint128 face,
    uint8 nInstallments,
    uint64 firstMaturity,
    uint32 interval,
    ReceivableCommitment.FundingTerms terms,
    BINV.DocBundle docs
)
```

The sole shelf signature is:

```text
lockInvoice(uint256,uint256,uint128,uint8,uint64,uint32,((uint16,bytes32,bytes32,bytes32,uint8,uint64,uint64),bool),(bytes32,bytes32,bytes32,bytes32,bytes32))
selector: 0xb8a01dfd
```

The token is signed into the extractor payload and must equal the shelf token;
it is not repeated in the shelf call. Any wire change requires a new action or
schema version and a synchronized producer plan.

## Cross-chain limitation

The authority ID is chain-independent, but one shelf mapping proves uniqueness
only in that shelf. Enabling another shelf or chain requires an accepted global
nullifier registry or synchronous cross-chain consumption design. Production
MVP must pin exactly one chain, shelf, verifier, configuration, and runtime
codehash.

## Explicit non-claims

This local contract does not claim that:

- BUFI creates a government-backed IOU or legal assignment;
- a simple hash of raw ARCA fields is private or unique;
- CAE, CAEA, WSFEX request ID, a PDF, or a Desk record is invoice identity;
- the deterministic strict mock is a production verifier;
- runtime codehash generically detects proxies or mutable policy;
- a per-shelf mapping provides global or cross-chain uniqueness;
- Reclaim, another proof provider, an algorithm, a key, an address, a chain,
  or a deployment configuration has been selected;
- production is enabled or safe to deploy.

## Production activation gates

Production remains fail-closed until all of the following are independently
reviewed, machine-pinned, and evidenced:

1. An Accepted `ARCA_AUTHORITY_IDENTITY_V1.md` owned by BU-318/BU-319.
2. Product, legal, and security approval evidence for the raw identity tuple,
   keyed-PRF/ZK nullifier, proof verification, key rotation, and revocation.
3. The exact immutable non-proxy verifier chain, verifier address, runtime
   codehash, schema version, configuration ID, and proof-provider
   configuration, with `Verifier upgrade policy: IMMUTABLE_NON_PROXY` and
   `Verifier admin: NONE` in the accepted artifact.
4. One exact origination shelf and one origination domain for MVP. A second
   domain requires an accepted global-nullifier protocol.
5. An owner-reviewed deployment manifest that machine-compares every pinned
   value before any production entrypoint can exist.
6. Coordinated shelf, extractor, indexer, role, migration, and deployment
   review. No local strict-mock value may be copied into production evidence.

Until those gates pass, the official deployment entrypoint remains a typed
pure revert and every production marker at the top of this document remains
false.
