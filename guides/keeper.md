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

By default it skips an ENFT whose last payout was zero, so it does not spend gas on
payouts that pay nothing. A zero payout usually means the ENFT has run dry (everything in
it has been paid out), or that the owner claimed their balance just before the payout.
An ENFT skipped for this reason stays skipped on every later run, even after someone
donates to it, until someone triggers a payout for it by hand (for example with the
Trigger payout button on its page) or you set `KEEPER_INCLUDE_DRY=1`, which includes
those ENFTs too.

### Skipping payouts with a small fee

Anyone can create many ENFTs with automatic payouts switched on and a fee of zero, or a
tiny one. A keeper that requests every due payout would then pay the gas for all of them,
which can drain the keeper account. To guard against that, set `KEEPER_MIN_FEE` to the
smallest fee you are willing to pay gas for, in wei (1 ETH is 1000000000000000000 wei):

```bash
KEEPER_MIN_FEE=100000000000000 npx hardhat run scripts/keeper.ts --network localhost
```

Due payouts whose fee is below that amount are then not requested. A payout that was
already requested is still finished, whatever its fee, so nothing is left half done. The
default is 0, which requests every due payout. The value must be a whole number written
in digits only; anything else (a negative number, a decimal point, `1e15`) makes the
script stop with `KEEPER_MIN_FEE must be a whole number of wei …` before it sends
anything. The script prints the minimum it is using on the `Min fee:` line.

## Run it on the local chain

With the local node running and the contracts deployed (see `guides/running-locally.md`):

```bash
npx hardhat run scripts/keeper.ts --network localhost
```

It prints `Network:`, `Keeper:` (the address that pays), `Balance:` and `Min fee:`, then one line
per contract, for example `auto: 2 token(s), 0 to finish, 1 to request`. Each transaction
is printed as it is sent, as `auto #1: requesting payout (tx 0x…, waiting…)`, followed by
`auto #1: payout finished`. The last line is
`Done: <n> requested, <n> finished, <n> failed.` If nothing is due it reports
`0 requested, 0 finished, 0 failed`. If no `auto` entry is recorded it prints
`No automatic-payout contract is recorded for localhost (looked in deployments/localhost.json); nothing to do.`
and stops.

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
RPC URL is shown as `<SEPOLIA_RPC_URL>`, a contract that cannot be read at all shows as `auto: reading tokens: FAILED: …` (counted as one failure), the other ENFTs are still handled, and the script
exits with a non-zero code. Run it again later; a payout that is requested but not yet
finished is picked up first.

## Running it on a schedule

The simpler and safer option is to run the keeper by hand whenever you like, with the
`read -s` steps above: the key then never touches a disk.

A schedule (cron) cannot type a key in for you, so it means storing the key in a file.
That is the one exception to "never in a file", and it is acceptable only for a throwaway
key that holds a small amount of Sepolia ETH, which you top up yourself. Keep the file
outside this repository, readable only by you. Example:

1. Create the key file (not in the repository):

   ```bash
   read -s PRIVATE_KEY
   ( umask 077; printf 'export SEPOLIA_RPC_URL="https://…your provider URL…"\nexport PRIVATE_KEY="%s"\n' "$PRIVATE_KEY" > ~/.annuart-keeper.env )
   unset PRIVATE_KEY
   chmod 600 ~/.annuart-keeper.env
   ```

2. Create a small wrapper, `~/run-keeper.sh`, and make it executable
   (`chmod +x ~/run-keeper.sh`). Cron has a minimal PATH, so give the full path to `npx`
   (find it with `which npx`):

   ```bash
   #!/bin/bash
   . ~/.annuart-keeper.env
   cd /path/to/annuart
   CONFIRM_KEEPER=sepolia /full/path/to/npx hardhat run scripts/keeper.ts --network sepolia
   ```

3. Add one line with `crontab -e`, for example every hour:

   ```
   0 * * * * ~/run-keeper.sh >> ~/keeper.log 2>&1
   ```

Each run costs gas for every payout it triggers, so do not run it more often than your
ENFTs' payout intervals. Delete `~/.annuart-keeper.env` and the cron line when you stop.
