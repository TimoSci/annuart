# Zero-Knowledge Endowment NFT — Design Spec

**Date:** 2026-06-21
**Status:** Approved for planning
**Target platform:** Zama FHEVM (Solidity), local testing on Anvil via `forge-fhevm`, deployment on Sepolia testnet.

## 1. Summary

A single Solidity contract, `EndowmentNFT`, that behaves as an ERC-721 where each token represents a transferable **income stream** backed by a **secret endowment**.

- Each NFT holds an encrypted endowment of a confidential ERC-20 token. Its remaining balance is unknown to the NFT's owner (and to the public).
- A per-token **distribution account** accrues over time according to a creator-defined **piecewise-linear schedule**. The current owner can read (decrypt) the distribution account but not the endowment.
- Each accrual drains the endowment by the accrued amount, capped so it never goes below zero (`FHE.min`). When the endowment is exhausted, accrual silently stops growing the distribution.
- The owner claims the accrued distribution as a real confidential-token transfer to themselves.
- The endowment, distribution, schedule, and unclaimed balance all travel with the NFT on transfer.

The system is fully homomorphic end to end: **no decryption oracle is used in any on-chain path.** Owners decrypt their own distribution balance off-chain via the relayer SDK (user-decryption), authorized by the on-chain ACL.

## 2. Decisions (locked)

| Topic | Decision |
|---|---|
| Token / NFT model | ERC-721; one token = one endowment/income stream. |
| Value medium | Zama `ConfidentialFungibleToken` (encrypted-balance ERC-20), referenced by interface — pooled and escrowed by the contract. |
| Endowment visibility | Secret from everyone, including the owner. ACL grants the contract only — never the owner. |
| Distribution visibility | Owner-readable (ACL granted to current owner) but **not** plaintext on-chain. |
| Accrual function | Piecewise-linear schedule: segments of `{duration, ratePerSec}`. Integrated in plaintext over elapsed time, then capped by the encrypted endowment via `FHE.min`. |
| Accrual trigger | Lazy / pull. `accrue(tokenId)` is **public** (anyone may poke; harmless, no leak). |
| Claim | `claim(tokenId)` is **owner-only**, `nonReentrant`. |
| Transfer semantics | Everything (endowment + distribution + schedule + unclaimed) travels with the NFT. ACL re-granted to the new owner; old owner retains no read access to post-transfer values. |
| Mint access | Permissionless — anyone can fund and mint. |
| Creator control | Chosen at mint, one of two immutable modes: (1) **Immutable** — no changes ever; (2) **Top-ups allowed** — anyone may add encrypted funds via `topUp`. No pause, clawback, or schedule edits in either mode. |
| Amount type | `euint64` (max ~1.8×10¹⁹ base units). |
| Contract structure | Single pooled contract (ERC-721 + escrow + accrual engine). |
| Client tooling | TypeScript `@zama-fhe/relayer-sdk` for Sepolia; contracts + tests are pure Foundry. |

## 3. Privacy / trust model

- **Endowment secrecy** is enforced by never calling `FHE.allow(endowmentRemaining, owner)`. Only `FHE.allowThis` is ever applied to it. The owner has no ACL entry, so relayer user-decryption of that handle is rejected.
- **ACL is permanent and non-revocable** in FHEVM, but every FHE operation produces a *fresh ciphertext handle*. We exploit this: on transfer, the distribution handle is refreshed (`distribution = FHE.add(distribution, FHE.asEuint64(0))`) and `FHE.allow`'d to the new owner only — so the previous owner has no read access to any post-transfer value. (A previous owner may have decrypted the pre-transfer value while they held the token; that is inherent and acceptable.)
- **Whom the remaining balance is hidden from:**
  - Always hidden from: the public, and any owner who received the NFT by transfer.
  - In **Immutable** mode: the original creator knows the initial endowment (they encrypted it) and can compute remaining from the public schedule + elapsed time until exhaustion.
  - In **Top-ups allowed** mode: once third parties contribute amounts the creator did not choose, the remaining balance becomes hidden even from the original creator.
- **Exhaustion** is observable only retroactively and only to the owner: when the decrypted distribution stops tracking the public schedule, the owner infers the endowment ran dry. The public never learns whether an accrual was capped (the result is encrypted) — only the schedule's *maximum possible* accrual is public.

## 4. Architecture

A single contract `EndowmentNFT is ERC721, ReentrancyGuard`, depending on:

