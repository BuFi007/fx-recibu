# MemoConduit CCTP/CCTPx extension — unsigned development handoff

This extends the existing invoice/reimbursement `src/rails/MemoConduit.sol`, based on
`BuFi007/fx-recibu` main `7330e6cc31bf83ad60f1adb10ad10ae7bc96dad1`. Worktree:
`fx-recibu-memo-cctp-20261014`, branch `codex/memo-cctp-20261014`. It adds typed bridge
entry points to that same contract; it is not a second route around Treasury policy.
No deployment, registry change, real authorization or payment was performed.

## Preserved authorization and accounting

- `MemoConduit(IAddressBook,address[])`, `payWithMemo` and its nonce vector remain
  compatible. The original 17 tests pass. The source token set stays fixed at deploy;
  there is no owner, admin, arbitrary-call executor, setter, rescue or withdrawal.
- Treasury signs its token's own **ERC-3009 ReceiveWithAuthorization to MemoConduit**,
  using the bytes-signature ERC-1271 path. Circle's real Treasury account must validate
  its required quorum. The relayer never substitutes its signature for that quorum.
- The final recipient must still appear in the payer's **live** AddressBook. Missing,
  unavailable or revoked authorization fails before the source debit. The Treasury
  must not call TokenMessenger/CCTS directly or remove/change the AddressBook plugin.
- The bridge nonce binds source chain/conduit/protocol/service/token/payer, exact
  principal, destination chain/domain/token/recipient, zero token fee and standard
  finality, authorization window, original source leg, document/terms, memo and the
  exact CCTPx signed-quote hash/native fee/expiry. Signature changes are required for
  any alteration. There is no swap or implicit USD/EUR/BTC conversion.
- The source transaction checks exact Treasury debit, exact conduit credit, exact
  token supply reduction, exact remaining conduit balance and cleared allowance. It
  retains pre-existing token donations. CCTPx additionally retains its pre-existing
  native balance and attaches **exactly** the signed native fee to the canonical CCTS.
- A successful bridge records `bridgePaymentCommitment(from,memoId)`. Replays, new
  source legs, fresh windows and parallel submissions cannot burn that document again.
  A failed EVM transaction rolls back the nonce, commitment, approval and debit, so
  recovery can resume the **same** original attempt after proving the failure.
- New-instance legacy/bridge overlap is rejected both ways: successful legacy payment
  stores `memoPaymentCommitment`; bridge refuses it. Legacy `payWithMemo` refuses a
  previously dispatched bridge. Legacy replay retains the token's original nonce check.

**Important migration boundary:** these mappings are per deployed contract. Old
MemoConduit authorizations remain valid against the old address. BUFI must retain its
global document reservation and reconcile outstanding legacy approvals, unknown
submissions and old receipts before preparing any bridge on a new deployment. This
source change cannot revoke a signature already given to another deployed contract.

## Exact reviewed sandbox capabilities

| Protocol | Asset | Reviewed source/destination pairs | Principal precision |
| --- | --- | --- | --- |
| CCTP v2 `depositForBurn` | USDC | Base Sepolia, Avalanche Fuji, Arc Testnet, distinct chains | 6 |
| CCTPx `crossChainTransfer` | EURC | Ethereum Sepolia, Base Sepolia, Avalanche Fuji, Arc Testnet, distinct chains | 6 |
| CCTPx `crossChainTransfer` | cirBTC | Ethereum Sepolia ↔ Arc Testnet only | 8 |

The code refuses production, same-chain requests, other token addresses, wrong
destination tokens/domains and cirBTC on Base/Fuji. `supportedToken` must include the
exact source asset in the constructor. Constructor token membership alone never
establishes bridge capability. A future chain or protocol requires a reviewed source
change; no runtime flag, native token presence or caller-provided service adds one.

USDC uses canonical TokenMessengerV2 `0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA`
and TokenMinterV2 `0xb43db544E2c27092c107639Ad201b3dEfAbcF192`. Each source execution
checks the local minter, remote messenger and asset burn limit before debit. It allows
standard finality `2000`, maxFee `0`, no forwarding hook and permissionless destination
caller. A fresh independent standard-fee check remains required in BUFI; if the route
develops a nonzero minimum burn fee, the on-chain zero-maxFee call must fail closed.

CCTPx uses canonical CCTS `0x63753E722bd2C2A5DF6EE19C5106662208B81077` and separate
EURC/cirBTC token IDs/managers. It checks unpaused service, trusted destination domain,
exact registered TokenManager, BURN_MINT type `1`, actual token/service and asset
precision. Approval goes to the **TokenManager**, never CCTS. Its call uses a packed
**20-byte** EVM recipient, caller zero, standard finality `2000`, `autoExecuteHookData`
**false** and empty hook data. It permits no post-mint arbitrary execution.

CCTPx FeeManager's public decoder is used before debit to require exactly one
`FORWARD` and one `PROTOCOL` item, native fee token zero and item sum equal to
`payment.nativeFee == msg.value`. Timestamp/block expiry packing is checked:
high byte `0` = timestamp, `1` = block number; lower 248 bits = actual deadline.
Timestamp `quoteValidUntil` must equal the actual timestamp deadline. For block mode,
`quoteValidUntil` is an additional signed conservative time bound and cannot extend
the actual block deadline. The opaque version-1 quote bytes are forwarded unchanged;
**decoding does not authenticate the quote**. CCTS/FeeManager subsequently validate
Circle's signature and the exact quote arguments in the same atomic transaction.
Refund attribution is fixed to `payment.from`, not a caller-supplied wallet. Gas Station
sponsorship is distinct from funding this native call value; validate relayer balances,
call-value policy and budgets independently before activation.

