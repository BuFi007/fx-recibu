# fx-Recibú — License Boundaries (M0)

| Source | License | Rule |
|---|---|---|
| OpenZeppelin v5 (`lib/openzeppelin-contracts`) | MIT | Import freely; attribution header on any *adapted* (copied-modified) file |
| forge-std | MIT/Apache-2.0 | test-only dependency |
| Circle `recibo` / `refund-protocol` | Apache-2.0 | May adapt WITH attribution header naming file + upstream repo; ReceivableEscrow must NOT copy refund-protocol blindly (known early-withdrawal/arbiter-custody risk — redesign + invariant tests required) |
| ERC-8004 reference contracts | MIT | Concepts adapted; our registries are clean-room implementations (no upstream submodule vendored) — attribution note in file headers where design follows the ERC |
| Morpho Blue | GPL-2.0 | **Interfaces only** — we declare minimal interfaces (`IOracle.price()`, market structs) by hand; NEVER copy internals into `src/` |
| Tinlake, Huma, Request Network | AGPL-3.0 / mixed | **Browser-only reference.** Never opened inside this workspace, never copied. `InvoiceShelf` is Tinlake-*inspired* (single-shelf custody pattern) as design lineage only |
| This repo (`src/`, `script/`) | Apache-2.0 | SPDX header on every file (fx-telarana convention: Apache-2.0 for contracts) |

Enforcement: every file in `src/` carries `// SPDX-License-Identifier: Apache-2.0`; any adapted file carries a `/// @dev Adapted from <repo> (<license>)` header; CI grep gate can verify both.
