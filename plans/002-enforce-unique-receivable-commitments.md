# Plan 002: Consume each verified authority invoice once in the canonical origination domain

> **Executor instructions**: Read this plan fully. Run every gate and stop on
> every STOP condition. Never derive an authority invoice ID from a Desk UUID,
> shelf counter, operation ID, CAE, PDF/document hash, or mutable database row.
> Never put raw CUIT, CAE, buyer data, or an ARCA response onchain.
>
> **Drift check — run from the repository root first**:
>
> <code>git merge-base --is-ancestor 3b17523 HEAD &amp;&amp; test -z "$(git status --porcelain)" &amp;&amp; test -z "$(git diff --stat 3b17523..HEAD -- components/fx-recibu/docs/LEGAL_BOUNDARIES.md components/fx-recibu/docs/RECEIVABLE_COMMITMENT_V1.md components/fx-recibu/src/interfaces/IAuthorityInvoiceVerifier.sol components/fx-recibu/src/interfaces/IReceivableDomainView.sol components/fx-recibu/src/libraries/ReceivableCommitment.sol components/fx-recibu/src/invoice/InvoiceShelf.sol components/fx-recibu/src/rails/FactoringSettlementExtractor.sol components/fx-recibu/script/Deploy.s.sol components/fx-recibu/test)"</code>
>
> Any output from that implementation-surface diff is a STOP condition until
> the baseline excerpts below are re-vetted and this plan is refreshed. The
> production authority artifact is deliberately not a local-conformance
> prerequisite. It remains a fail-closed activation gate and is out of scope.

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: HIGH
- **Depends on**:
  - Plan 001 full-installment accounting — complete at <code>cabddcc</code>
  - Plan 003 canonical installment projection — complete at <code>83cb818</code>
- **Category**: security
- **Planned at**: reviewed verification-repair commit <code>3b17523</code>, 2026-07-11
- **Linear mapping**: BU-318 defines identity; BU-322 consumes it
- **Execution state**: READY for production-disabled, keyless local
  conformance. Live activation remains blocked on the independently accepted
  authority/nullifier/verifier/deployment contract.

## Why this matters

CRE operation replay protection prevents the same report from executing twice,
but a servicer can submit a second operation for the same legal invoice. The
shelf currently has no stable authority identity and therefore cannot detect
that duplicate. Document hashes and CAE are not safe uniqueness keys:
documents can be regenerated, CAE is authorization evidence, and both raw
ARCA fields and simple hashes of enumerable fields leak information.

This plan introduces three deliberately separate values:

1. <code>authorityInvoiceId</code> — a stable, opaque, chain-independent
   keyed-PRF/ZK nullifier for the ARCA voucher identity;
2. <code>receivableCommitment</code> — a chain/domain-specific commitment to
   the approved economic and legal funding terms;
3. <code>documentCommitment</code> — a separate commitment to the full
   five-field document bundle.

Within BUFI's one canonical origination domain, the shelf consumes the verified
authority invoice ID permanently before value leaves. A new operation, changed
policy document, settlement, default, burn, or failed acknowledgement cannot
make that invoice financeable again. This plan does not claim global or
multi-shelf uniqueness.

## Official authority facts

Official ARCA evidence supports the engineering identity tuple:

~~~text
ARCA environment
+ WSFEXV1
+ issuer CUIT
+ voucher type
+ point of sale
+ voucher number
~~~

ARCA does not formally name this a “global invoice key”; that description is
an engineering inference from official lookup and numbering behavior.
Factura E voucher types are 19 (invoice), 20 (debit note), and 21 (credit
note). CAE is authorization evidence, not the voucher identity. CAEA is not
valid for the Factura E adapter. WSFEX request <code>Id</code> is a
client-assigned retry identifier, not invoice identity.

Primary sources:

