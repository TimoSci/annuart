# Red team report: PrivateRateEndowmentNFT

## Scope

In scope: `src/PrivateRateEndowmentNFT.sol` and the two points where it hooks into
`src/EndowmentNFT.sol` (`mint` and `_accrue`, now `virtual`). Everything the earlier report
(`2026-11-red-team-report.md`) found about the base contract, the token and the keeper still
applies and is not repeated here. Out of scope (trusted): Zama's coprocessor, KMS and relayer,
the FHEVM and OpenZeppelin libraries, and the token contract.

| Item | Value |
|---|---|
| Reviewed commit | `50ffa15` on `main` |
| `forge test` after the review | 258 passed, 0 failed (249 before, plus the 9 tests of this review) |
| New tests | `test/redteam/PrivateRate.t.sol` |
| Not run | Hardhat, web and e2e suites (no source changed; they passed at `46ed6cc`) |

## Result

No Critical, High or Medium finding. Nobody but the token's owner can take a payout, no
caller can change what a token pays, and the rate is not granted to anyone but the creator and
the token's owners. Two Low findings and four notes follow. Neither Low finding is a defect in
the contract's code: one is a limit of the design, the other depends on the network's limits.

| ID | Severity | Summary |
|---|---|---|
| PR-1 | Low | A zero rate on a schedule with no end locks the endowment and every later donation for good |
| PR-2 | Low | Calls cost 4 to 11% of the network's FHE budget per transaction and per block; when that budget is used up, claims and transfers fail until a later block |
| PR-3 | Note | Every reader of the rate can pass it on, on chain, to anyone or to everyone, and this cannot be undone |
| PR-4 | Note | The "contract only" values are hidden from the public, not from readers of the rate |
| PR-5 | Note | One encrypted input used for two tokens gives both the same rate handle |
| PR-6 | Note | A buyer cannot check the rate before buying unless a reader grants them access, which they then keep |

## What was tried

Each line is a hypothesis an attacker would test, and what happened.

| # | Hypothesis | Outcome | Test |
|---|---|---|---|
| P1 | Another sender can reuse a creator's encrypted endowment and rate | Refused, before and after the creator uses them; with an empty proof refused earlier still | `test_P1_replayByAnotherSender_reverts` |
| P1 | A valid proof of the attacker's own lets them pass someone else's handle as the rate or endowment, including a stored rate they may read | Refused in all three cases | `test_P1_foreignHandleUnderOwnProof_reverts` |
| P2 | A receiving contract can re-enter `claim`, `mintPrivate` or `mint` from the mint callback | `claim` and `mintPrivate` are stopped by the reentrancy guard; `mint` always reverts | `test_P2_callbackCannotReenter_andHandoffIsSound` |
| P2 | Passing the token on from inside the callback leaves the rate or the balance in a broken state | No: the heir is paid in full, the receiver gets nothing, and the amounts add up | same |
| P3 | An approved account or operator can read the rate without owning the token | No. It can only once it takes the token, and then keeps it (by design) | `test_P3_approvalAloneDoesNotGrantTheUnit` |
| P4 | A stranger calling `accrue` often, or at chosen moments, changes what the owner is paid | No: paid is exactly `floor(rate × weight × elapsed / 2^32)` whatever the cadence (24 fuzz runs, 5 accruals each) | `testFuzz_P4_cadenceCannotChangeWhatIsPaid` |
| P4 | Running out, a donation and claims in between break the accounting | No: paid + claimable + remaining equals what was deposited at every step, and the contract holds exactly what it owes | `test_P4_exhaustionAndDonationConserve` |
| P5 | One encrypted pair can be used for two tokens | Yes, by its creator only. See PR-5 | `test_P5_sameInputTwice_sharesOneUnitHandle` |
| P6 | A zero rate locks funds | Yes. See PR-1 | `test_P6_zeroUnitIndefinite_locksEndowmentAndDonations` |
| P7 | A call can exceed the FHE cost limits | No single call does. See PR-2 for the figures | `test_P7_costPerCall` |

Checked by reading, with no test of its own:

- **Overflow.** The rate is below 2^64 and the weighted time saturates at 2^64 − 1, so their
  product plus the carry stays below 2^128. The amount paid is the smaller of that and the
  remaining endowment, so it fits 64 bits. Existing tests cover both extremes.
- **Staging the rate before the token exists.** The rate is written under the next id before
  the base mints. Nothing can take that id in between: `mintPrivate` holds the reentrancy
  guard, `mint` is disabled, and `accrue` refuses an id that has no owner yet. A failed mint
  reverts the staged rate with it.
- **Every path into accrual.** `accrue`, `claim` and transfers all reach the override. The
  settled and past-the-end cases go to the base, which releases the whole remainder as before.
- **What the chain shows.** The FHE operations take the weighted time, the shift and the mask
  as public operands. All three were public already. No event carries the rate.
- **The Create page.** The base payout field has no `name`, and the form has no change event,
  so the typed rate is not sent to the server.

## Findings

### PR-1 (Low): a zero rate on a schedule with no end locks the endowment and donations

