# Automatic-payout ENFT: design

Date: 2026-11-13. Builds on `2026-06-21-zk-endowment-nft-design.md` (contracts) and
`2026-11-11-annuart-web-design.md` (web app).

Lines marked **(my call)** were decided by Claude, not by the owner, and are open to change.

## 1. Intent

An ENFT owner today has to visit the app and approve several wallet prompts to turn a payout
into ETH. A non-technical owner, for example someone who was given an ENFT, may never do
that. This adds a second ENFT type whose payouts can be triggered by **anyone**, and which
pays the owner in plain ETH, so the owner needs no wallet interaction and no ETH for gas.

"Automatic" means someone else sends the transactions. A contract cannot act on its own.

## 2. Goals, non-goals, anti-goals

**Goals**

- A new contract type, deployed next to the existing one. The existing `EndowmentNFT`
  keeps its behaviour and its place in the app.
- Per ENFT, three settings the current owner can change at any time:
  - automatic payouts on or off;
  - the minimum interval between automatic payouts, default **1 day**;
  - a fee paid to whoever triggers a payout, default **0**. The fee actually paid is never
    more than 10% of the payout.
- With the fee at zero, the person triggering pays all transaction fees and the owner
  receives the whole payout.
- The owner's ordinary `Claim` (private, paid in cWETH) still works on the new type.

**Non-goals**

- Changing or migrating ENFTs minted on the existing contracts.
- Tokens other than wrapped ETH. The new type exists only over `ConfidentialWETH`.
- A fee that follows gas prices.
- Running a payout bot inside the Phoenix server.

**Anti-goals** (the feature has failed if any of these happens)

- An ENFT with automatic payouts off is any less private than an ENFT of the existing type.
- A payout can be blocked, redirected or taken by someone other than the owner it was
  requested for (apart from the fee the owner set).
- The remaining endowment becomes readable while payouts still match the schedule.
- The server holds a private key, or Claude sends a Sepolia transaction.

## 3. Privacy cost, stated plainly

Unwrapping reveals the amount. So for an ENFT with automatic payouts on:

- every automatic payout amount is public, with its time;
- while payouts equal the scheduled amount, the remaining endowment stays hidden;
- the first payout that falls short shows the endowment has run out. Because the schedule
  is public, that also reveals in hindsight everything the ENFT ever held: the original
  endowment plus all donations up to then;
- after it has run out, each later payout is whatever was donated in between, so those
  donation amounts become public too;
- when a fixed schedule ends, the leftover is released to the owner and the next automatic
  payout reveals it.

The UI says this wherever the setting is turned on (section 7). Automatic payout amounts
are public chain data, so the server may index and show them. This is a deliberate
exception to "no plaintext amount reaches the server"; that rule continues to hold for
endowments, claimable balances, token balances and manual claims.

## 4. The contract

### 4.1 Shape

`AutoPayoutEndowmentNFT` extends `EndowmentNFT` and adds the functions below. Its token
must be an ERC-7984 wrapper whose underlying token is WETH; the constructor takes the
wrapper and reads `underlying()` and `rate()` from it. `EndowmentNFT` may get
behaviour-preserving changes (for example `virtual`, or an internal helper shared by
`claim` and the payout request) so the new contract can reuse it. It is not deployed on
Sepolia yet, so this costs nothing.

There are no admin functions and no owner-of-contract role.

### 4.2 Settings

Per token id:

| Setting | Type | Default | Bounds |
|---|---|---|---|
| `enabled` | bool | set at mint | |
| `interval` | seconds | 86 400 (1 day) | 1 hour to 365 days **(my call)** |
| `fee` | wei of ETH | 0 | any value; capped at 10% of each payout when paid |

- `mint(...)` keeps the existing signature and mints with automatic payouts **off**, interval
  1 day, fee 0.
- A second mint function takes the three settings as well. This lets a creator give an
  ENFT that already pays out automatically.
- `setAutoPayout(tokenId, enabled, interval, fee)`: current owner only; sets all three.
- **On transfer to a new owner, `enabled` is reset to off**; interval and fee are kept.
  A new owner never inherits public payouts they did not choose. **(my call)**
- The reset applies to every transfer between two different addresses, including one made
  by an approved operator. A transfer to oneself changes nothing. **(my call)**
- Every change, including the reset and the settings given at mint, emits
  `AutoPayoutSet(tokenId, enabled, interval, fee)`, so the indexer needs no extra read.

