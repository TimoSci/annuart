# Private-rate ENFT: design

Date: 2026-11-16. Builds on `2026-06-21-zk-endowment-nft-design.md` (contracts),
`2026-11-11-annuart-web-design.md` (web app) and
`2026-11-13-automatic-payout-enft-design.md` (the second ENFT type).

Lines marked **(my call)** were decided by Claude, not by the owner, and are open to change.

## 1. Intent

On the existing ENFT types the payout schedule is public: every period's rate is stored in
plaintext. Anyone can therefore work out what a funded ENFT pays, and the encrypted claim
amounts hide nothing while the endowment lasts.

This adds a third ENFT type whose payout rate is encrypted. The schedule keeps a public
*shape* (how long each period lasts and how the periods compare with each other), and the
creator supplies one encrypted number, the **base rate**, that sets its size. The public
can see that period 2 pays twice what period 1 pays, but not what either pays.

## 2. Goals, non-goals, anti-goals

**Goals**

- A new contract, `PrivateRateEndowmentNFT`, deployed next to the existing ones.
- One encrypted base rate per ENFT, set at mint and never changed.
- Accrual, claim and transfer cost the same number of encrypted operations whatever the
  number of periods.
- The new type is one more option on the Create page. Its ENFTs appear in Browse, Mine,
  the ENFT page and Transactions like any other.
- Claim, donate (top-up), transfer, naming, the 256-period cap and the release of the
  leftover at the end of a fixed schedule behave as on `EndowmentNFT`.

**Non-goals**

- Changing the behaviour of `EndowmentNFT`, `AutoPayoutEndowmentNFT`, `ConfidentialWETH`
  or the `Schedule` library. The only edit to an existing Solidity file is the word
  `virtual` on two functions of `EndowmentNFT` (section 4.1).
- Automatic payouts on the new type. They publicly decrypt each payout, which would
  reveal the base rate.
- Hiding the shape: period lengths, relative weights, start and end stay public.
- An encrypted rate per period.
- Changing the base rate after mint.

**Anti-goals** (the feature has failed if any of these happens)

- The base rate, or any amount derived from it, reaches the server, a log or the socket.
- The app shows a weight as if it were a token amount.
- The app calls this type "fully private" without saying what stays public (section 3).
- An existing ENFT, or a create on an existing type, behaves differently after this lands.
- Someone who is not the owner can stop or shrink payouts by calling `accrue` often.

## 3. Privacy, stated plainly

| Fact | Who can learn it |
|---|---|
| Base rate | Creator, the owner at mint, and every later owner. Access cannot be taken back. |
| Each claim amount | The owner who claimed. |
| Endowment remaining | Nobody (unchanged). |
| Period lengths, weights, start, end | Everyone. |
| That an accrual, claim, donation or transfer happened, and when | Everyone. |

Three consequences the app and guides must state:

1. **One public amount reveals the rate.** If an owner converts a claim to ETH in a way
   that ties the public amount to that claim, anyone can divide by the elapsed weighted
   time and learn the base rate, and so every past and future payout while the endowment
   lasts. On the existing types this leak told the public nothing new; here it does.
2. **A past owner keeps the rate.** The value never changes, so a seller knows what the
   ENFT pays the buyer.
3. **The rate cannot be validated.** The contract cannot see it, so it cannot refuse a
   base rate of zero. On a schedule with an end, a zero rate pays nothing until the end
   and then releases everything. On a schedule with no end, the endowment is locked for
   good. The owner can check by revealing the rate; a donor cannot.

The existing advice in `guides/keeping-the-endowment-private.md` on funding and on
converting to ETH still applies to this type.

## 4. The contract

### 4.1 Shape

`src/PrivateRateEndowmentNFT.sol`: `contract PrivateRateEndowmentNFT is EndowmentNFT`,
over any `IERC7984` token. Inheriting was decided by the owner. Claim, top-up, naming,
the views and the transfer hook come from the base, so a fix there reaches this type too.

`EndowmentNFT` gets exactly two edits: `mint` and `_accrue` become `virtual`. Nothing else
in that file changes, and `AutoPayoutEndowmentNFT` is not edited.

Inheriting brings three obligations:

1. **The inherited `mint` is blocked.** It takes no base rate, so the override always
   reverts with `RateRequired`. A token minted through it would have no rate and, on a
   schedule with no end, a locked endowment.
2. **The rate is stored before the token is handed over** (section 4.3). The base mint
   routine ends by calling a recipient contract; that code must never run against a token
   whose rate is unset.
3. **Base changes reach this type.** In the base, a schedule's numbers are amounts; here
   they are weights and the rate is secret. `EndowmentNFT` gets a NatSpec note saying that
   a subclass reinterprets `ratePerSec`, so that later edits are checked against it.

