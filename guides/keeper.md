# Running the payout keeper

An automatic-payout ENFT (the `auto` kind) pays its owner in plain ETH, but only when
someone asks the contract to. Anyone can ask. The keeper is a small script that does it
for you: it looks at every automatic-payout ENFT, triggers the payouts that are due, and
finishes them.

On Sepolia, you (the owner) run it yourself. Nothing here is run by Claude.

## What it does

One run is one pass over every contract marked `auto` in `deployments/<network>.json`:

1. It finishes any payout that was already requested but not yet paid out.
2. It requests every payout that is due.
3. It finishes the payouts it has just requested.

Finishing needs a decrypted amount from Zama's network. That is not always ready
straight away. If it is not ready, that token is reported as a failure for this run and
the pass carries on with the others; the next run finishes it.

**Whoever runs it pays the gas, and receives any fee** that the ENFT owners set for
triggering a payout. The ENFT owner does not need to be the one running it.

By default it skips an ENFT whose last payout was zero (nothing had accrued yet), so it
does not spend gas on payouts that pay nothing. To include those too, set
`KEEPER_INCLUDE_DRY=1`.

## Run it on the local chain

With the local node running and the contracts deployed (see `guides/running-locally.md`):

```bash
npx hardhat run scripts/keeper.ts --network localhost
```

It prints `Network:`, `Keeper:` (the address that pays) and `Balance:`, then one line
per contract, for example `auto: 2 token(s), 0 to finish, 1 to request`. Each transaction
is printed as it is sent, as `auto #1: requesting payout (tx 0x…, waiting…)`, followed by
`auto #1: payout finished`. The last line is
`Done: <n> requested, <n> finished, <n> failed.` If nothing is due it reports
`0 requested, 0 finished, 0 failed`. If there is no `auto` entry in the deployment file
it says so and stops.

## Run it on Sepolia

Use a throwaway key that holds only a little Sepolia ETH, the same advice as in
`guides/sepolia-deployment.md`. Never put the key in a file in this repository.

```bash
export SEPOLIA_RPC_URL="https://…your provider URL…"
read -s PRIVATE_KEY && export PRIVATE_KEY      # paste the key (0x…), press Enter
CONFIRM_KEEPER=sepolia npx hardhat run scripts/keeper.ts --network sepolia
unset PRIVATE_KEY
```

`CONFIRM_KEEPER=sepolia` is required; without it the script prints
`Refusing to send transactions to the public network "sepolia" without confirmation`
and sends nothing. Check that the `Keeper:` address it prints is the throwaway account
you intended.

If a transaction fails, the line says which ENFT (`auto #3: finishing: FAILED: …`), your
RPC URL is shown as `<SEPOLIA_RPC_URL>`, the other ENFTs are still handled, and the script
exits with a non-zero code. Run it again later; a payout that is requested but not yet
finished is picked up first.

## Running it on a schedule

Run it from a terminal now and then, or from cron. With cron the key has to be available
to the job, so use a throwaway key and keep it in the job's environment rather than in the
repository. Example, every hour:

```
0 * * * * cd /path/to/annuart && CONFIRM_KEEPER=sepolia npx hardhat run scripts/keeper.ts --network sepolia >> keeper.log 2>&1
```

with `SEPOLIA_RPC_URL` and `PRIVATE_KEY` set for that job. Each run costs gas for every
payout it triggers, so do not run it more often than your ENFTs' payout intervals.