### 4.3 A payout is two transactions

**`requestPayout(tokenId)`**, callable by anyone. It reverts unless all of these hold:

- automatic payouts are enabled for the token;
- no payout is pending for the token (one at a time);
- `interval` seconds have passed since the previous request (the first request is allowed
  at once);
- the schedule has started;
- no automatic payout has been requested at or after the schedule's end. That request
  settles the ENFT and takes the leftover; nothing can accrue afterwards, so further
  requests would only waste the caller's gas.

`requestPayout` also takes a `minFee`, and reverts if the ENFT's fee is lower, so an owner
cannot lower the fee just ahead of a caller's transaction. **(my call)**

It then accrues, takes the whole claimable balance as `claim` does (the emptied balance
stays readable by the owner, not by the caller), and asks the wrapper to unwrap it from
the contract's own balance to the contract. It records a pending
payout: the unwrap request id, the **owner at this moment** as recipient, the caller as
requester, and the **fee as set at this moment**. Emits
`PayoutRequested(tokenId, requestId, recipient, requester, fee)`.

Snapshotting the recipient and fee means neither a transfer nor a settings change between
the two transactions can redirect the payout or cheat the requester. **(my call)**

**`finalizePayout(tokenId, cleartextAmount, decryptionProof)`**, callable by anyone, once
Zama's network has decrypted the amount.

- The contract verifies the decryption proof itself against the request id. It must not
  rely on being the one to call the wrapper's `finalizeUnwrap`: that function is open to
  anyone, so a third party can finalise the unwrap directly. If the unwrap request is still
  open the contract finalises it; if someone already did, the WETH is already here.
- It converts `cleartextAmount × rate` of WETH to ETH and pays:
  - `min(fee, amount / 10)` to the requester;
  - the rest to the recipient.

  The 10% cap is the owner's decision. Whatever fee is set, at mint or later, the
  recipient always receives at least 90% of every payout.
- It clears the pending payout before paying, and is non-reentrant.
- Emits `PayoutPaid(tokenId, requestId, amountWei, feeWei, paidInWeth)`.
- A zero amount pays nothing and no fee, and still clears the pending payout.

The whole fee goes to the **requester**, not to whoever finalises. Otherwise someone could
wait for others to pay for the request and collect the fee with the second transaction.
The requester has every reason to finalise; if they do not, anyone can, at their own cost.
**(my call)**

**Payment failures.** ETH is sent with a gas limit of 100 000 **(my call)**, so a recipient
contract cannot make the finaliser's transaction run out of gas.

- If paying the recipient fails, their share is paid in WETH instead (`paidInWeth = true`).
- If paying the requester fails, the fee goes to the recipient.

The contract accepts plain ETH only from the WETH contract.

### 4.4 Reads

- `autoPayoutOf(tokenId)`: enabled, interval, fee, time of the last request.
- `pendingPayoutOf(tokenId)`: request id (zero when none), recipient, requester, fee.
- `payoutDue(tokenId)`: whether `requestPayout` would be accepted now.

### 4.5 What a caller risks

The amount is encrypted until the second transaction. A caller cannot know whether it
covers the fee, or whether it is zero because the endowment ran dry or the owner claimed
just before. That risk is the caller's. With a zero fee the caller is paying out of goodwill anyway.

## 5. Deployment

- `deployments/<network>.json` entries gain `"nftKind"`: `"auto"` for the new type; absent
  means the existing type.
- `scripts/deploy.ts` gains `NFT_KIND=auto`. It requires the wrapped token and, by default,
  **reuses the token of the file's `wrapped` entry**, so both types share one cWETH and a
  user has one cWETH balance. If there is no entry labelled `wrapped`, it stops and asks for
  `TOKEN_ADDRESS`. The new entry's `tokenKind` is `"wrapped"`, so everything that already
  works for wrapped ETH (unwrap, claim and convert) applies to it. Default label: `auto`. All existing safeguards apply
  (confirmation for public networks, no overwrite, address printed before waiting).
- `guides/sepolia-deployment.md` gets the third deploy as a step; `guides/running-locally.md`
  gets the third local command. The owner runs the Sepolia deploy, as before.

## 6. Server

- `Config.Contract` carries the NFT kind and publishes it to the browser.
- The indexer records the three new events. Stored per ENFT: the current settings, whether a
  payout is pending, and a list of automatic payouts (time, amount, fee, requester, whether
  paid in WETH, transaction hash). Amounts are in wei and do not fit the existing 64-bit
  column type.