- `@fhevm/solidity` — the `FHE` library and encrypted types (`euint64`, `externalEuint64`), ACL primitives (`FHE.allow`, `FHE.allowThis`, `FHE.fromExternal`).
- OpenZeppelin Confidential Contracts — `ConfidentialFungibleToken` referenced via an `IConfidentialFungibleToken` interface (`confidentialTransfer`, `confidentialTransferFrom`).
- A `Schedule` library — pure plaintext piecewise-linear integration math.

The real tokens are pooled: the contract holds a single confidential-token balance and tracks each NFT's share via encrypted per-token state.

## 5. Per-token state

```solidity
struct Segment {
    uint64  duration;    // seconds this segment lasts
    uint64  ratePerSec;  // base units accrued per second during this segment
}

struct Endowment {
    euint64   endowmentRemaining; // SECRET — ACL: contract only
    euint64   distribution;       // owner-readable — ACL: contract + current owner
    uint64    lastAccrualAt;      // plaintext timestamp of last accrual
    uint64    scheduleStart;      // plaintext start time of the schedule
    bool      topUpsAllowed;      // mode flag, fixed at mint
    Segment[] schedule;           // piecewise-linear, plaintext
}

mapping(uint256 tokenId => Endowment) internal _endowments;
IConfidentialFungibleToken public immutable token;
uint256 internal _nextId;
```

**Per-token invariant** (verifiable in tests by decrypting all handles):
`endowmentRemaining + distribution + totalClaimed == initialEndowment + totalToppedUp`.

## 6. Core functions

### `mint(address to, externalEuint64 encEndowment, bytes calldata proof, Segment[] calldata segments, uint64 scheduleStart, bool topUpsAllowed) → uint256 tokenId`
1. `euint64 amount = FHE.fromExternal(encEndowment, proof)`.
2. Pull tokens: `euint64 received = token.confidentialTransferFrom(msg.sender, address(this), amount)`. **Set `endowmentRemaining = received`** (the actual transferred handle, never the requested `amount`) so under-funding cannot desync accounting.
3. `distribution = FHE.asEuint64(0)`; `lastAccrualAt = scheduleStart` (default `block.timestamp` if `scheduleStart == 0` and in the past is clamped to now at accrue time); store schedule + mode.
4. ACL: `FHE.allowThis(endowmentRemaining)`, `FHE.allowThis(distribution)`, `FHE.allow(distribution, to)`. **Never** allow `to` on the endowment.
5. `_safeMint(to, tokenId)`.

### `accrue(uint256 tokenId)` — public
1. Compute `owedPlain = Schedule.integrate(schedule, scheduleStart, lastAccrualAt, now)` (plaintext, clamped to schedule end, overflow-clamped to `type(uint64).max`).
2. If `owedPlain == 0` → return (no-op; also covers same-block / post-end calls).
3. `euint64 actual = FHE.min(FHE.asEuint64(owedPlain), endowmentRemaining)`.
4. `endowmentRemaining = FHE.sub(endowmentRemaining, actual)`; `distribution = FHE.add(distribution, actual)`.
5. Refresh ACL: `FHE.allowThis(endowmentRemaining)`, `FHE.allowThis(distribution)`, `FHE.allow(distribution, ownerOf(tokenId))`.
6. `lastAccrualAt = min(now, scheduleEnd)`.

No plaintext is revealed. Post-exhaustion, `FHE.min` yields 0 and the operation is a no-op in effect.

### `claim(uint256 tokenId)` — owner-only, `nonReentrant`
1. Require `msg.sender == ownerOf(tokenId)`.
2. `accrue(tokenId)` (internal call).
3. Checks-effects-interactions: `euint64 amt = distribution; distribution = FHE.asEuint64(0);` refresh ACL on the new zero handle (`allowThis` + `allow(owner)`).
4. `token.confidentialTransfer(msg.sender, amt)` — the confidential token grants the recipient ACL on the transferred amount internally.

### `topUp(uint256 tokenId, externalEuint64 encAmount, bytes calldata proof)` — public, reverts if `!topUpsAllowed`
1. `euint64 amount = FHE.fromExternal(encAmount, proof)`.
2. `euint64 received = token.confidentialTransferFrom(msg.sender, address(this), amount)`.
3. `endowmentRemaining = FHE.add(endowmentRemaining, received)`; `FHE.allowThis(endowmentRemaining)` (never allow any owner). The new total stays secret.

