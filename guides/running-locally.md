# Running Annuart locally

This starts the web app against a local Hardhat chain on your own machine. Nothing here
touches Sepolia or any public network, and no wallet or real funds are needed. For
Sepolia, see `guides/sepolia-deployment.md`.

Local mode is the default: the app uses the local chain whenever `ANNUART_RPC_URL` and
`ANNUART_DEPLOYMENTS` are not set.

## 1. What you need

- Elixir 1.20 (with Erlang/OTP)
- Node 20 or newer
- Ports 8545 (the chain) and 4000 (the app) free

## 2. First-time setup

Run these once, and again after pulling changes that touch dependencies.

```bash
# repo root
npm install

# the web app
cd web
npm install --prefix assets   # JS dependencies; also copies the encryption library into place
mix setup                     # Elixir dependencies, database, asset tools, first build
```

## 3. Start it

You need three terminals.

**Terminal 1, repo root: the local chain.** Leave it running.

```bash
npx hardhat node
```

**Terminal 2, repo root: deploy the three contract variants to it.**

```bash
npx hardhat run scripts/deploy.ts --network localhost
TOKEN_KIND=wrapped npx hardhat run scripts/deploy.ts --network localhost
NFT_KIND=auto npx hardhat run scripts/deploy.ts --network localhost
```

The third one is the automatic-payout variant. It reuses the wrapped variant's token, so
run it after the second command, never before.

Each ends with a line like `Wrote deployments/localhost.json (label "mock")`. The file
should now list three entries, `mock`, `wrapped` and `auto`.

**Terminal 3, `web/`: the app.**

```bash
cd web
mix phx.server
```

Open `http://localhost:4000`.

Deploy before starting the app: it reads `deployments/localhost.json` once, when it
starts.

## 4. Log in

The header shows a dropdown of Hardhat's test accounts next to `Connect wallet`. Pick an
account to log in as it. This is the dev login: transactions are signed in the page with
Hardhat's public test keys and sent to your local chain. It exists only on the local
chain.

To get tokens to play with, open **Tokens** and use `Get test tokens` on the mock card,
or wrap some of the account's test ETH on the wrapped card.

## 5. Day-to-day

- **You restarted the Hardhat node.** The chain is empty again. Run the three deploy
  commands from step 3 again. The running app notices the new chain and rebuilds its
  list; you do not need to restart it.
- **You pulled a change to a database migration.** Run `mix ecto.reset` once in `web/`.
  It drops the local database; the list is rebuilt from the chain.
- **Stopping.** Press Ctrl-C twice in the app's terminal, and Ctrl-C in the chain's.

## 6. If something goes wrong

- **The header says `Not configured`, or the lists are empty and stay empty.** The app
  started before the deploys, or `deployments/localhost.json` is missing. Run the
  deploys, then restart the app.
- **The dev login dropdown is missing and only `Connect wallet` shows.** The app is not
  on the local chain. You probably still have the Sepolia settings in this terminal.
  Clear them and restart the app:

  ```bash
  unset ANNUART_RPC_URL ANNUART_DEPLOYMENTS
  ```

- **`mix phx.server` fails with "address already in use".** Something else is on port
  4000. Stop it, or start the app on another port with `PORT=4001 mix phx.server`.
- **`npx hardhat node` fails with "address already in use".** A node is already running
  on port 8545, possibly left over from a test run. Stop it with
  `pkill -f "hardhat node"`.
- **macOS: `tailwind` or `esbuild` is killed as soon as it starts.** Re-sign the
  downloaded binary, from `web/`:

  ```bash
  codesign -s - --force _build/tailwind-macos-arm64-4.1.12
  codesign -s - --force _build/esbuild-darwin-arm64
  ```

- **You ran the browser test suite (`web/e2e`).** It stops whatever is on port 8545 and
  rewrites `deployments/localhost.json` and the local database. Start again from step 3.

## 7. Running the tests

```bash
# Contracts (repo root)
forge test
npx hardhat test

# Server (web/)
mix test

# Browser code, in Node (web/). Needs the chain from step 3 running, with both
# variants deployed.
node --test "assets/test/**/*.test.js"

# Browser end to end (web/e2e/). Starts its own chain and app, so ports 8545 and
# 4000 must be free.
cd e2e
npm install
npx playwright install chromium
npx playwright test
```