- Nothing else about the server's rules changes: no private key, RPC URL stays private off
  the local chain.

## 7. Web app

**Create**

- The token selector lists the new contract as its own choice, worded so the two cWETH
  choices can be told apart (for example `cWETH` and `cWETH, automatic payouts`).
- Choosing it shows an **Automatic payouts** group: on/off (default **on**, since the
  person picked this type **(my call)**), interval (default 1 day), fee in ETH (default 0).
- Turning it on shows the privacy note from section 3 in one or two sentences, and the
  confirmation summary repeats the settings.
- The fee field says that at most 10% of each payout is ever paid as a fee. A fee above
  10% of one interval's scheduled payout gets a note that it will be cut to that.

**ENFT page**, for an ENFT of the new type

- A public **Automatic payouts** panel: on or off, interval, fee, the last automatic payout
  (time and amount), when the next one can be triggered, and whether one is pending.
- `Trigger payout`, for any connected wallet, enabled when a payout is due. Steps: request,
  wait for decryption, finish, done. It states that the caller pays the gas and what fee
  they receive.
- `Finish payout`, for any connected wallet, when a payout is pending.
- Both buttons read whether a payout is due or pending from the chain in the browser, not
  from the server's index, which runs a few blocks behind.
- In **Yours**: the three settings with one `Save` (one transaction), with the privacy note
  next to the on/off control. `Claim` and `Claim and convert to ETH` stay.
- **History** lists automatic payouts with their amounts.

**Elsewhere**

- Browse and My ENFTs mark ENFTs that have automatic payouts on.
- Tokens shows **one card per distinct token**, not one per contract. The contract
  authorisation is per contract, so that part of the card lists each contract using the
  token. The page and its hook are built per contract label today, so this is a real
  restructure, not a tweak.
- Wording never suggests the remaining endowment is visible.

## 8. Keeper script

Automatic payouts only happen if someone triggers them. A small script, separate from the
Phoenix server, lets anyone who wants to pay for that do so with their own key.
**(my call to include it; it can be cut without affecting the rest.)**

- `scripts/keeper.ts`, run with Hardhat against a chosen network. One pass, then exit, so
  it can be run from cron.
- Each pass: finish every pending payout it can, then request every payout that is due, on
  every `auto` contract in the deployments file.
- By default it skips an ENFT whose most recent automatic payout was zero, since it has
  probably run dry; a flag includes those.
- On a public network it needs the same explicit confirmation variable as the deploy
  script, and takes its key from the environment, never from a file in the repository.
- Claude runs it only on the local chain.

## 9. Decided by the owner

1. **The fee is capped.** The fee actually paid is never more than 10% of the payout
   (section 4.3).
2. **A payout that is never decrypted is accepted as a risk.** The amount has already left
   the ENFT's claimable balance and the wrapper offers no way to cancel, so that token's
   automatic payouts pause until the pending one is finished. There is no timeout. The
   owner's ordinary `Claim` keeps working for what accrues afterwards, and a pending
   payout can be finished at any later time by anyone.

## 10. Left to the builder

- Storage layout, error names, exact event field types, and how `EndowmentNFT` is opened
  up for reuse.
- Whether the settings travel in a struct or as separate arguments.
- The exact wording and layout of the new UI, within the existing dark minimal theme.
- How the indexer stores payouts.

## 11. Testing

- Contract: settings and their bounds; owner-only changes; reset on transfer; every
  `requestPayout` precondition; a full request, decrypt, finalise round on the FHEVM mock;
  fee paid to the requester and capped at 10% of the amount; `minFee`; zero payout; fee and recipient
  snapshots; a third party finalising the unwrap on the wrapper first; a recipient that
  rejects ETH (paid in WETH); a requester that rejects ETH; reentrancy from a recipient;
  the one payout after settlement.
- Existing contract tests keep passing unchanged for `EndowmentNFT`.
- Browser code against the local chain: trigger, finish, change settings, create with
  settings.
- Server: indexing the three events, the new panels, who sees which control.
- Browser end to end: one flow that creates an automatic ENFT as one account, triggers the
  payout as another, and sees the owner's ETH balance rise.
- `web/docs/manual-checklist.md` gets a section for the owner's Sepolia pass.