### Transfer hook (`_update`)
On owner change (mint and burn excluded as appropriate):
1. `accrue(tokenId)` to settle the clock under the prior state.
2. Refresh distribution handle and grant the new owner read access only: `distribution = FHE.add(distribution, FHE.asEuint64(0)); FHE.allowThis(distribution); FHE.allow(distribution, newOwner);`.
3. Endowment ACL remains contract-only.

## 7. Schedule library (plaintext)

`integrate(Segment[] schedule, uint64 scheduleStart, uint64 from, uint64 to) → uint64`:
- Walk segments accumulating `ratePerSec * overlap(segment_window, [from, to])`.
- Clamp `to` to `scheduleStart + Σ durations` (schedule end).
- Saturate the running total at `type(uint64).max` rather than overflowing.
- Pure and deterministic; the public can compute the maximum possible accrual, never the capped (actual) value.

## 8. Edge cases & error handling

- **Zero elapsed / same block / past schedule end** → `owedPlain == 0`, no-op.
- **Exhausted endowment** → `FHE.min` yields 0; distribution unchanged; no leak.
- **Under-funding at mint/top-up** → use the actual transferred handle, not the requested amount.
- **Reentrancy** → `claim` is `nonReentrant` and sets `distribution = 0` before the external transfer.
- **Amount range** → `euint64`; document the maximum representable amount relative to the token's decimals.
- **`topUp` on an immutable token** → revert.
- **Unauthorized claim** → revert (owner-only).
- **Schedule validation at mint** → reject empty schedule, zero-duration segments, and `Σ durations` overflow.

## 9. Testing

### Local — Foundry + `forge-fhevm` (Anvil, chain 31337, real host contracts, no mocks)
- **Schedule unit tests** (pure): integration across segment boundaries, clamping at end, overflow saturation; table + fuzz.
- **Accrual integration:** encrypt endowment input → mint → `vm.warp` → `accrue` → in-test decrypt distribution, assert `== min(scheduleOwed, endowment)`. Multi-warp sequences.
- **Exhaustion:** tiny endowment, warp far; assert distribution caps and `endowmentRemaining` reaches 0; further `accrue` is a no-op.
- **Transfer:** mint → accrue → transfer; assert new owner can decrypt distribution, prior owner's handle is stale (no ACL on post-transfer value), accrual continues, new owner can claim.
- **Claim:** assert contract confidential balance ↓, owner balance ↑ by distribution, distribution resets to 0.
- **Top-up mode:** top-up extends payout lifetime; assert total stays secret; assert `topUp` reverts in immutable mode.
- **Access control (headline):** assert the owner **cannot** user-decrypt `endowmentRemaining` (no ACL entry).
- **Invariant/fuzz:** random schedules + endowments + warp/claim/top-up sequences; decrypt all handles and assert `claimed + distribution + remaining == initial + toppedUp` and `distributionGrowth ≤ scheduleOwed`.

### Testnet — Sepolia
- Foundry deploy scripts for a `ConfidentialFungibleToken` (or reuse an existing one) and `EndowmentNFT`.
- TypeScript client (`@zama-fhe/relayer-sdk`): build the encrypted endowment input + proof, set operator/approval on the confidential token, `mint`. Use small real-time rates / short segments (no `vm.warp` on a live chain); poll `accrue`; user-decrypt distribution; `claim`; user-decrypt the resulting token balance.
- **Negative check:** attempt to user-decrypt the endowment handle → expect rejection (proves on-chain secrecy end to end).

## 10. Repository layout (proposed)

```
foundry.toml
remappings.txt
src/
  EndowmentNFT.sol
  interfaces/IConfidentialFungibleToken.sol
  libraries/Schedule.sol
test/
  Schedule.t.sol
  EndowmentNFT.t.sol          // forge-fhevm integration + invariant tests
script/
  Deploy.s.sol
client/                       // TypeScript relayer-sdk tooling for Sepolia
  package.json
  src/mint.ts | accrue.ts | claim.ts | decrypt.ts
lib/                          // forge deps: forge-fhevm, fhevm-solidity, oz-confidential
```

## 11. Out of scope (YAGNI)

Marketplace/royalties, multiple endowments per NFT, pause/clawback/editable schedules, non-linear (exponential) accrual curves, plaintext distribution accounts, decryption-oracle payout paths, cross-chain. Any of these can be a follow-up spec.