The rate is encrypted, so `mintPrivate` cannot refuse a zero. With a schedule that has no end,
such a token never pays, and nothing can release its endowment. Donations are still accepted
and are locked with it: in the test, 1,000 minted and 500 donated are all still in the contract
after 100 years. A donor cannot tell, because nothing on chain distinguishes this token from a
working one. A rate that is merely tiny behaves the same in practice.

The creator loses their own money, so this is a mistake or a trap for donors, not a theft.
The Create page already warns the creator, and the ENFT page already tells donors that they
cannot check a token pays anything.

Options, none of them free:

- Leave it and keep the warnings (the current state).
- Refuse an indefinite schedule on this contract, so every token ends and releases what is
  left. This removes the lock at the cost of the "pays until it runs out" product.
- Clamp the rate to at least 1 at mint. This does not help: the smallest rate pays one base
  unit per 50 days at 100%.

### PR-2 (Low): calls are costly in FHE units, and the budget per block is shared

Measured on the forge-fhevm mock, whose limits are 20,000,000 units per transaction and
20,000,000 per block (5,000,000 in sequence):

| Call | Units | Share of 20,000,000 |
|---|---|---|
| `mintPrivate` | 748,192 | 3.7% |
| `accrue` | 1,642,064 | 8.2% |
| `transferFrom` | 1,804,096 | 9.0% |
| `claim` | 2,228,160 | 11.1% |

Consequences:

- At most 8 claims, or 11 transfers, of private-rate tokens fit in one transaction. A batch
  tool or a marketplace that moves many tokens at once must split its work.
- The mock's per-block cap is one meter for every contract on the network that is not on
  Zama's whitelist. Once a block's budget is used, by ordinary traffic or by someone spending
  it on purpose, further FHE calls in that block revert. For this contract that includes
  plain transfers of the token, because a transfer accrues first. The failure is temporary
  and loses no funds, and the standard contracts are exposed too, at a lower cost per call.

Whether Sepolia and mainnet use the same limits, and the same price per operation, has not
been checked. That decides how much this matters, so it is listed under the Sepolia checks.

### PR-3 (Note): a reader can pass the rate on, on chain

The creator and every owner so far hold access to the rate, and FHEVM lets any holder of
access to a value grant it to another account or mark it publicly decryptable. Neither can be
undone. So the rate is exactly as private as its least careful reader, and a past owner can
publish it long after selling the token. The contract documentation already says a grant
cannot be taken back; the guide should also say that any reader can publish the rate.

This is described here without a runnable example, in line with the earlier decision on
F-C3-4a.

### PR-4 (Note): "contract only" means hidden from the public, not from readers

The carry is granted to the contract alone, and a test asserts that. But the carry is a
function of the rate and of public data (weights and accrual times), so every reader of the
rate can work it out. The same reasoning lets a reader work out what each accrual owed.

The remaining endowment is different: a reader needs the deposits as well. The creator has
their own deposit, as F-C3-4a (accepted) already records, and now also the rate, so a creator
can follow a token's remaining balance and payouts until someone else donates. An owner who
is not the creator cannot. This matches what the standard contract gives the public about its
payouts, since there the rate is public.

No change is proposed. The comment on the carry is accurate as a statement about grants.

### PR-5 (Note): one input used for two tokens shares one rate handle

A creator can use the same encrypted pair for two mints. Both tokens then store the same rate
handle, so an account granted the rate of one can read the rate of the other. The two rates
are the same number by construction, so nothing is learned. It would matter only if a later
change relied on a rate handle being unique to a token. The web app encrypts afresh for every
mint.

### PR-6 (Note): a buyer cannot check the rate before buying

Only the creator and owners read the rate, and the amount in the token is hidden from
everyone. A sale therefore rests on the seller's word, unless a reader grants the buyer access
first, and then the buyer keeps that access even if the sale does not happen. A marketplace
contract that holds the token in escrow becomes an owner and keeps access too. This is for the
design of the planned Market page, not a defect here.

## Not covered

- **The live network.** Everything ran on the forge-fhevm mock. The mock does not enforce
  access when a test decrypts, so access was checked through the access list itself.
- **Private rate over wrapped ETH.** The tests use the mock token. The code path to the token
  is the base contract's, which the earlier review covered over cWETH.
- **Fuzzing depth.** The cadence fuzz runs 24 cases of 5 accruals, because each test is one
  mock transaction with a budget of 20,000,000 units. There is no invariant suite for this
  contract.
- **The handle-reconstruction vector.** As before, argued on paper only.

## Sepolia-only checks

1. Read the network's FHE limits (per transaction, in sequence and per block) and compare
   them with the table in PR-2. If the per-block cap is the mock's, note how much of it other
   applications use.
2. Do one `claim` and one transfer of a private-rate token and confirm neither reverts for
   cost.
3. Reveal the rate as creator and as owner. This is the first 128-bit decryption through the
   real relayer.
4. Run the access check from the earlier report on the new contract, with the rate handle
   added: the rate readable by the contract, creator and owners only; the remaining endowment
   by the contract only.

## Go / no-go

Nothing found blocks a Sepolia deployment. Before real value is put in it: decide PR-1, run
the four Sepolia checks, and add PR-3 to the privacy guide.