Official references, with read-only registry/contract observations on 2026-10-14:
[Bridge Kit bridge](https://docs.arc.io/app-kit/bridge),
[Circle CCTPx](https://developers.circle.com/cctpx),
[CCTP token messenger](https://developers.circle.com/cctp/evm-smart-contracts).
Verified source used for quote/type semantics is Circle's CCTS implementation and
`IFeeManager`, `FeeUtils`, `TransferDelegate`, `TokenManager` dependencies; the installed
`@circle-fin/provider-cctpx` action types describe the same nine-argument payable API.
Public registry availability and bytes-signature selectors do not prove a real
Treasury signature or application settlement. Those tests remain outstanding.

## Stable ABI and receipt boundary

`BridgePayment` field order:

```text
uint8 protocol
address token
address from
address recipient
uint256 amount
uint256 destinationChainId
uint32 destinationDomain
address destinationToken
uint256 maxFee
uint32 minFinalityThreshold
uint256 validAfter
uint256 validBefore
bytes32 paymentId
bytes32 termsHash
bytes32 memoId
bytes memo
bytes32 tokenId
bytes32 quoteHash
uint256 nativeFee
uint256 quoteValidUntil
```

Read `bridgeRouteOf`, `bridgeTokenIdOf`, `bridgeTokenManagerOf`, and
`bridgePaymentNonceOf` from the **actual verified extension deployment** before
reviewing signatures. USDC CCTP requires the final four CCTPx fields to be zero.
`bridgeWithMemo(payment,quorumSignature)` is nonpayable USDC only;
`bridgeWithMemoCctpX(payment,signedQuote,quorumSignature)` is payable EURC/cirBTC only.

Source event (not a payment-completion event):

```solidity
MemoConduitSourceBurn(
  bytes32 indexed memoId, address indexed from, address indexed recipient,
  bytes32 paymentId, bytes32 termsHash, bytes32 nonce, address token,
  uint256 amount, uint256 destinationChainId, uint32 destinationDomain,
  address destinationToken, bytes memo
)
```

Do not mark Paid or issue a settlement Recibo from that event. Match the original
document reservation, decoded call, original source transaction/message and event,
then independently verify the final destination mint/recipient/asset/principal. CCTPx
has its own transfer payload and must not use the USDC fixed 376-byte body verifier.
The source depositor is MemoConduit; the actual debit is Treasury → MemoConduit, and
the actual burn is through the canonical minter/asset-specific TokenManager. Neither
receipt decoder may assume Treasury → zero is the burn log.

Shared USDC nonce golden vector is pinned in Solidity and Desk's nonce mirror:
`0x98f69b2a774d1f69846d5fe22493fa17f2fb33c1917ea9546e25739400047163`.

## Validation and activation gates

From this worktree, use the already installed libraries without installation:

```sh
/Users/criptopoeta/.foundry/bin/forge test --offline \
  --lib-paths '../fx-recibu-production/lib' \
  -R '@openzeppelin/contracts/=../fx-recibu-production/lib/openzeppelin-contracts/contracts/' \
  -R 'forge-std/=../fx-recibu-production/lib/forge-std/src/' \
  --match-path 'test/unit/*MemoConduit*.t.sol' --fuzz-runs 1024
```

The tests cover the original local rail, two-signature ERC-1271 quorum, malicious
recipient/spender/domain/token/amount/terms/memo/window/quote changes, revoked and
unavailable allowlist, retired minter/manager/domain, malformed/expired native quote,
false lock/burn, exact six/eight-decimal amounts, reentrancy, uncertain replay,
rollback and same-instance legacy/bridge duplication. Unit signatures use synthetic
Foundry accounts; no wallet or live provider is called.

Recorded final run: **64 tests pass**, including 17 original local-rail tests and
five existing deployment-script compatibility tests; **3,072 fuzz cases** across
USDC, EURC and eight-decimal cirBTC. `forge fmt --check` and `git diff --check` pass.
Compiled deployed bytecode is 13,587 bytes; this is a local artifact, not deployed
codehash evidence or an external security audit.

Before any application activation: external contract review, human-authorized testnet
deployment, exact code/chain/runtime getters and bytecode provenance, deployment
registry updates by the owning task, signer display of the immutable summary, durable
original-leg reservations and recovery, native fee funding, real Treasury quorum
exercise and independent USDC **and CCTPx** destination receipts. Then test Paid/Recibo,
reload, repeated callbacks and expired/uncertain submissions from the public page.
The old direct Treasury TokenMessenger/CCTS route must remain blocked throughout.

Coinflow contract settlement requires its own sandbox program/contract approval and
immutable provider funding identity. This Treasury extension does not manufacture
Coinflow approval or use a Treasury authorization for a card-funded purchase.
Console inspection for this task showed no active sandbox program requests and a
Base contract approval request option. Those observations do not establish that
settlement-to-contracts is enabled or that this new funding/bridge contract is
approved. Obtain the merchant's actual sandbox approval and a verified deployment
before replacing its current direct Base checkout. CCTPx native call-value funding
and the source relayer's budget remain separate requirements from Gas Station.
