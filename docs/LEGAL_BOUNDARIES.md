# fx-Recibú — Legal Boundaries (M0)

## The boundary

**fx-Recibú smart contracts do not create enforceable legal assignment of receivables.** Legal agreements — executed off-chain between seller, debtor (notice/acknowledgment where required), and the servicer entity — create the receivable assignment and collection rights. The contracts record and automate the on-chain state of receivables that have already been legally assigned: accounting, settlement, reputation, and tranche state.

A contract MUST NOT mark an invoice as legally assigned unless the authorized issuer/servicer has attested the required document hashes (enforced in `InvoiceShelf.lockInvoice` via the bINV doc-hash bundle).

## Required off-chain evidence per funded invoice

| Field | Content addressed |
|---|---|
| `invoiceDocHash` | canonical invoice PDF (desk-v1 `packages/invoice` format) |
| `assignmentHash` | executed receivables-assignment agreement |
| `paymentInstructionHash` | lockbox/payment redirection instruction to the debtor |
| `servicingPolicyHash` | servicing policy version in force |
| `disputePolicyHash` | dispute/default policy version in force |

These are the five content hashes in `BINV.DocBundle`. The separately stored
`recourse` boolean is an explicit legal/product election, not a document hash.
The receivable commitment binds that election together with the computed
advance rate, advance amount, holdback amount, schedule, canonical grace, and
tranche. Its separate document commitment binds the election to all five
content hashes.

## Recourse vs non-recourse

- **Recourse** (default; required when either party < Strong tier or no pair history — SPEC §3.3): on default the seller owes the outstanding advance back; enforced economically by inflow diversion + cross-default freeze + reputation.
- **Non-recourse**: designed for a future differentiated credit-default branch,
  but production-disabled in v1. It cannot be offered until differentiated
  pricing, insurance, recovery, and loss allocation are implemented and
  approved.
- **Fraud is always recourse** regardless of flag: a `PERMANENT_DEFAULT` attributable to fabricated invoices/acceptance voids non-recourse protection. `RestructureRouter` refuses to reclassify fraud.

## Servicer authority

The servicer (BUFI operating entity) holds: document attestation authority (issuer role), collection rights under the assignment, restructure proposal rights (executed only via ops multisig), and audit-trail duties (guaranteed-delivery log of every advance/installment/default event). The servicer does NOT hold: unilateral score writes bypassing the HSM path, exposure-limit overrides (L(w) is contract-enforced), or seizure of escrowed funds beyond the coded waterfall.

## Jurisdiction notes (Argentina v1)

v1 operates on contractual assignment without factura-electrónica integration; an AFIP/comprobante verification adapter is committed before ARS-corridor scale (SPEC §8.3.8). Points of counsel review before launch: enforceability of e-signed assignments, debtor-notice requirements, and the tax treatment of discount/fee income. This document is an engineering constraint map, not legal advice — counsel signs off, not this file.