- [WSFEXV1 developer manual](https://www.arca.gob.ar/ws/documentacion/manuales/WSFEX-Manualparaeldesarrollador_V3.1.1_ARCA.pdf)
- [RG 4290 numbering rules](https://biblioteca.arca.gob.ar/search/query/norma.aspx?p=t%3ARAG%7Cn%3A4290%7Co%3A3%7Ca%3A2018%7Cf%3A02%2F08%2F2018)
- [Factura E RG 4401](https://biblioteca.arca.gob.ar/search/query/norma.aspx?p=t%3ARAG%7Cn%3A4401%7Co%3A3%7Ca%3A2019%7Cf%3A21%2F01%2F2019)
- [CAEA RG 2926](https://biblioteca.arca.gob.ar/search/query/norma.aspx?p=t%3ARAG%7Cn%3A2926%7Co%3A3%7Ca%3A2010%7Cf%3A24%2F09%2F2010)
- [Official QR schema](https://www.afip.gob.ar/fe/qr/documentos/QRespecificaciones.pdf)

BU-318/BU-319 own raw-tuple canonicalization, PRF/ZK generation, proof
verification, key governance, and rotation. Their future accepted repository
artifact is <code>docs/ARCA_AUTHORITY_IDENTITY_V1.md</code>. That artifact is a
mandatory **production activation** prerequisite, but requiring its deployed
verifier address before compiling the consumer creates a circular dependency:
the queue explicitly permits only keyless local conformance, while the
production verifier and shelf require later review and deployment.

This reconciled plan therefore implements only the consumer boundary and
single-use invariant against a deterministic strict test verifier. The shelf
treats <code>authorityInvoiceId</code> as an opaque verifier output and never
computes it. Tests use synthetic namespaced IDs that are not derived from raw
ARCA fields, documents, operation IDs, or shelf counters. No test fixture is
an approved PRF, proof, verifier, chain, address, codehash, shelf, or provider
configuration. Production remains fail-closed until the independent artifact
pins all of those values and security/product/legal approve them.

## Current state

- <code>InvoiceShelf.lockInvoice</code> accepts seller/debtor, face, schedule,
  and <code>BINV.DocBundle</code>, but no authority identity.
- <code>FactoringSettlementExtractor</code> deduplicates
  <code>operationId</code>, not a legal receivable.
- <code>BINV</code> deletes the raw document bundle at burn.
- The shelf now has one canonical installment cursor/projection; this plan
  must preserve it and must not introduce schedule state elsewhere.

Every live direct lock caller is in:

- <code>components/fx-recibu/src/invoice/InvoiceShelf.sol</code>
- <code>components/fx-recibu/src/rails/FactoringSettlementExtractor.sol</code>
- <code>components/fx-recibu/test/invariant/ShelfInvariants.t.sol</code>
- <code>components/fx-recibu/test/unit/Deploy.t.sol</code>
- <code>components/fx-recibu/test/unit/FactoringSettlementExtractor.t.sol</code>
- <code>components/fx-recibu/test/unit/GuardHook.t.sol</code>
- <code>components/fx-recibu/test/unit/InvoiceShelf.t.sol</code>
- <code>components/fx-recibu/test/unit/OracleAndReserve.t.sol</code>
- <code>components/fx-recibu/test/unit/Rails.t.sol</code>
- <code>components/fx-recibu/test/unit/RecibuMemoRouter.t.sol</code>

Baseline excerpts at <code>3b17523</code> that the executor must compare before
editing (line numbers are descriptive; every displayed field/modifier is
normative and no struct field is elided):

~~~solidity
// InvoiceShelf.sol:55-70
struct Invoice {
    uint256 sellerAgentId;
    uint256 debtorAgentId;
    uint128 face; // USDC 6-dec
    uint128 advance; // funded to seller at lock
    uint128 outstanding; // advance not yet repaid
    uint128 holdback; // face − advance (notional): the seller's residual, paid by the debtor
    uint128 holdbackCollected; // debtor payments received beyond the advance — CASH held here
    uint64 firstMaturity;
    uint32 interval;
    uint32 grace;
    uint8 nInstallments;
    uint8 paidInstallments;
    uint8 tranche; // 0=A 1=B 2=C — the most-junior eligible tranche funds it
    Status status;
}

// InvoiceShelf.sol:201-209
function lockInvoice(
    uint256 sellerAgentId,
    uint256 debtorAgentId,
    uint128 face,
    uint8 nInstallments,
    uint64 firstMaturity,
    uint32 interval,
    BINV.DocBundle calldata docs
) external onlyRole(SERVICER_ROLE) nonReentrant returns (uint256 invoiceId);

// InvoiceShelf.sol:259-280
uint8 tranche = uint8(TIERS.trancheEligibility(...));
uint32 grace = TIERS.tierOf(...) >= WorkspaceTierRegistry.Tier.Strong
    ? Params.GRACE_STRONG
    : Params.GRACE_WEAK;
invoices[invoiceId] = Invoice({
    sellerAgentId: sellerAgentId,
    debtorAgentId: debtorAgentId,
    face: face,
    advance: advance,
    outstanding: advance,
    holdback: face - advance,
    holdbackCollected: 0,
    firstMaturity: firstMaturity,
    interval: interval,
    grace: grace,
    nInstallments: nInstallments,
    paidInstallments: 0,
    tranche: tranche,
    status: Status.Funded
});
~~~

At the same baseline, <code>ShelfHandler.lock</code> catches every lock revert
and appends only successful IDs. A uniqueness invariant that merely loops that
array can therefore pass with zero successful locks; this plan adds an explicit
non-vacuity witness.

## Identity, evidence, and commitment contract

### AuthorityRef

Define a shared fixed-width struct:

~~~solidity
struct AuthorityRef {
    uint16 schemaVersion;
    bytes32 authorityInvoiceId;
    bytes32 authorityEvidenceCommitment;
    bytes32 verifierConfigId;
    uint8 authorityVoucherType;
    uint64 issuedAt;
    uint64 authorityPaymentDueAt;
}

struct FundingTerms {
    AuthorityRef authority;
    bool recourse;
}

struct ScheduleTerms {
    uint8 nInstallments;
    uint64 firstMaturity;
    uint32 interval;
    uint32 grace;
}

struct ComputedFundingTerms {
    uint16 advanceRateBps;
    uint128 advanceAmount;
    uint128 holdbackAmount;
    uint8 tranche;
}
~~~

Rules:

- schema version v1 is explicit and immutable;
- <code>authorityInvoiceId</code> is the stable, chain-independent opaque
  verifier output (a synthetic opaque fixture in local tests and a
  security-approved nullifier only in production);
- <code>authorityEvidenceCommitment</code> separately binds the complete
  authority evidence;
- <code>verifierConfigId</code> identifies the configured verifier/schema/key
  profile without exposing its secret; local fixture IDs have no production
  authority;
- <code>authorityVoucherType</code> is explicit and equals <code>19</code> for
  an originatable Factura E invoice. Types <code>20</code> and <code>21</code>
  are adjustment evidence for an already identified type-19 invoice and can
  never originate or mint a separately financeable receivable;
- <code>issuedAt</code> is the authority voucher date;
- <code>authorityPaymentDueAt</code> is WSFEX <code>Fecha_pago</code>, not CAE
  expiry and not automatically the financing schedule's final maturity.
- <code>recourse</code> is the explicit legal/product election required by
  <code>LEGAL_BOUNDARIES.md</code>. It is stored separately from the five hash
  fields in <code>BINV.DocBundle</code>; it is not falsely described as a
  document hash.

The evidence commitment must bind, offchain, the canonical identity tuple,
voucher/payment dates, export-operation type, total, currency and FX rate,
buyer/country commitments, authorization type CAE, CAE value/expiry,
result/observations, associated credit/debit voucher identities, canonical
response/item root, and schema/verifier/environment versions.

The accepted authority artifact must define the adjustment relationship and
pin this exact funding rule:

~~~text
Origination voucher type: 19; adjustments: 20,21 only
Factura E authorization policy: CAE_ONLY; CAEA_REJECTED
~~~

The shelf independently rejects every <code>authorityVoucherType != 19</code>
before calling the verifier. The verifier independently enforces the same rule
and proves that any type-20/type-21 evidence is attached to the original
type-19 identity; a note's own nullifier is never a funding identity.

### IAuthorityInvoiceVerifier

Create a read-only verifier boundary. It receives the opaque
<code>AuthorityRef</code>, seller/debtor IDs, currency, face amount, and the
complete proposed schedule, and returns true only for a currently approved,
non-revoked verification record. BU-318/underwriting policy and the configured
verifier exclusively approve the authority-specific relationship between the
authority payment date and the financing schedule; this plan must not guess
equality or ordering. The shelf independently enforces only generic
<code>issuedAt != 0</code>, <code>authorityPaymentDueAt != 0</code>, and
<code>authorityPaymentDueAt &gt;= issuedAt</code> invariants before calling the
verifier.
The shelf must call it before consuming identity or moving value.

The verifier interface exposes its configuration ID and supported schema
version. Wrong configuration, unsupported version, missing/revoked evidence,
or false verification fails closed. A nonzero ID is not sufficient.

Use a deterministic mock only in tests. Do not implement PRF keys, ARCA
credentials, or a production Reclaim verifier in this plan.

Pin this exact ABI; do not invent an alternate verifier shape:

~~~solidity
interface IAuthorityInvoiceVerifier {
    function verifierConfigId() external view returns (bytes32);
    function supportedSchemaVersion() external view returns (uint16);
    function approvedChainId() external view returns (uint256);
    function approvedShelf() external view returns (address);
    function isVerified(
        ReceivableCommitment.AuthorityRef calldata authority,
        uint256 sellerAgentId,
        uint256 debtorAgentId,
        address currency,
        uint128 faceAmount,
        bool recourse,
        uint8 nInstallments,
        uint64 firstMaturity,
        uint32 interval
    ) external view returns (bool);
}
~~~

The library constants are also load-bearing:

~~~text
RECEIVABLE_DOMAIN = keccak256("BUFI_FX_RECIBU_RECEIVABLE_V1")
DOCUMENT_DOMAIN   = keccak256("BUFI_FX_RECIBU_DOCUMENT_BUNDLE_V1")
VERSION           = 1
~~~

Pin their computed values:

- <code>RECEIVABLE_DOMAIN = 0x49385b4266c49996eacbc5bd06bca8c63684a02c863914baaa554513aa983a3f</code>
- <code>DOCUMENT_DOMAIN = 0x29e20b268db4ae20ab8646be4f1d600213a14a7defce68fda440e2e93d4d05f0</code>

Use this exact receivable golden vector:

| Field | Value |
| --- | --- |
| chain ID | <code>5042002</code> |
| shelf | <code>0x1111111111111111111111111111111111111111</code> |
| seller / debtor agent IDs | <code>101</code> / <code>202</code> |
| authority ID / evidence / verifier config | <code>0xaaaa…aaaa</code> / <code>0xbbbb…bbbb</code> / <code>0xcccc…cccc</code> (32 bytes each) |
| authority voucher type | <code>19</code> |
| currency | <code>0x2222222222222222222222222222222222222222</code> |
| face | <code>1000000000</code> |
| recourse / advance rate | <code>true</code> / <code>8000</code> bps |
| advance / holdback | <code>800000000</code> / <code>200000000</code> |
| issued / authority payment due | <code>1780000000</code> / <code>1782592000</code> |
| count / first maturity / interval | <code>4</code> / <code>1780648000</code> / <code>648000</code> |
| grace / tranche | <code>432000</code> / <code>0</code> |
| assignment hash | <code>0xdddd…dddd</code> (32 bytes) |
| expected commitment | <code>0x829261aa91a44479007c08156fc76e3da44676c422081e816b6d3455227d097a</code> |

The test must independently <code>abi.encode</code> these values and compare
the exact digest; it may not call the library to compute its expected result.

The exact literals, field order, and types must appear in the schema document,
library, independent golden-vector test, and CRE LOCK wire.

Pin these library function signatures:

~~~solidity
function hashReceivable(
    uint256 chainId,
    address invoiceShelf,
    uint256 sellerAgentId,
    uint256 debtorAgentId,
    address currency,
    uint128 faceAmount,
    FundingTerms memory terms,
    ScheduleTerms memory schedule,
    ComputedFundingTerms memory computed,
    bytes32 assignmentHash
) internal pure returns (bytes32);

function hashDocumentBundle(
    AuthorityRef memory authority,
    BINV.DocBundle memory docs,
    bool recourse
) internal pure returns (bytes32);
~~~

### Receivable commitment

Define the chain/domain-specific v1 commitment with
<code>abi.encode</code>, never packed encoding:

~~~text
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
~~~

The shelf computes <code>advanceRateBps</code>, <code>advanceAmount</code>,
<code>holdbackAmount</code>, <code>grace</code>, and <code>tranche</code> from
the live canonical policy before hashing and requires
<code>advanceAmount + holdbackAmount == faceAmount</code>.
<code>recourse</code> must be <code>true</code> in v1. Although the existing
tiers expose <code>nonRecourseEligible</code>, the live shelf does not yet
implement differentiated non-recourse pricing, insurance, or recovery/loss
branching. A false election therefore reverts with
<code>NonRecourseNotEnabled()</code>. Enabling it requires a new accepted
economic/legal plan and a new commitment version. Store <code>recourse</code>,
rate, advance, and holdback as separate
invoice projections, and use the canonical stored grace and tranche, so every
committed funded term remains inspectable. No caller may supply a grace period
or tranche that differs from the values the shelf has just computed and stored.

The authority ID is the anti-duplicate key. The receivable commitment binds
that identity to this funding domain and the actual funded economic/legal
terms. The full
<code>DocBundle</code> gets a separate domain/version commitment in its exact
declared field order.

Pin the document/legal-election commitment exactly:

~~~text
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
~~~

This commitment is chain-independent evidence binding for the verified
authority invoice. Chain, shelf, economic funding terms, and calculated
advance remain in the separate receivable commitment.

Pin this document golden vector: authority ID <code>0xaaaa…aaaa</code> and
authority voucher type <code>19</code>; the
five hashes are respectively <code>0x11…11</code>,
<code>0x22…22</code>, <code>0x33…33</code>, <code>0x44…44</code>, and
<code>0x55…55</code> (32 bytes each); recourse is <code>true</code>. The
expected digest is
<code>0xc1d9671c9008465eb2b8c5d92de40dbaef60975ee33f9a9a6777cbdc4f3902bc</code>.

### Cross-chain boundary

The opaque authority ID is chain-independent, but a mapping in one shelf
deployment proves exactly-once only in that canonical origination domain. MVP
production must machine-pin exactly one chain, shelf, verifier, config, and
runtime codehash before activation. Enabling a second shelf or chain requires an
accepted global-nullifier registry or synchronous cross-chain consumption
protocol. This plan must not claim global exactly-once enforcement from a
per-chain mapping.

### Domain view consumed by loans

Create <code>IReceivableDomainView.sol</code> and have the shelf implement this
exact read boundary:

~~~solidity
interface IReceivableDomainView {
    struct FundingEvidence {
        uint16 schemaVersion;
        bytes32 verifierConfigId;
        bytes32 authorityInvoiceId;
        bytes32 authorityEvidenceCommitment;
        bytes32 receivableCommitment;
        bytes32 documentCommitment;
        bool consumed;
    }

    function fundingEvidence(uint256 invoiceId) external view returns (FundingEvidence memory);
    function invoiceIdOfAuthorityInvoiceId(bytes32 authorityInvoiceId) external view returns (uint256);
    function invoiceIdOfReceivableCommitment(bytes32 receivableCommitment) external view returns (uint256);
}
~~~

Plan 004 mirrors and selector-pins this interface. A provider router validates
the returned values; it never treats nonzero caller-supplied commitments as
proof.

### LOCK wire and shelf selector

The v1 LOCK action payload is load-bearing and must use this exact order and
types; no field may be appended, reordered, nested differently, or encoded
packed:

~~~solidity
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
~~~

The extractor decodes exactly:

~~~solidity
abi.decode(
    actionPayload,
    (
        address,
        uint256,
        uint256,
        uint128,
        uint8,
        uint64,
        uint32,
        ReceivableCommitment.FundingTerms,
        BINV.DocBundle
    )
)
~~~

The sole shelf function has canonical ABI signature:

~~~text
lockInvoice(uint256,uint256,uint128,uint8,uint64,uint32,((uint16,bytes32,bytes32,bytes32,uint8,uint64,uint64),bool),(bytes32,bytes32,bytes32,bytes32,bytes32))
selector: 0xb8a01dfd
~~~

The address token exists only in the signed extractor payload and must equal
<code>SHELF_TOKEN</code>; it is not repeated in the shelf call. Any future wire
change requires a new action/schema version and synchronized producer plan.

## Commands you will need

Run from the repository root.

<pre>
| Purpose | Command | Expected |
| --- | --- | --- |
| Reachable baseline | <code>git merge-base --is-ancestor 3b17523 HEAD</code> | exit 0 |
| Record execution base | <code>git rev-parse HEAD | tee "$(git rev-parse --git-dir)/plan-002-base"</code> | one commit SHA is recorded outside the worktree before edits |
| Local/production split | <code>f=components/fx-recibu/docs/RECEIVABLE_COMMITMENT_V1.md; test -f "$f" &amp;&amp; rg -q '^Status: Implemented$' "$f" &amp;&amp; rg -q '^Local conformance status: Complete$' "$f" &amp;&amp; rg -q '^Production enabled: false$' "$f" &amp;&amp; rg -q '^Authority source mode: OPAQUE_VERIFIER_OUTPUT$' "$f" &amp;&amp; rg -q '^Local verifier mode: DETERMINISTIC_STRICT_MOCK$' "$f" &amp;&amp; rg -q '^Official deployment entrypoint: DISABLED_REVERTS_BEFORE_ENV_OR_BROADCAST$' "$f" &amp;&amp; rg -q '^Production verifier configured: false$' "$f" &amp;&amp; rg -q '^Production origination domain configured: false$' "$f"</code> | local conformance is explicit and every production authority/deployment switch is false |
| Production gates documented | <code>f=components/fx-recibu/docs/RECEIVABLE_COMMITMENT_V1.md; rg -q '^## Production activation gates$' "$f" &amp;&amp; rg -q 'ARCA_AUTHORITY_IDENTITY_V1.md' "$f" &amp;&amp; rg -q 'PRF/ZK|nullifier' "$f" &amp;&amp; rg -qi 'verifier chain' "$f" &amp;&amp; rg -qi 'verifier address' "$f" &amp;&amp; rg -qi 'runtime codehash' "$f" &amp;&amp; rg -qi 'config' "$f" &amp;&amp; rg -qi 'one origination domain' "$f" &amp;&amp; rg -qi 'product.*legal.*security' "$f"</code> | the independent authority, review, verifier, and one-domain requirements remain explicit |
| Commitment discovery | <code>cd components/fx-recibu &amp;&amp; out="$(forge test --list)" &amp;&amp; printf '%s\n' "$out" | rg -q '^test/unit/ReceivableCommitment.t.sol$' &amp;&amp; printf '%s\n' "$out" | rg -q '^  ReceivableCommitmentTest$'</code> | exact path and test contract are discovered |
| Commitment tests | <code>cd components/fx-recibu &amp;&amp; forge test --match-contract ReceivableCommitmentTest -vv</code> | all schema/golden/selector tests pass |
| Shelf tests | <code>cd components/fx-recibu &amp;&amp; forge test --match-path test/unit/InvoiceShelf.t.sol -vv</code> | uniqueness and existing tests pass |
| Extractor tests | <code>cd components/fx-recibu &amp;&amp; forge test --match-path test/unit/FactoringSettlementExtractor.t.sol -vv</code> | replay and duplicate tests pass |
| Duplicate regression discovery | <code>cd components/fx-recibu &amp;&amp; forge test --list | rg -q '^    test_sameAuthorityDifferentOperationRejectedAndRetrySafe$'</code> | exact cross-operation duplicate regression is discovered |
| Exact disabled Deploy ABI | <code>cd components/fx-recibu &amp;&amp; forge inspect Deploy abi --json | jq -e '([.[] | select(.type == "function")]) as $f | ($f | length) == 1 and $f[0].name == "run" and ($f[0].inputs | length) == 0 and $f[0].stateMutability == "pure"'</code> | prints <code>true</code>; zero-input pure <code>run</code> is the only callable function, so no alternate <code>--sig</code> construction path exists |
| Deployment source guard | <code>f=components/fx-recibu/script/Deploy.s.sol; rg -Uq 'function run\(\) external pure returns \(Deployment memory\) \{\n[[:space:]]*revert ProductionActivationDisabled\(\);\n[[:space:]]*\}' "$f" &amp;&amp; ! rg -n 'vm\.(env[A-Za-z0-9_]*|startBroadcast|broadcast)\(' "$f"</code> | exact <code>run</code> body only reverts and no environment/private-key/broadcast cheatcode call remains |
| Deployment disabled test | <code>cd components/fx-recibu &amp;&amp; out="$(forge test --list)" &amp;&amp; printf '%s\n' "$out" | rg -q '^    test_runRevertsBeforeEnvironmentReadOrBroadcast$' &amp;&amp; forge test --match-test test_runRevertsBeforeEnvironmentReadOrBroadcast -vv</code> | exact test is discovered, then proves zero-input pure <code>run</code> contains only the typed disable revert |
| Mock isolation | <code>test -f components/fx-recibu/test/utils/StrictAuthorityInvoiceVerifier.sol &amp;&amp; ! rg -n 'StrictAuthorityInvoiceVerifier|StrictVerifierFactory|import .*test/' components/fx-recibu/src components/fx-recibu/script</code> | strict mock/factory exist only under <code>test/</code> and official source/script cannot select them |
| Verifier binding regressions | <code>cd components/fx-recibu &amp;&amp; out="$(forge test --list)" &amp;&amp; for n in test_constructorRejectsSelfConsistentSchemaTwo test_constructorRejectsSameCodeDifferentConfig test_lockRejectsPostConstructionVerifierConfigDrift test_lockRejectsPostConstructionVerifierSchemaDrift test_lockRejectsPostConstructionVerifierShelfDrift test_lockRejectsPostConstructionVerifierChainDrift test_lockRejectsPostConstructionVerifierRuntimeCodehashDrift; do printf '%s\n' "$out" | rg -q "^    ${n}$" || exit 1; done &amp;&amp; forge test --match-test 'test_(constructorRejects(SelfConsistentSchemaTwo|SameCodeDifferentConfig)|lockRejectsPostConstructionVerifier(Config|Schema|Shelf|Chain|RuntimeCodehash)Drift)' -vv</code> | schema 2 is rejected even when self-consistent, and all same-bytecode/storage plus post-construction tuple-drift regressions pass |
| Deploy tests | <code>cd components/fx-recibu &amp;&amp; forge test --match-path test/unit/Deploy.t.sol -vv</code> | disabled production entrypoint plus exact test-only verifier/shelf prediction and role wiring pass |
| Invariant discovery | <code>cd components/fx-recibu &amp;&amp; out="$(forge test --list)" &amp;&amp; printf '%s\n' "$out" | rg -q '^test/invariant/ShelfInvariants.t.sol$' &amp;&amp; printf '%s\n' "$out" | rg -q '^  ShelfInvariantsTest$' &amp;&amp; printf '%s\n' "$out" | rg -q '^    invariant_authorityCoverageIsNonVacuous$'</code> | exact invariant suite and non-vacuity witness are discovered |
| Invariant duplicate coverage | <code>f=components/fx-recibu/test/invariant/ShelfInvariants.t.sol; rg -q 'assertGt\([^;]*duplicateAttempts\(\), 0' "$f" &amp;&amp; rg -q 'assertEq\([^;]*duplicateSuccesses\(\), 0' "$f" &amp;&amp; rg -q 'assertEq\([^;]*duplicateGuardReverts\(\),[^;]*duplicateAttempts\(\)' "$f"</code> | at least one pre-approved duplicate is attempted, none succeeds, and every attempt reaches the exact duplicate guard |
| Invariant tests | <code>cd components/fx-recibu &amp;&amp; forge test --match-contract ShelfInvariantsTest -vv</code> | seeded success and authority uniqueness/permanence campaigns pass |
| Full component | <code>cd components/fx-recibu &amp;&amp; forge test</code> | all tests pass |
| Recursive checkout | <code>git submodule update --init --recursive &amp;&amp; test -z "$(git submodule status --recursive | sed -n '/^-/p')"</code> | every keyless recursive dependency is initialized; no status line begins with <code>-</code> |
| Aggregate | <code>./script/verify.sh</code> | all packages and Desk fixture pass |
| Scoped format/hygiene | <code>cd components/fx-recibu &amp;&amp; forge fmt --check src/interfaces/IAuthorityInvoiceVerifier.sol src/interfaces/IReceivableDomainView.sol src/libraries/ReceivableCommitment.sol src/invoice/InvoiceShelf.sol src/rails/FactoringSettlementExtractor.sol script/Deploy.s.sol test/utils/StrictAuthorityInvoiceVerifier.sol test/invariant/ShelfInvariants.t.sol test/unit/Deploy.t.sol test/unit/FactoringSettlementExtractor.t.sol test/unit/GuardHook.t.sol test/unit/InvoiceShelf.t.sol test/unit/OracleAndReserve.t.sol test/unit/Rails.t.sol test/unit/RecibuMemoRouter.t.sol test/unit/ReceivableCommitment.t.sol</code> then <code>git diff --check</code> | exit 0; unrelated legacy files do not block scoped conformance |
| No legacy lock | <code>rg -n 'lockInvoice\(' components/fx-recibu/src components/fx-recibu/test</code> | every call carries FundingTerms |
| Exact LOCK/shelf ABI | <code>cd components/fx-recibu &amp;&amp; sig='lockInvoice(uint256,uint256,uint128,uint8,uint64,uint32,((uint16,bytes32,bytes32,bytes32,uint8,uint64,uint64),bool),(bytes32,bytes32,bytes32,bytes32,bytes32))' &amp;&amp; forge inspect InvoiceShelf methodIdentifiers --json | jq -e --arg sig "$sig" '.[$sig] == "b8a01dfd" and ([to_entries[] | select(.key | startswith("lockInvoice("))] | length) == 1' &amp;&amp; forge test --list | rg -q '^    test_lockActionPayloadV1AndShelfSelector$'</code> | exact v1 action-payload regression is discovered and the sole shelf selector is <code>0xb8a01dfd</code> |
| Scope allowlist | <code>base="$(cat "$(git rev-parse --git-dir)/plan-002-base")"; changed="$({ git diff --name-only "$base"..HEAD; git diff --name-only; git diff --name-only --cached; git ls-files --others --exclude-standard; } | sort -u)"; unexpected="$(printf '%s\n' "$changed" | rg -v '^(EXECUTION_STATUS\.md|components/fx-recibu/(docs/(LEGAL_BOUNDARIES|RECEIVABLE_COMMITMENT_V1)\.md|src/(interfaces/(IAuthorityInvoiceVerifier|IReceivableDomainView)\.sol|libraries/ReceivableCommitment\.sol|invoice/InvoiceShelf\.sol|rails/FactoringSettlementExtractor\.sol)|script/Deploy\.s\.sol|test/(utils/StrictAuthorityInvoiceVerifier\.sol|invariant/ShelfInvariants\.t\.sol|unit/(Deploy|FactoringSettlementExtractor|GuardHook|InvoiceShelf|OracleAndReserve|Rails|RecibuMemoRouter|ReceivableCommitment)\.t\.sol)|plans/README\.md))$' || true)"; test -n "$changed" &amp;&amp; test -z "$unexpected"</code> | at least one change exists and every changed or untracked path is explicitly in scope |
</pre>

## Scope

Only these implementation/docs/test paths may change:

- <code>components/fx-recibu/docs/RECEIVABLE_COMMITMENT_V1.md</code> — create.
- <code>components/fx-recibu/docs/LEGAL_BOUNDARIES.md</code>.
- <code>components/fx-recibu/src/interfaces/IAuthorityInvoiceVerifier.sol</code> — create.
- <code>components/fx-recibu/src/interfaces/IReceivableDomainView.sol</code> — create.
- <code>components/fx-recibu/src/libraries/ReceivableCommitment.sol</code> — create.
- <code>components/fx-recibu/src/invoice/InvoiceShelf.sol</code>.
- <code>components/fx-recibu/src/rails/FactoringSettlementExtractor.sol</code>.
- <code>components/fx-recibu/script/Deploy.s.sol</code> — hard-disable
  broadcast/public deployment entrypoints and retain internal wiring helpers
  for the test-only harness.
- <code>components/fx-recibu/test/unit/ReceivableCommitment.t.sol</code> — create.
- <code>components/fx-recibu/test/utils/StrictAuthorityInvoiceVerifier.sol</code>
  — create the sole shared strict mock and its test-only drift hooks/factory
  helpers; production source and scripts may not import it.
- the eight live lock call-site test files listed under Current state, plus the
  two listed source call sites.
- <code>components/fx-recibu/plans/README.md</code> — update only Plan 002.
- <code>EXECUTION_STATUS.md</code> — update only Plan 002.

Out of scope:

- Raw ARCA tuple ingestion, credentials, CAE storage, Reclaim proof generation,
  production verifier implementation, or key material.
- <code>components/fx-recibu/docs/ARCA_AUTHORITY_IDENTITY_V1.md</code> remains
  owned under BU-318/BU-319 and must be independently approved. This executor may not create, edit,
  approve, or substitute for it; its absence blocks production activation,
  not the keyless consumer conformance suite.
- Desk/database, Motora, <code>chainlink-cre</code>, loans-provider, migration,
  or sibling source changes. The in-scope deployment-script edit must make
  live/broadcast construction impossible; only the test file exposes an
  internal harness.
- A legacy lock overload or fallback identity derived from a document,
  operation, shelf ID, CAE, or arbitrary caller salt.
- Changing <code>InvoiceLocked</code>; add separate typed events.
- Multi-chain origination before an accepted global-nullifier design.
- Live deployments, upgrades, role changes, RPCs, broadcasts, funding, or
  external writes.

## Git workflow

- Start only from a clean worktree; record the execution base with the command
  above. Do not require or manufacture a production authority deployment.
- Suggested branch:
  <code>codex/002-consume-authority-invoice-once</code>.
- Do not commit until Scope allowlist and every verification gate pass.
- Commit only explicit in-scope paths with
  <code>feat(recibu): consume verified authority invoices once</code>.
- Do not push, open/merge a PR, deploy, broadcast, or update Linear from this
  executor plan unless the operator separately authorizes that action.

## Steps

### Step 1: Record the production-disabled consumer contract

Create <code>docs/RECEIVABLE_COMMITMENT_V1.md</code> from the normative consumer
schema in this plan. It must begin with these exact machine-readable markers:

~~~text
Status: Proposed implementation
Local conformance status: In progress
Production enabled: false
Authority source mode: OPAQUE_VERIFIER_OUTPUT
Local verifier mode: DETERMINISTIC_STRICT_MOCK
Official deployment entrypoint: DISABLED_REVERTS_BEFORE_ENV_OR_BROADCAST
Production verifier configured: false
Production origination domain configured: false
~~~

The document must contain:

- local implementation status and explicit non-approval language
- Official ARCA basis
- Canonical raw tuple owner
- Opaque authority invoice ID
- Authority evidence commitment
- Verifier and key rotation
- Chain/domain-specific receivable commitment
- Full document-bundle commitment
- Permanent consumption
- Cross-chain limitation
- CRE LOCK encoding
- Explicit non-claims
- a <code>## Production activation gates</code> section that requires an
  independently Accepted <code>ARCA_AUTHORITY_IDENTITY_V1.md</code>, approved
  keyed-PRF/ZK/nullifier and rotation/revocation policy, product/legal/security
  evidence, one exact immutable verifier chain/address/runtime-codehash/config,
  one exact origination shelf/domain, a deployment manifest, and a production
  proof-provider configuration

Include the official sources above. Do not select, name, or imply a production
PRF algorithm, Reclaim provider, verifier deployment, chain, shelf, key,
address, codehash, or configuration. The local strict mock is test machinery,
not authority evidence. Synthetic IDs must be described as opaque fixtures,
never as privacy-safe derivations.

Start the new document at <code>Status: Proposed implementation</code> and keep
<code>Production enabled: false</code>. After the preliminary targeted gates
pass, Step 6 changes <code>Status</code> to <code>Implemented</code> and
<code>Local conformance status</code> to <code>Complete</code> before the final
full/aggregate/scope sequence. All four production markers stay false, so the
exact final bytes are covered without claiming live readiness.

**Verify**: before implementation, the eight proposed/in-progress/false mode
markers above occur exactly once. After Step 6, run Local/production split and
Production gates documented.

### Step 2: Implement the schema library and verifier interface

Create <code>ReceivableCommitment.sol</code> with fixed semantic domains,
version 1, <code>AuthorityRef</code>, receivable hashing, and full-bundle
hashing. Create the verifier interface.

Update <code>LEGAL_BOUNDARIES.md</code> so its table distinguishes the five
content hashes in <code>BINV.DocBundle</code> from the separately stored
<code>recourse</code> election. Do not delete the recourse requirement and do
not pretend a bool is a document hash. Change its existing “non-recourse is
offered” language to say non-recourse is designed but production-disabled in
v1 until differentiated pricing, insurance, recovery, and loss allocation are
implemented. The explicit election, computed rate, advance, and holdback must
be part of the receivable commitment.

Tests must include:

- a documented golden vector independently encoded in the test;
- every-field sensitivity;
- domain contract and chain sensitivity for the receivable commitment;
- chain independence of the opaque authority ID;
- every document field changing the document commitment; the four ancillary
  hashes change only that commitment, while <code>assignmentHash</code>
  deliberately changes both document and receivable commitments;
- CAE/document changes unable to create a new authority ID;
- no packed encoding.

**Verify**: run Commitment discovery, then Commitment tests. Both exit 0 and
the two exact golden digests match.

### Step 3: Permanently consume verified authority identity

Add persistent indices:

- <code>invoiceIdOfAuthorityInvoiceId</code>: authority invoice ID → first
  funded invoice ID;
- <code>authorityInvoiceIdOf</code>: invoice ID → authority invoice ID;
- <code>invoiceIdOfReceivableCommitment</code>: receivable commitment → first
  funded invoice ID;
- <code>receivableCommitmentOf</code>: invoice ID → receivable commitment;
- <code>documentCommitmentOf</code>: invoice ID → full document commitment;
- <code>authorityEvidenceCommitmentOf</code> and
  <code>verifierConfigIdOf</code>: invoice ID → verified evidence/config.
- <code>recourseOf</code> and <code>advanceRateBpsOf</code>: invoice ID → the
  explicit legal election and computed policy rate; advance/holdback remain in
  the canonical Invoice projection and are included in the commitment.

The shelf constructor receives an explicitly configured verifier. In local
tests this is the deterministic strict mock; no default or allow-all verifier
exists. The sole
<code>lockInvoice</code> accepts <code>FundingTerms</code> before
<code>DocBundle</code>.

The constructor appends the verifier immediately before admin:

~~~solidity
constructor(
    IERC20 usdc,
    IBUFIIdentityRegistry identity,
    IBUFIReputationRegistry reputation,
    WorkspaceTierRegistry tiers,
    IAuthorityInvoiceVerifier authorityVerifier,
    uint16 authorityVerifierSchemaVersion,
    bytes32 authorityVerifierConfigId,
    uint256 authorityVerifierChainId,
    bytes32 authorityVerifierCodehash,
    address admin
)
~~~

The lock argument is <code>ReceivableCommitment.FundingTerms calldata
terms</code> immediately before <code>BINV.DocBundle calldata docs</code>.

Hard-disable <code>script/Deploy.s.sol</code> for production while preserving
its internal role-wiring helpers:

- add typed error <code>ProductionActivationDisabled()</code>;
- remove the <code>Script</code> import and <code>is Script</code> inheritance;
  otherwise forge-std's inherited <code>IS_SCRIPT()</code> would create a
  second callable ABI function and weaken the exact-disabled-ABI gate;
- replace the current env/Arc/Morpho deployment notice with an explicit
  production-disabled local-conformance notice; do not retain instructions
  suggesting that a private key or current address list can activate it;
- <code>run()</code> must be zero-input <code>external pure</code> and its body
  must contain only <code>revert ProductionActivationDisabled();</code>;
- remove every <code>vm.env*</code>, <code>vm.startBroadcast</code>, and
  <code>vm.broadcast</code> call from the source script;
- remove every public/external <code>deploy(...)</code>,
  <code>deployLocal(...)</code>, or test convenience overload from the source
  script. Construction helpers may be <code>internal</code> only;
- do not read <code>AUTHORITY_INVOICE_VERIFIER</code>, a private key, or any
  deployment manifest in this local-conformance plan. A later production
  activation plan must add a manifest-verified entrypoint;
- <code>Deploy.t.sol</code> defines a test-only stack harness and uses the one
  shared strict verifier/factory utility below. No mock/harness is imported by
  <code>src/</code> or <code>script/</code>.

The shared <code>test/utils/StrictAuthorityInvoiceVerifier.sol</code> mock must
store schema, config, chain, shelf, revocation/approval state in ordinary test
storage rather than Solidity immutables. This intentionally gives differently
configured instances identical runtime bytecode and provides explicit
test-only drift setters. The shelf must still reject a wrong instance or any
post-construction drift because it pins and rechecks the complete expected
tuple, proving that codehash is not being mistaken for storage policy.

That utility file must also provide the one shared fixture construction
pattern used by every test that creates an <code>InvoiceShelf</code>:

- a fresh strict-verifier factory per shelf, so its first child CREATE nonce is
  always exactly <code>1</code>;
- a deterministic, namespaced CREATE2 salt derived from a monotonically
  increasing fixture counter (never an invoice/operation/document identity);
- a helper that accepts already deployed identity/reputation/tiers and admin,
  predicts verifier and shelf, deploys verifier first, deploys shelf second,
  asserts both predictions, and returns both instances;
- helpers for synthetic <code>FundingTerms</code> whose opaque authority IDs are
  explicit test inputs and never derived from shelf, operation, or document
  values.

Existing unit/invariant files must import this one utility rather than define
independent allow-all mocks or improvise different deployment orders.

The test-only deployment order must be exact and non-circular:

1. The test harness deploys identity, reputation, attestation, KYB policy, and
   tiers, so every shelf constructor dependency has a known address.
2. It deploys a dedicated test-only <code>StrictVerifierFactory</code> whose
   first child deployment uses CREATE nonce <code>1</code>.
3. It computes the future verifier address with
   <code>vm.computeCreateAddress(address(factory), 1)</code>.
4. It computes
   <code>expectedVerifierCodehash = keccak256(type(StrictAuthorityInvoiceVerifier).runtimeCode)</code>.
   Using that codehash, the predicted verifier, and every other known shelf
   constructor argument, it computes the exact shelf CREATE2 init-code
   hash/address for a fixed test-only salt.
5. The factory deploys the strict verifier, already bound to the predicted
   shelf, schema, config, and chain. The test asserts its actual address equals
   the prediction and its runtime codehash equals the precomputed codehash.
6. The harness deploys the shelf with the same CREATE2 salt and asserts its
   actual address equals the prediction before wiring roles.

Any additional factory deployment before step 5, a nonce other than 1, or an
address mismatch is a test failure. This recipe exists only under
<code>test/</code>; it is not a production deployment path.

The shelf stores immutable expected schema, config ID, chain ID, and runtime
codehash. Its constructor itself requires
<code>block.chainid == authorityVerifierChainId</code>, requires nonzero
verifier bytecode, checks
<code>address(authorityVerifier).codehash == authorityVerifierCodehash</code>,
requires a nonzero expected config, requires
<code>authorityVerifierSchemaVersion == ReceivableCommitment.VERSION</code>
exactly (v1 cannot be paired with a self-consistent schema 2 verifier), checks
<code>authorityVerifier.supportedSchemaVersion() == authorityVerifierSchemaVersion</code>,
checks
<code>authorityVerifier.verifierConfigId() == authorityVerifierConfigId</code>,
requires <code>authorityVerifier.approvedChainId() == block.chainid</code>, and
requires <code>authorityVerifier.approvedShelf() == address(this)</code>. The
verifier independently rejects <code>isVerified</code> calls from any other
caller, so a second shelf on the same chain cannot consume the same authority
ID in an independent registry. Matching a spoofable
<code>verifierConfigId()</code> alone is never a trust root. Production remains
disabled until the independent authority artifact's chain, address, runtime
codehash, config ID, shelf, and security approval all match an owner-reviewed
deployment manifest. The local mock tuple must never be copied into such a
manifest.

Immediately before every funding verification, the shelf must recheck the
verifier's runtime codehash, supported schema, config ID, approved chain, and
approved shelf against the immutable expected tuple. Runtime codehash alone
does not bind constructor-populated or mutable storage. A same-bytecode
verifier with different storage, or post-construction config/shelf/schema
drift, must fail before <code>isVerified</code>, consumption, exposure, minting,
or value movement.

Production v1 permits only an immutable, non-proxy verifier deployment. The
future accepted artifact must contain exact lines
<code>Verifier upgrade policy: IMMUTABLE_NON_PROXY</code> and
<code>Verifier admin: NONE</code>. A proxy, beacon, diamond, delegatecall-based
upgrade path, mutable implementation pointer, or nonempty upgrade admin is a
STOP even when the proxy runtime codehash matches. A future upgradeable
verifier requires an accepted implementation/admin/timelock policy and a new
schema/config version.

The EVM cannot generically prove from another contract's outer runtime
codehash that no proxy, delegatecall, beacon, diamond, or hidden upgrade path
exists. Production v1 therefore trusts only the one independently audited verifier
address/runtime-codehash tuple in the accepted artifact and deployment
manifest; the security evidence must establish the non-proxy/admin claims.
The constructor mechanically enforces address bytecode, codehash, chain, and
single-shelf binding, but it must not claim a generic onchain proxy detector.

The internal test harness necessarily receives a synthetic tuple and cannot
prove it came from an accepted artifact. It exists only in
<code>test/unit/Deploy.t.sol</code>; the source script exposes no deployment
helper and its <code>run()</code> fails closed. A later owner-reviewed production
plan must machine-compare the accepted artifact and deployment manifest before
adding any broadcast path. No broadcast or production-enable change is in
scope here.

Use these typed errors exactly:

- <code>UnsupportedAuthoritySchema(uint16 received, uint16 expected)</code>
- <code>UnsupportedAuthorityVoucherType(uint8 received)</code>
- <code>VerifierConfigMismatch(bytes32 received, bytes32 expected)</code>
- <code>VerifierDeploymentMismatch(address verifier, bytes32 receivedCodehash, bytes32 expectedCodehash)</code>
- <code>WrongVerifierChain(uint256 received, uint256 expected)</code>
- <code>VerifierShelfMismatch(address received, address expected)</code>
- <code>AuthorityInvoiceNotVerified(bytes32 authorityInvoiceId)</code>
- <code>AuthorityInvoiceAlreadyConsumed(bytes32 authorityInvoiceId, uint256 originalInvoiceId)</code>
- <code>ReceivableCommitmentAlreadyConsumed(bytes32 commitment, uint256 originalInvoiceId)</code>
- <code>InvalidAuthorityDates(uint64 issuedAt, uint64 authorityPaymentDueAt)</code>
- <code>MissingRequiredDocumentHash(uint8 fieldIndex)</code>
- <code>NonRecourseNotEnabled()</code>
- <code>UnknownFundingEvidence(uint256 invoiceId)</code>

For <code>MissingRequiredDocumentHash</code>, the stable v1 indices are exactly:
<code>0=invoiceDocHash</code>, <code>1=assignmentHash</code>,
<code>2=paymentInstructionHash</code>, <code>3=servicingPolicyHash</code>, and
<code>4=disputePolicyHash</code>. Every one of the five hashes is required and
must be nonzero. A domain-separated hash of an all-zero or partially zero
bundle is not valid legal evidence.

Validation order:

1. schema/config/required fields, exact voucher type <code>19</code>, all five
   nonzero document hashes, <code>recourse == true</code>, and the generic
   nonzero/ordered authority-date invariants;
2. verifier approval, including its config-bound authority-date/schedule
   policy;
3. duplicate authority ID and duplicate commitment checks;
4. all existing eligibility, exposure, reserve, tranche, and liquidity checks;
5. write the authority/commitment consumption records;
6. mint bINV and transfer the advance.

Writes occur before value leaves but after every precondition. Any downstream
revert rolls all writes back. Settlement, default, resolution, restructuring,
and burn never delete them.

Add this separate event without changing <code>InvoiceLocked</code>:

~~~solidity
event AuthorityInvoiceConsumed(
    bytes32 indexed authorityInvoiceId,
    bytes32 indexed receivableCommitment,
    uint256 indexed invoiceId,
    bytes32 authorityEvidenceCommitment,
    bytes32 documentCommitment,
    bytes32 verifierConfigId
);
~~~

Implement the exact <code>IReceivableDomainView</code> getters specified above.
For an unknown invoice, <code>fundingEvidence</code> must fail closed with a
typed error rather than return an all-zero record that a provider could
misinterpret.

**Verify**: Shelf tests exit 0; <code>forge build</code> compiles the disabled
Deploy surface and test-only wiring; Exact LOCK/shelf ABI passes.

### Step 4: Carry FundingTerms through CRE LOCK

Change the LOCK payload and interface in
<code>FactoringSettlementExtractor</code> so no path can lock without the
authority reference. Preserve target-chain, operation, expiry, token, workflow,
and current installment boundaries. Add
<code>test_lockActionPayloadV1AndShelfSelector</code>; it must independently
encode the exact LOCK tuple from “LOCK wire and shelf selector,” pass it
through the extractor, and assert the concrete shelf selector
<code>0xb8a01dfd</code>. It may not derive the expected selector from the live
interface under test.

Prove:

- operation A funds once;
- before operation B, the strict verifier explicitly approves B's complete
  verifier-call tuple (AuthorityRef, parties, currency, face, recourse, and
  schedule) under the same authority ID. Change operation ID and DocBundle
  separately; those fields are intentionally not verifier inputs and must not
  be added to its pinned ABI;
- use <code>vm.expectCall</code> for B's exact <code>isVerified</code> calldata,
  then require operation B to revert with the exact encoded
  <code>AuthorityInvoiceAlreadyConsumed(authorityInvoiceId, originalInvoiceId)</code>
  error. A generic verifier rejection does not satisfy this regression;
- operation B remains unprocessed after the shelf revert;
- no second bINV, advance, exposure, or consumption record exists;
- a verifier rejection consumes neither operation nor identity;
- corrected exact retry succeeds only if no earlier funding succeeded.

**Verify**: Extractor tests and Duplicate regression discovery both exit 0.

### Step 5: Update every fixture and invariants

Normal tests use deterministic, namespaced mock authority IDs that are
independent of shelf/operation counters. Explicit duplicate tests reuse one ID.
The invariant handler records funded IDs and proves the authority mapping is
injective and permanent. It must expose monotonically increasing
<code>lockAttempts</code>, <code>successfulLocks</code>,
<code>duplicateAttempts</code>, <code>duplicateGuardReverts</code>, and
<code>duplicateSuccesses</code> counters.
Increment <code>successfulLocks</code> only inside a successful unique-lock
<code>try</code> branch. In <code>setUp</code>, seed one valid strict-verifier
lock and then attempt the same authority ID again with a changed operation,
terms, and document bundle; increment <code>duplicateAttempts</code> before the
call, first configure the strict verifier to approve the complete changed
verifier-call tuple only, increment <code>duplicateSuccesses</code> only if it unexpectedly
succeeds, and increment <code>duplicateGuardReverts</code> only when caught
revert bytes equal the exact encoded
<code>AuthorityInvoiceAlreadyConsumed(authorityInvoiceId, originalInvoiceId)</code>.
Add
<code>invariant_authorityCoverageIsNonVacuous</code> that asserts
<code>successfulLocks &gt; 0</code>, <code>duplicateAttempts &gt; 0</code>, and
<code>duplicateSuccesses == 0</code>, and
<code>duplicateGuardReverts == duplicateAttempts</code>. The authority invariants must also assert
that the number of indexed funded IDs equals <code>successfulLocks</code> and
the original authority mapping never changes. Swallowing all reverts or never
trying a duplicate can no longer satisfy the suite.

Add regressions for:

- zero/unsupported schema and verifier config;
- constructor argument and verifier both reporting schema <code>2</code> must
  still revert with exact
  <code>UnsupportedAuthoritySchema(2, ReceivableCommitment.VERSION)</code>;
- voucher types <code>20</code>, <code>21</code>, zero, and arbitrary values
  cannot originate even when the strict mock would otherwise return true;
- one regression for each of the five zero document hashes, asserting exact
  <code>MissingRequiredDocumentHash(0..4)</code> errors and no state/value
  movement;
- <code>recourse == false</code> always reverts with
  <code>NonRecourseNotEnabled</code>, including for an otherwise
  non-recourse-eligible Strong/Strong pair;
- revoked or false verifier result;
- constructor rejection of identical verifier runtime bytecode whose stored
  schema/config differs from the immutable expected tuple;
- post-construction schema, config, shelf, chain, or runtime-codehash drift
  rejecting at lock before verifier approval or any state/value movement;
- constructor/deploy rejection of an EOA, wrong chain, wrong runtime codehash,
  and an allow-all substitute that reports the configured mock config ID;
- constructor/verifier rejection of a second shelf address; the future
  accepted artifact gate—not a generic Solidity proxy detector—owns the separate
  non-proxy/admin production decision;
- future issue date, invalid authority payment date, and rejected
  authority-date/schedule relationship;
- distinct authority ID success;
- duplicate after settlement and bINV burn;
- original authority/index mappings unchanged after settlement, default, and
  bINV burn;
- mint/transfer failure rollback;
- no legacy lock ABI.

**Verify**: Invariant discovery and Invariant tests exit 0; Full component
then proves every existing lock-caller compiles and passes. The command
<code>rg -n 'authorityInvoiceId.*(operationId|invoiceId|nextInvoiceId)|keccak256\(.*(operationId|invoiceId|nextInvoiceId)' components/fx-recibu/src components/fx-recibu/test</code>
must print only explicit negative-test assertions (or nothing), never a helper
that derives authority identity from operation/shelf/document data.

### Step 6: Run targeted and aggregate gates

Run Commitment, Shelf, Extractor, Exact disabled Deploy ABI, Deployment source
guard, Deployment disabled test, Mock isolation, Verifier binding regressions, Deploy, and both
Invariant discovery/coverage/tests first.
If any preliminary targeted gate fails, do not change status. After they pass,
change <code>components/fx-recibu/docs/RECEIVABLE_COMMITMENT_V1.md</code> to
<code>Status: Implemented</code> and
<code>Local conformance status: Complete</code> while keeping every production
marker false. Update only the Plan 002 plan-index row to
<code>COMPLETE — keyless local conformance; production authority gate remains</code>,
and set its executor-status cell to <code>Complete locally</code> before the
final full sequence.

Run this exact final-status assertion:

<code>f=components/fx-recibu/docs/RECEIVABLE_COMMITMENT_V1.md; rg -q '^Status: Implemented$' "$f" &amp;&amp; rg -q '^Local conformance status: Complete$' "$f" &amp;&amp; rg -q '^Production enabled: false$' "$f" &amp;&amp; rg -q '^Official deployment entrypoint: DISABLED_REVERTS_BEFORE_ENV_OR_BROADCAST$' "$f" &amp;&amp; rg -q '^Production verifier configured: false$' "$f" &amp;&amp; rg -q '^Production origination domain configured: false$' "$f" &amp;&amp; rg -q '002 .* COMPLETE — keyless local conformance; production authority gate remains' components/fx-recibu/plans/README.md &amp;&amp; rg -Fq '| fx-recibu | 002 verified authority nullifier + unique receivable | Complete locally |' EXECUTION_STATUS.md</code>

**Verify**: after the final-status assertion, rerun Commitment tests, Shelf
tests, Extractor tests, Duplicate regression discovery, Exact disabled Deploy
ABI, Deployment source guard, Deployment disabled test, Mock isolation, Verifier binding
regressions, Deploy tests, Invariant discovery, Invariant duplicate coverage,
Invariant tests, Local/production split, Production gates
documented, Full component, Recursive checkout, Aggregate, Scoped
format/hygiene, No legacy lock, Exact LOCK/shelf ABI, and Scope allowlist. All must
exit 0 in that order against the exact final status and implementation bytes.

## Test plan

- <code>ReceivableCommitment.t.sol</code>: schema, golden vectors, field
  sensitivity, separate document binding, privacy/non-derivation assertions.
- <code>InvoiceShelf.t.sol</code>: verifier, permanent single-use, dates,
  rollback, terminal-state persistence, distinct-ID success.
- <code>FactoringSettlementExtractor.t.sol</code>: operation replay versus
  receivable duplication and retry, with both complete call tuples pre-approved
  and the exact duplicate error plus verifier call asserted.
- Invariant suite: one authority ID maps to at most one funded invoice,
  consumption is never cleared, and a seeded successful lock plus the
  <code>successfulLocks</code> counter make the property non-vacuous.
- All existing lock fixtures compile with explicit valid authority refs.
- Full component and root aggregate gates pass.

## Done criteria

- [ ] The consumer ABI and single-use behavior are implemented against a
      deterministic strict mock; the document makes clear that this does not
      approve a PRF/ZK algorithm, verifier, proof provider, or deployment.
- [ ] No raw ARCA/PII/CAE data is stored onchain.
- [ ] The authority ID is stable and chain-independent; the receivable
      commitment is explicitly chain/domain bound.
- [ ] A strict <code>isVerified</code> result—not nonzero caller-supplied
      bytes or a config ID alone—gates funding.
- [ ] Verifier ABI, semantic-domain literals, schema version, and field order
      exactly match this plan; a future independent authority artifact must
      match them or version the integration instead of silently changing v1.
- [ ] Only voucher type 19 can originate; types 20/21 are adjustments to the
      original type-19 identity and never separately financeable nullifiers.
- [ ] All five legal document hashes are individually nonzero before funding.
- [ ] V1 permits recourse funding only; non-recourse remains production-disabled
      until differentiated pricing, insurance, and recovery are implemented.
- [ ] Authority ID, receivable commitment, and document commitment are
      separate and permanently indexed.
- [ ] The exact <code>IReceivableDomainView</code> exposes the stored evidence
      for Plan 004 and rejects unknown invoices.
- [ ] Same authority ID cannot fund twice even if terms, documents, operation
      ID, settlement, default, or burn differ.
- [ ] Failed funding rolls back consumption; successful funding never clears.
- [ ] The receivable commitment binds canonical grace and tranche as well as
      rate, advance, holdback, recourse, schedule, and assignment.
- [ ] Invariant coverage proves at least one successful strict-verifier lock;
      at least one duplicate is attempted; zero duplicates succeed; no empty
      funded-ID or duplicate-attempt set can satisfy uniqueness; every
      pre-approved duplicate fails with the exact duplicate-guard error rather
      than a verifier rejection.
- [ ] The CRE LOCK wire has no legacy bypass.
- [ ] <code>Deploy.run()</code> reverts before env/private-key/broadcast access,
      no public alternate deploy signature exists, and strict mocks/factories
      are isolated under <code>test/</code>.
- [ ] The constructor/deploy helper binds verifier chain, address, runtime
      codehash, schema, config ID, and shelf; every lock rechecks the immutable
      expected tuple; same-bytecode/different-storage and post-construction
      drift are rejected locally. Production matching to an accepted artifact
      remains a separate fail-closed activation gate.
- [ ] Cross-chain enforcement is not overstated; local conformance proves one
      shelf registry, and production remains disabled until one exact MVP
      origination domain is approved.
- [ ] Targeted, full, invariant, aggregate, format, and hygiene gates pass.
- [ ] No deployment, credential, external write, or sibling mutation occurs.

## STOP conditions

Stop and report if:

- Implementing the consumer would require selecting or implementing the
  production PRF/ZK nullifier, verifier, key rotation, revocation behavior,
  Reclaim provider, ARCA credential path, or raw-tuple canonicalizer.
- The fixed opaque consumer ABI cannot support a later product/legal-approved
  authority identity without exposing raw fields onchain.
- CAEA or WSFEX request ID is proposed as Factura E identity.
- A plain hash of enumerable raw tuple fields is proposed as privacy-safe.
- The verifier cannot fail closed or the shelf would trust arbitrary
  servicer-supplied bytes.
- Local integration would require a broadcast-reachable or public source
  deployment helper, a mock import in <code>src/</code>/<code>script/</code>, or
  a production activation flag.
- The verifier's schema/config/shelf/chain policy can mutate without the shelf
  detecting the change immediately before funding.
- Product enables more than one origination domain without a global-nullifier
  protocol.
- A legacy lock path must remain compatible with a live deployment.
- Any required legal document is legitimately optional and policy is
  unresolved.
- A test can pass only by using operation/document/shelf identity as the
  authority ID.
- Work requires Desk, Motora, Reclaim production, CRE, provider, live
  deployment, migration, RPC, or funding changes.
- A verification command fails twice after a reasonable correction.

## Maintenance notes

- V1 raw canonicalization stays in BU-318/BU-319; the shelf consumes only its
  opaque verified product.
- Never reinterpret v1 field order or domains. Use a new version and migration
  review.
- A contract migration must carry the permanent authority-nullifier registry
  or keep the old registry authoritative.
- Provider and CRE consumers use the stored receivable commitment verbatim;
  they must not reconstruct a weaker hash.
- Production rollout requires the accepted authority artifact plus a
  coordinated verifier, shelf, extractor, indexer, and role/deployment review.
