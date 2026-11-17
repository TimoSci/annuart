# Keeping the endowment total private

The creator and the owner can keep the total value of an endowment from the public, but only
on an ENFT without automatic payouts, and only if both avoid the actions below.

The public always knows an upper bound, because the schedule is public. What can stay hidden
is the actual total.

The same text is in the web app's user guide (the Guide page, last section, in
`web/lib/annuart_web/live/guide_live.ex`). Change both together.

## If you create the ENFT

1. **Do not switch on automatic payouts.** Every automatic payout amount is public, and the
   first short one shows everything the ENFT ever held. Mint on the standard contract, or
   leave the option off.
2. **Do not wrap exactly the endowment amount.** Wrapping ETH into the confidential token
   shows the amount in the clear. Wrap a different, larger sum well beforehand, and do not
   unwrap the exact remainder afterwards, or the difference gives the amount away.
3. **Do not fund the schedule exactly and then say so.** The most a schedule with an end can
   pay is public, so saying it is fully funded publishes the total.
4. **Never disclose the amount,** in words or on chain. You know it and can reveal it at any
   time; nobody can stop you (design spec §3).
5. **Choose the donation setting on purpose.** With donations off, you alone know the total.
   With donations on, each donor knows their own part and may disclose it, but nobody knows
   the whole.

## If you own the ENFT

1. **Keep automatic payouts off** for as long as you hold the ENFT, on a contract that has
   them.
2. **Do not unwrap claims as they arrive.** Anyone can decrypt an unwrap amount. Once the
   ENFT has run out, an unwrap that matches a short claim shows the total. Keep the income in
   the confidential token, or unwrap amounts and at times that have nothing to do with your
   claims.
3. **Do not let your behaviour show when it ran out.** Claim amounts are encrypted, but if
   you visibly stop claiming from a schedule with no end, an observer can estimate the total
   from the date.
4. **Only use Reveal on a computer you trust,** and do not share what it shows.
5. **Keep the amount private if you pass the ENFT on.** The next owner cannot check the
   funding and will want to be told. Once told, the secret depends on them as well.

## What cannot be hidden

- **The schedule and the time of every accrual and claim** are public, so the most the ENFT
  could have paid is always known.
- **The amount of a claim that was paid in full** can usually be worked out from the
  schedule. Only the remaining endowment, and whether a claim fell short, stay hidden.

## If the ENFT has a private payout rate

Only the base rate is hidden, not the periods. There is no automatic payout on this kind,
because it would publish each payout and so the rate. Three things to know.

1. **One public amount reveals the rate.** If an owner converts an identifiable claim to ETH,
   anyone can divide it by the elapsed weighted time and learn the base rate. That shows every
   payout for as long as the endowment lasts.
2. **A past owner keeps the rate.** A seller still knows what the ENFT pays the buyer. Access
   cannot be taken back.
3. **A zero rate cannot be refused.** The contract cannot see the rate. On a schedule with an
   end, a zero rate pays nothing until the end and then releases everything. On a schedule with
   no end, the endowment is locked for good. The owner can check by revealing the rate. A donor
   cannot.

## How far this has been checked

- The automatic payout, unwrap and inference points come from the red-team review
  (`docs/security/2026-11-red-team-report.md`, items D-C3-3 and D-C2-2, and finding F-C3-4a
  for creator disclosure).
- Creator point 2 (the wrapped amount) and owner point 3 (visible behaviour) are reasoning
  from how wrapping and public timing work. The review did not test them.
- All of it assumes the live network enforces access to encrypted values the way the local
  mock does. The Sepolia ACL check in the report confirms that, and it has not been run yet.
- The private-rate contract has Foundry and Hardhat tests, run on in-process networks. It has had
  no red-team review. The Sepolia ACL check has not been run for this contract. The browser path
  that decrypts the 128-bit rate has not been run against a real relayer.