`Schedule.sol` is unchanged. A `Segment`'s `ratePerSec` field holds the period's
**weight**. **(my call)** This keeps `scheduleOf` identical across the types, at the price
of a misleading field name; the contract's NatSpec must say so.

### 4.2 Fixed-point base rate

Token amounts have 9 decimals and rates are per second, so whole-number multiples would be
far too coarse. The base rate is therefore a fixed-point number:

- `UNIT_SHIFT = 32`. The encrypted `unit` is the payout per second, per one unit of
  weight, multiplied by 2^32.
- A period pays `unit * weight / 2^32` base units per second.
- `MAX_WEIGHT = type(uint32).max`. A larger weight reverts with `WeightTooLarge`.

Per-token state, in a mapping of its own beside the base contract's `_endowments`:

```solidity
struct Rate {
    euint128 unit;   // ACL: contract, creator, every owner so far
    euint128 carry;  // fraction left over from the last accrual, < 2^32. ACL: contract only
}
mapping(uint256 => Rate) internal _rates;
```

### 4.3 Mint

```solidity
function mintPrivate(
    address to,
    externalEuint64 encEndowment,
    externalEuint64 encUnit,
    bytes calldata inputProof,   // one proof covering both inputs
    Segment[] calldata segments, // ratePerSec = weight
    uint64 scheduleStart,
    bool topUpsAllowed,
    bytes32 name_
) external nonReentrant returns (uint256 tokenId);
```

A separate name, like `mintAuto`, so that callers never have to pick between overloads.
**(my call)** In this order:

1. An empty proof reverts with `EmptyInputProof` (it covers both inputs). Every weight is
   at most `MAX_WEIGHT`, else `WeightTooLarge`.
2. `unit = FHE.asEuint128(FHE.fromExternal(encUnit, inputProof))`, then `allowThis`,
   `allow(unit, msg.sender)` and `allow(unit, to)`. `carry` is an encrypted zero, allowed
   to the contract only. Both are stored under the id the token is about to get,
   `_nextId + 1`.
3. `_mintEndowment(...)` from the base does the rest: its own checks (including a
   non-zero weight on an indefinite last period, `ZeroRateIndefiniteSegment`), pulling
   the endowment, the `EndowmentMinted` event and the safe mint.
4. The id it returns must equal the id used in step 2, else revert. This cannot happen
   under `nonReentrant`; the check guards against a later change to the base.

If step 3 reverts, step 2 is undone with it.

`mint(...)`, inherited, is overridden to revert with `RateRequired`.

### 4.4 Accrual

`_accrue` is overridden; `accrue`, `claim` and the transfer hook in the base all reach it.

```
if settled: return
if now >= end: release the remainder exactly as EndowmentNFT does; carry is dropped
W = Schedule.integrate(schedule, start, lastAccrualAt, now)   // plaintext, saturating
if W == 0: return                                             // clock does not move
acc    = unit * uint128(W) + carry          // euint128; cannot overflow, see below
owed   = acc >> 32
carry  = acc & (2^32 - 1)
actual = asEuint64(min(owed, asEuint128(endowmentRemaining)))
endowmentRemaining -= actual
distribution       += actual
lastAccrualAt = now
```

- **No overflow:** `unit < 2^64` and `W < 2^64`, so the product and the carry fit in 128
  bits. `actual` is at most `endowmentRemaining`, so the cast back to 64 bits is exact.
- **The carry is what stops griefing.** Without it, each accrual would round down, and
  someone calling `accrue` every block could round a small rate down to nothing. With it,
  the total paid over any stretch of time is the same however often `accrue` is called,
  to within one base unit.
- **Encrypted operations per accrual:** one multiply, one add, one shift, one mask, two
  casts, one min, then the same subtract and add as today. All are in
  `@fhevm/solidity` 0.11.1. By the cost table in `@fhevm/host-contracts` `HCULimit.sol`
  they come to about 1.65 million computation units, against limits of 20 million per
  transaction and 5 million per chain of dependent operations. Section 9 still tests it.

### 4.5 The rest

- `claim`, `topUp`, `accrue`, the views and `_validName` are inherited unchanged.
- `_update` is overridden: it calls the base, and on a real transfer also does
  `FHE.allow(unit, to)`.
- New view: `unitHandle(tokenId) returns (euint128)`.
- No automatic-payout functions.

## 5. Deployment

- `scripts/deploy.ts` accepts `NFT_KIND=private` and writes `"nftKind": "private"` to the
  deployments file. The guard against reusing a non-WETH token applies as it does to the
  standard kind.
- Local: one private-rate contract over the mock token and one over cWETH, labels
  `private-mock` and `private`. **(my call)**
- Sepolia: the owner deploys, as always. The production-gating ACL check from the red-team
  report should be run for this contract too, with `unit` added to the handles checked.
- The keeper ignores this kind; it already filters on `nftKind === "auto"`.

## 6. Server

