# fx-Recibú — Development Topology (local routes · GitHub origins · Linear)

> Verified 2026-07-01 against actual `git remote` state. Org is **BuFi007** (not "bufinance007").

## 1. Local routes (`~/coding-dojo/BUFI/`) and where each piece of fx-Recibú lives

| Local route | GitHub origin | fx-Recibú workstream | State |
|---|---|---|---|
| `fx-Recibu/` → **rename `fx-recibu/`** (kebab, match fx-telarana/fx-pasillo/fx-matcher) | **CREATE: `BuFi007/fx-recibu`** | The protocol repo: Foundry contracts (M1–M8), SPECs, docs, audits | specs only; **no git yet** — `git init` + first commit = next step |
| `desk-v1/` | `BuFi007/desk-v1` | Offer engine (acceptance event → offer service), `factoring_offer` multisig op kind, passport score v0.5 (motora+inbox features into the RPC), invoice StableFX prod-gate lift, compliance flag-ON | active (branch `private-multisig`) |
| `bufinance-publish/` | **CREATE: `BuFi007/bufinance-publish`** | Factoring `BuTool`s (`get_factoring_offer`, `accept_advance`) land in `intelligence/` → npm `@bufinance/intelligence`; payout UX via `ramps`/`ramps-ui`; KYB via `kyc-ui` | publishes to npm but **no git remote** — untracked source of truth for published code = risk, fix first |
| `bu-intelligence-agent/` | **CREATE: `BuFi007/bu-intelligence-agent`** (or `BuFi007/eve`) | Eve inherits factoring tools automatically; channel delivery (Discord/Slack/web) of the offer moment | active but **no git remote** — same risk, fix first |
| `fx-telarana/` | `BuFi007/fx-telarana` | Asset-loan market seeding + `WireRedstone…`-style ops scripts; adapt `KawaiiPower.sol` / `TournamentPrizePool.sol` (they live on this remote — `fx-telarana-tournament/` is a second clone of the same origin, branch-parked like `fx-onchain`) | active |
| `defi-web-app/` | `BuFi007/defi-web-app` | SDK `MarketKey` union += asset-loan markets; envio-yield indexing; fix `loan.tsx` SEED_MARKETS façade; protocol dashboard tiles | active |
| `fx-pasillo/` | `BuFi007/fx-pasillo` | Reuse UAFE audit queue+DLQ pattern for factoring events; StableFX RFQ leg for settlement conversion | active |
| `fx-matcher/` | `BuFi007/fx-matcher` | Invoice-FX conversion settlement reuse (`eip712.go`, `spot_executor.rs`) — later phase | active |
| `bufi-analytics/` | `BuFi007/bufi-analytics` | Emit `project:'recibu'` `BufiMetricsSnapshot` (advance volume, default rate, prize pool) | active |
| `b-in-bufi/` | `BuFi007/b-in-bufi` | Enterprise surface later (approvals UI is a stub today) | active |
| `BUFX/` | `BuFi007/BUFX` | Not on the critical path (stale; request/venue layer) | stale |

**Rule:** fx-Recibú protocol code never sprawls into sibling repos; sibling repos get *thin integration branches* named `feat/recibu-<workstream>` (e.g. `desk-v1` → `feat/recibu-offer-engine`, `defi-web-app` → `feat/recibu-market-registration`).

## 2. Repo-creation order (unblocks everything else)

1. `git init` + push **`BuFi007/fx-recibu`** (this directory; rename to lowercase first). License split per fx-telarana convention (Apache-2.0 contracts).
2. Push **`BuFi007/bufinance-publish`** — it is the *source of truth for code already live on npm* and currently untracked; provenance for `@bufinance/intelligence` v0.3.2 must be in git before factoring tools are added.
3. Push **`BuFi007/bu-intelligence-agent`** — same reason (Eve is running from untracked source).

## 3. Linear (team **BUFI**, key `BU` — per `BUFI-DEPLOYMENT-REGISTRY.md`)

- **New Linear project: “fx-Recibú — Invoice Factoring & Credit Passport”** added to the registry's project map (row 9), primary repo `BuFi007/fx-recibu`, deploy target = Arc Testnet 5042002.
- **Milestones = the ROADMAP gates, verbatim:** `M0 docs → M0.5 params → M1 identity → M2 tier → M3 invoice-core → M4 defaults → M5 rails → M6 vault → M7 v4-hook → M8 testnet`, parallel track `CP-1 score v0.5 → CP-2 offer+labels → CP-3 ML+mirroring`. One Linear milestone per gate; a gate's exit criteria (the `invariant_*` tests, the end-to-end dry-runs) become the milestone's issues.
- **Labels:** `repo:fx-recibu | repo:desk-v1 | repo:bufinance-publish | repo:eve | repo:defi-web-app | repo:fx-telarana | repo:fx-pasillo` for cross-repo work; `env:dev|staging|prod` (registry §Open-3 recommendation); `gate:blocking` for exit-gate issues; `precondition:8.3-N` for the eight Argentina launch preconditions (each is ONE issue that must close before mainnet).
- **Seed issues (first batch):** the 5 closure-plan items from `docs/BUCKET_ANALYSIS.md` + the 3 repo-creation items above + the 8 §8.3 preconditions.

## 4. The Eve / open-agents loop (agents working the backlog)

- **Executor:** desk-v1 `apps/open-agents` (background coding agents) + Eve's Linear MCP reach. An issue is **agent-executable** when it carries: the `repo:*` label, exact file paths, and grep-able acceptance criteria (the bucket-analysis criterion style — "binary, grep-able, drawn from spec language").
- **Convention:** tag agent-ready issues `agent:eve-ok`; issues touching money paths, §8.3 preconditions, or contracts additionally carry `gate:human-review` — **an agent may draft, only the multisig/human merges** (same dual-control law as `accept_advance`, applied to the development loop itself).
- **Feedback loop:** agent PRs reference the issue; the ROADMAP rule "a milestone is not done if its bucket score didn't move" is enforced by re-running `/bucket-analysis` at each gate and attaching the delta to the milestone.

## 5. Naming note

User-facing name: **fx-Recibú** (accented ú in prose/UI). Machine names: repo `fx-recibu`, npm scope stays `@bufinance/*`, Solidity prefix `Recibu` (e.g. `RecibuSettlementGuardHook`), Linear project prefix `[RECIBU]`.