- `Annuart.Chain.Config`: `nft_kind` gains `:private`.
- ABI and indexer: the `mintPrivate` selector is indexed as a create. The schedule is read
  with the same `scheduleOf` call; for this kind the stored `rate_per_sec` is a weight.
- `Annuart.Schedule`: nothing that formats an amount may be given a private-rate schedule.
  Add weight-aware variants (share of base rate per period, summary text such as
  "3 periods, rate hidden") and make the amount functions unreachable for `:private`.
- The server never receives the base rate. There is no new event or assign carrying it.

## 7. Web app

**Create page**

- The token selector gains an option per private-rate contract, worded
  "`label` (`symbol`, private payout rate)".
- With that option chosen, the schedule editor changes: **(my call)**
  - one **Base payout** field, an amount per day, week, month or year. It is secret and
    is encrypted in the browser together with the endowment;
  - each period has a length and a **Percent of base** field, public, in steps of 0.1,
    default 100. Weight = percent × 10, so 100% is weight 1000;
  - the chart shows the shape only; the total line is computed in the browser and never
    sent.
- The creator does not type amounts per period for this type. Deriving weights from
  secret amounts would publish their exact ratios, and with awkward amounts the amounts
  themselves.
- `unit = floor(basePerSecond * 2^32 / 1000)`, computed in `units.js` with BigInt.
- Notes on the form: what stays public, and that a base payout of zero on a schedule
  with no end locks the endowment.
- The automatic-payout fields stay hidden for this type.

**ENFT page**

- Schedule panel: a "Share of base rate" column instead of amounts, and the same chart.
- A "Base rate" row showing hidden dots, with a Reveal control for the creator and the
  current owner. It uses the existing `SecretValue` hook with a new secret kind, decrypts
  in the browser and shows the amount per day at 100%.
- Remaining, donations, transfer and claim panels are unchanged. No automatic-payout
  panel.
- Donate note for a private-rate ENFT with no end: the donor cannot check that it pays
  anything.

**Elsewhere**

- Browse and Mine cards use the weight-aware summary.
- Transactions: creates on the new contract are listed as "Create ENFT", amount Private.
- `errors.js`: messages for `WeightTooLarge` and `RateRequired`.
- Guide page: the "Creating an ENFT" and "What is private and what is public" sections
  describe the third type, and "Keeping the endowment total private" gains the three
  consequences from section 3. `guides/keeping-the-endowment-private.md` and the README
  privacy model change with it.

## 8. Decided by the owner

- The single-multiplier design: public shape, one encrypted rate.
- The new contract inherits from `EndowmentNFT`.
- The existing ENFT types stay intact.
- The new type is an additional option in the web app.

## 9. Testing

**Foundry and Hardhat (in-process network only)**

- Mint stores the schedule, emits `EndowmentMinted`, pulls the endowment.
- Payout equals `unit * W >> 32` for one period, several periods, a zero-weight period and
  an indefinite last period; capped by the endowment; leftover released at a fixed end.
- Accruing every second for N seconds pays the same as one accrual after N seconds, to
  within one base unit.
- Largest inputs (`unit = 2^64 - 1`, weights at `MAX_WEIGHT`, a saturated `W`) do not
  revert and never pay more than the endowment.
- Reverts: empty proof, weight above `MAX_WEIGHT`, zero-weight indefinite period, and the
  errors shared with `EndowmentNFT`.
- The inherited `mint` reverts with `RateRequired` and mints nothing.
- A recipient contract that calls `accrue` from its receive callback during
  `mintPrivate`, on a schedule that started in the past, loses nothing: a later claim
  pays the same as for a plain recipient.
- `EndowmentNFT` and `AutoPayoutEndowmentNFT` behave as before: their existing suites
  pass with no test edited.
- ACL: creator, minted-to owner and a later owner can decrypt `unit`; a stranger cannot;
  nobody but the contract can decrypt `carry` or `endowmentRemaining`; a previous owner
  cannot decrypt the new owner's distribution.
- A unit of zero: nothing accrues; a fixed schedule still releases everything at the end.
- **Computation cost:** measure accrue, claim, top-up and transfer against the network's
  per-transaction limit. If any exceeds it, stop and report; the design then needs a
  64-bit variant with a bounded unit.

**Web**

- `units.js`: percent to weight, base payout to unit, rounding and bounds.
- Create form: fields switch with the chosen type; the base payout never appears in a
  pushed event.
- LiveView: private-rate ENFT page shows shares and no amounts; Reveal is offered to
  creator and owner only; cards use the weight summary.
- Local-chain test and one e2e flow: create, accrue, reveal rate, claim. These touch the
  owner's chain or start servers, so they are run only with the owner's say-so.

## 10. Left to the builder

- Whether the shared create logic in `actions.js` is branched or split.
- The exact wording of notes and labels, within the anti-goals.
- How the indexer distinguishes the kinds internally.
- Test file layout.
