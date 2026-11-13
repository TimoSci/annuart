# EndowmentNFT

An ERC-721 on [Zama FHEVM](https://docs.zama.org/protocol) where each token is a transferable income stream backed by a **secret encrypted endowment**.

Full design: [`docs/superpowers/specs/2026-06-21-zk-endowment-nft-design.md`](docs/superpowers/specs/2026-06-21-zk-endowment-nft-design.md)

---

## Overview

Each `EndowmentNFT` token holds an encrypted endowment of a confidential ERC-20 token (OpenZeppelin `ERC7984`). A per-token **distribution account** accrues over time according to a creator-defined **piecewise-linear schedule**; each accrual drains the secret endowment, capped via `FHE.min` so exhaustion never leaks. The current owner can read (decrypt) their distribution balance but not the endowment — enforced by the FHEVM ACL (the endowment handle is never `FHE.allow`-ed to any owner). Everything — endowment, distribution, schedule, unclaimed balance — travels with the NFT on transfer, with the ACL handed off to the new owner.

### Two creator modes (fixed at mint)

| Mode | Description |
|---|---|
| **Immutable** | The initial funding is sealed at mint. No further top-ups are possible. The original creator is the only party who ever knows the initial endowment amount. |
| **Top-ups allowed** | Anyone can call `topUp(tokenId, encryptedAmount, ...)` to add secret funds. After the first third-party top-up, even the original creator cannot know the total endowment. |

### Privacy model

- The endowment balance is **hidden from the owner and from the public**. The on-chain ACL never grants the endowment handle to any owner address.
- Endowment **exhaustion is only observable retroactively**: once the distribution stops growing (no accrual increase), an owner can infer the endowment is spent — but the exact remaining balance is never revealed.
- The current owner can decrypt their **distribution** balance off-chain via the relayer SDK (`FHE.allow`-ed to `ownerOf`).
- In **immutable mode**, the original creator knows the initial endowment amount they funded. In **top-ups-allowed mode**, third-party top-ups can obscure even that.

### Names

An ENFT can be given a name at mint (`mint`'s last argument, a `bytes32`; zero for none). A name
is **public**, is carried in `EndowmentMinted`, is readable with `nameOf(tokenId)`, and can never
be changed or added later. It is up to 31 ASCII characters, zero-padded on the right: letters,
digits, space and `- _ . '`, with no space at either end; anything else reverts `InvalidName`.

Names are **not unique** and anyone can pick any name, so a name identifies nothing. The token id
and the creator do. The web app therefore never shows a name alone: it is always next to the
token number and a small picture of the creator's address (the "randomart" OpenSSH draws for key
fingerprints, see `web/lib/annuart/randomart.ex`). The picture is a recognition aid, not a proof;
the creator's full address is on the ENFT's page.

### FHE cost model

FHE operations are metered in **HCU (Homomorphic Complexity Units)** — far heavier than native EVM ops — plus small `$ZAMA` protocol fees. The lazy-accrual design mitigates this: distribution accrues passively, so owners can call `accrue` + `claim` infrequently.

### Deployment topology

This is a **single-chain system**. FHEVM is a confidentiality layer on existing host chains (Ethereum mainnet, BSC, HyperEVM; Sepolia for testing) — not a separate chain. `EndowmentNFT` deploys directly on the host chain as a standard ERC-721. "Only the NFT owner controls the endowment" is native same-chain `ownerOf()`. No bridge, oracle, or cross-chain messaging is required.

---

## Prerequisites

- **Foundry** (`forge`, `anvil`): install via [https://getfoundry.sh](https://getfoundry.sh)
- **Node.js**: the `client/` TypeScript client requires **Node >= 20** at runtime (`@zama-fhe/relayer-sdk` emits a warning on Node 18)
- **An FHEVM-compatible Sepolia RPC**: a standard Ethereum Sepolia RPC that supports the Zama coprocessor (e.g. Alchemy/Infura Sepolia)

---

## Build

```shell
forge build
```

---

## Test

```shell
forge test
```

Run with full verbosity:

```shell
forge test -vvv
```

Expected: **117 tests pass** (50 `EndowmentNFT`, 50 `AutoPayoutEndowmentNFT`, 13 `Schedule`, 4 `ConfidentialWETH`), 0 failed.

---

## Deploy

### Local dry-run (Anvil)

Start a local Anvil node (with `forge-fhevm` host contracts) and run:

```shell
PRIVATE_KEY=<anvil-private-key> forge script script/Deploy.s.sol --sig "run()"
```

### Live Sepolia deploy

```shell
export SEPOLIA_RPC_URL=https://sepolia.infura.io/v3/<your-key>
export PRIVATE_KEY=<your-private-key>

forge script script/Deploy.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --private-key $PRIVATE_KEY
```

Note: `SEPOLIA_RPC_URL` must be set in your environment or `.env` before running.
This deploys the contracts only; to deploy what the web app needs, use
[`guides/sepolia-deployment.md`](guides/sepolia-deployment.md).

---

## Client (TypeScript relayer SDK)

The `client/` directory contains a TypeScript client using `@zama-fhe/relayer-sdk` for Sepolia interaction.

### Setup

```shell
cd client
cp .env.example .env
# Fill in: SEPOLIA_RPC_URL, PRIVATE_KEY, NFT_ADDRESS, TOKEN_ADDRESS
npm install
```

`.env.example`:
```
SEPOLIA_RPC_URL=
PRIVATE_KEY=
NFT_ADDRESS=
TOKEN_ADDRESS=
TOKEN_ID=
```

### Operator precondition

Before minting or topping up, the funder must authorise the `EndowmentNFT` contract to pull funds from the confidential token:

```shell
# The funder calls setOperator on the confidential token contract:
# token.setOperator(endowmentNFT, untilTimestamp)
```

This grants `EndowmentNFT` operator rights to call `confidentialTransferFrom` on the funder's behalf.

### Client flow

```shell
# 1. Mint a new EndowmentNFT (funds the endowment in the same tx)
npm run mint

# 2. Wait for accrual to build up over time, then poke the accrual:
npm run accrue

# 3. Decrypt your distribution balance (off-chain, via relayer SDK):
npm run decrypt

# 4. Claim the accrued distribution to your wallet:
npm run claim

# 5. Confirm the endowment is NOT decryptable (negative proof):
npm run try-endow
```

`npm run try-endow` demonstrates the privacy guarantee: attempting to decrypt the endowment handle will fail (the ACL does not grant owner access), confirming the endowment is sealed.

---

## Security Note

**`src/mocks/MockConfidentialToken.sol` is a TEST/DEV token only.**

It has a permissionless `mint` function that allows anyone to mint arbitrary amounts — it exists solely for local Foundry tests and Anvil dry-runs. **Never rely on the mock on mainnet or any production deployment.** Set `TOKEN_ADDRESS` in your `.env` to a real, audited confidential token contract for any real deployment.

---

## Project structure

```
src/
  EndowmentNFT.sol          # Main ERC-721 contract
  AutoPayoutEndowmentNFT.sol # EndowmentNFT over a WETH wrapper, with automatic ETH payouts
  ConfidentialWETH.sol      # ERC-7984 wrapper over WETH (9 decimals)
  libraries/
    ScheduleLib.sol          # Piecewise-linear accrual schedule
  mocks/
    MockConfidentialToken.sol # TEST ONLY — permissionless mint
script/
  Deploy.s.sol              # Foundry deploy script
test/                       # Foundry test suite (117 tests) and Hardhat tests
scripts/                    # Hardhat deploy, pre-flight check and payout keeper
client/                     # TypeScript relayer-sdk client (Sepolia)
docs/superpowers/specs/     # Design spec
```

---

## Interacting via Hardhat

A Hardhat setup with the Zama FHEVM plugin (`@fhevm/hardhat-plugin`) is included for
interactive use — deploying and calling the contract with encrypted inputs and
user-decryption — alongside the Foundry test suite. Hardhat compiles the same
contracts in `src/`, uses a separate `cache-hardhat/` directory, and leaves Foundry's
`forge test` untouched.

### Prerequisite: Node ≥ 20

The fhevm Hardhat plugin requires **Node 20+** (it hard-fails on Node 18). If your
default `node` is older, install Node 22 (e.g. Homebrew keg-only) and put it first on
PATH for Hardhat commands:

```bash
export PATH="/opt/homebrew/opt/node@22/bin:$PATH"   # adjust to your Node ≥20 install
node --version   # must be >= 20
```

### Build & smoke test (in-process mock — no external services)

```bash
npx hardhat compile
npx hardhat test test/EndowmentNFT.hh.ts
```

The smoke test deploys the contract, mints with an encrypted endowment, accrues over
simulated time, user-decrypts the distribution, and claims — all on the plugin's local
FHEVM mock.

### Deploy

```bash
# Local: start a node, then deploy
npx hardhat node                                        # terminal 1
npx hardhat run scripts/deploy.ts --network localhost   # terminal 2 (mock token)
TOKEN_KIND=wrapped npx hardhat run scripts/deploy.ts --network localhost
NFT_KIND=auto npx hardhat run scripts/deploy.ts --network localhost   # automatic payouts; after the wrapped deploy
```

For Sepolia, follow [`guides/sepolia-deployment.md`](guides/sepolia-deployment.md): a no-cost
pre-flight check (`scripts/preflight.ts`), then the deploys. A deploy to a public network
refuses to run unless `CONFIRM_DEPLOY=<network name>` (for example `CONFIRM_DEPLOY=sepolia`) is set.

Environment variables:

- `NFT_KIND`: `standard` (default, `EndowmentNFT`) or `auto` (`AutoPayoutEndowmentNFT`). `auto` deploys
  no token: it shares the token of the `wrapped` entry (or `TOKEN_ADDRESS`), so deploy `wrapped` first.
  The default `LABEL` is `auto`, and `TOKEN_KIND`, if set, must be `wrapped`.
- `TOKEN_KIND`: `mock` (default, `MockConfidentialToken`, dev only: its constructor reverts on
  mainnet/BSC/HyperEVM), `wrapped` (`ConfidentialWETH` wrapping a WETH) or `plain` (an existing ERC7984).
- `LABEL`: the entry name in the deployment file (default: the token kind). On a public network,
  deploying again with a recorded label is refused unless `REPLACE=1` is set; locally it replaces
  the entry.
- `WETH_ADDRESS`: the WETH to wrap for `wrapped`. Required except on `localhost`/`hardhat`,
  where a `MockWETH` is deployed when it is unset. When set, the deploy refuses it unless it has
  code, the symbol `WETH` and 18 decimals.
- `TOKEN_ADDRESS`: required for `plain`; for `mock` and `wrapped`, reuses that token instead of
  deploying one (a wrapped token's `underlying` is read from the token itself).
- `CONFIRM_DEPLOY`: on a public network, must equal the network name. `REPLACE`: `1` overwrites a
  recorded label.

Each deploy writes `deployments/<network>.json` (git-ignored, except `deployments/sepolia.json`), keyed by Hardhat's network name:

```json
{
  "chainId": 31337,
  "contracts": [
    {
      "label": "mock",
      "nft": "0x...",
      "token": "0x...",
      "tokenKind": "mock",
      "underlying": null,
      "deployBlock": 3
    }
  ]
}
```

`tokenKind` is `mock`, `wrapped` or `plain`; `underlying` is the WETH address for `wrapped`,
otherwise `null`; `deployBlock` is the block the ENFT contract was deployed in. An `auto` entry has
`tokenKind` `wrapped` and `"nftKind": "auto"`; entries without `nftKind` are standard.

### Interaction tasks

Addresses are read from `deployments/<network>.json` (the first entry, or the one chosen with
`--label`; `--nft`/`--token` override). Add `--network localhost` or `--network sepolia`.
`task:mint` only mints test tokens for a `mock` deployment and fails with a clear message otherwise.

```bash
npx hardhat task:mint --amount 1000000 --topups true   # mint a new endowment NFT
npx hardhat task:mint --amount 1000000 --name "Rainy day fund"   # the same, with a public name
npx hardhat task:accrue --id 1                          # advance accrual (anyone)
npx hardhat task:distribution --id 1                    # decrypt your claimable balance
npx hardhat task:claim --id 1                           # claim (owner only)
npx hardhat task:info --id 1                            # owner, mode, schedule, settled, distribution handle
npx hardhat task:info --id 1 --label wrapped            # use another deployment
```

The endowment balance is deliberately **not** decryptable — there is no task for it,
and any attempt to user-decrypt the endowment handle is rejected by the FHEVM ACL.

### Behaviour

- At the end of a fixed schedule, the first accrual releases the whole leftover endowment to
  the owner's claimable distribution and marks the token settled.
- Top-ups are rejected after that end.
- A final segment with `duration = 2^64 - 1` is indefinite and must have a non-zero rate.
- `scheduleStart` plus all fixed (non-indefinite) durations must stay below `2^64 - 1`, else
  `mint` reverts `ScheduleTooLong`.
- cWETH has 9 decimals.

For ad-hoc exploration, `npx hardhat console --network localhost` exposes `ethers` and
`fhevm` (the encrypt/decrypt helpers).

---

## Automatic payouts (`AutoPayoutEndowmentNFT`)

`AutoPayoutEndowmentNFT` is an `EndowmentNFT` whose token is an ERC-7984 wrapper over WETH
(`ConfidentialWETH`, the same token as the `wrapped` deployment). Its owner can let **anyone**
pay out the whole claimable balance to the owner as plain ETH, so income arrives without the
owner having to claim and unwrap by hand. With automatic payouts off (the state of a token
minted with plain `mint`) it behaves exactly like an `EndowmentNFT`. There are no admin
functions and no contract-owner role.

**Settings** (per token, set by the owner, or given at `mintAuto`): on or off; the interval, at
most one payout per interval, default 1 day, between 1 hour and 365 days; the fee, in wei of ETH,
default 0, offered to whoever requests a payout. The fee actually paid is never more than 10% of
the payout. When a payout is requested, the recipient (the owner then) and the fee are fixed for
that payout, so a later change cannot redirect or raise it. The first payout may be requested at
once. **Automatic payouts reset to off when the token is transferred**, so a new owner never
inherits public payouts they did not choose.

**Functions**

| Function | Who | What |
|---|---|---|
| `mintAuto(to, encEndowment, inputProof, segments, scheduleStart, topUpsAllowed, name, enabled, interval, fee)` | anyone | `mint` with the settings given up front |
| `setAutoPayout(tokenId, enabled, interval, fee)` | owner | change all three settings |
| `requestPayout(tokenId, minFee)` | anyone | take the whole claimable balance and ask the wrapper to unwrap it; reverts if the fee is below `minFee`, a payout is pending, or it is too soon |
| `finalizePayout(tokenId, cleartextAmount, decryptionProof)` | anyone | once the amount is publicly decrypted, pay the fee to the requester and the rest to the owner, in ETH (in WETH if the owner cannot receive ETH) |
| `autoPayoutOf`, `pendingPayoutOf`, `payoutDue`, `lastPayoutOf`, `totalMinted` | view | settings and last request time; the pending payout; whether a request would be accepted now; the last paid payout; the number of tokens minted |

**Events:** `AutoPayoutSet(tokenId, enabled, interval, fee)` on every change, including mint and
the reset on transfer; `PayoutRequested(tokenId, requestId, recipient, requester, fee)`;
`PayoutPaid(tokenId, requestId, amountWei, feeWei, paidInWeth)`.

**Privacy cost.** Unwrapping reveals the amount, so for a token with automatic payouts on:

- every automatic payout amount is public, with its time;
- while payouts equal the scheduled amount, the remaining endowment stays hidden;
- the first payout that falls short shows that the endowment has run out. Because the schedule
  is public, that also reveals, in hindsight, everything the ENFT ever held: the original
  endowment plus all donations up to then;
- after that, each later payout is whatever was donated in between, so those donation amounts
  become public too;
- when a fixed schedule ends, the leftover is released to the owner, and the next automatic
  payout reveals it.

The Create page and the ENFT page say this wherever the setting is turned on. Automatic payout
amounts are public chain data, so the web server indexes and shows them: a deliberate exception
to "no amount reaches the server" that does not extend to endowments, claimable balances, token
balances or manual claims.

**Deploying.** `NFT_KIND=auto` deploys it, sharing the token of the `wrapped` entry (see
"Interacting via Hardhat", Deploy, above). On Sepolia, see
[`guides/sepolia-deployment.md`](guides/sepolia-deployment.md).

**The keeper.** `scripts/keeper.ts` is a small script that triggers the payouts that are due
and finishes the pending ones, for every `auto` contract in the deployment file. Whoever runs it
pays the gas and receives the fees. See [`guides/keeper.md`](guides/keeper.md).

---

## Web app

`web/` is a Phoenix LiveView app for browsing, creating and managing ENFTs. The server indexes
the contracts' public events and renders pages; everything secret happens in the browser.

### The privacy rule

**No amount ever reaches the server.** Endowment and donation amounts, revealed balances and
revealed claimable amounts are typed, encrypted, decrypted and shown only by browser code. Their
inputs have no `name`, sit in `phx-update="ignore"` regions, and are never sent in a LiveView
event, form or URL; the server only hears `tx:confirmed` with an action, a contract label, a token
id and a transaction hash. The server never holds a private key and never signs, encrypts or
decrypts. `web/e2e` checks this in a real browser.

The one exception is the amount of an automatic payout (see "Automatic payouts" above): it is
public chain data once paid, so the server indexes and shows it.

An ENFT's name is not an amount and is not private: it is public chain data, and the server reads
it from the `EndowmentMinted` event like the owner and the schedule.

### Prerequisites

- Elixir 1.20 (with Erlang/OTP)
- Node 20+ (for Hardhat, the JS dependencies and the tests)

### Run it locally

```bash
# repo root: a local chain with the FHEVM mock, and the three variants
npx hardhat node                                                     # terminal 1
npx hardhat run scripts/deploy.ts --network localhost                # terminal 2: mock token
TOKEN_KIND=wrapped npx hardhat run scripts/deploy.ts --network localhost
NFT_KIND=auto npx hardhat run scripts/deploy.ts --network localhost

# the app
cd web
npm install --prefix assets   # JS dependencies; its postinstall vendors the relayer SDK
mix setup                     # deps, database, asset tools, first build
mix phx.server                # http://localhost:4000
```

Deploy before starting the server: it reads `deployments/localhost.json` once, at start. After a
restart of the Hardhat node, redeploy; the running server notices the new chain and rebuilds its
index. After pulling changes to a migration, run `mix ecto.reset` once (it drops the dev
database; the index is rebuilt from the chain).

macOS: if the downloaded `tailwind` or `esbuild` binary is killed as soon as it starts, re-sign it
ad hoc: `codesign -s - --force <path>`, for example
`codesign -s - --force _build/tailwind-macos-arm64-4.1.12` or
`codesign -s - --force _build/esbuild-darwin-arm64` (run from `web/`).

### Dev login

In dev and test, the wallet control in the header is a `<select>` of Hardhat's first five
accounts (derived in the browser from Hardhat's public test mnemonic). Picking one connects as
that account; transactions are signed in the page and the FHEVM mock stands in for the relayer.
It only works on chain 31337 and is never part of a production build: the dev bundle (`dev.js`)
is referenced only when `:dev_wallet` is on, which only `config/dev.exs` and `config/test.exs`
set. In production the control is `Connect wallet`, for a browser wallet. The dev login is offered only
when the chain is 31337, and then beside a `Connect wallet` button.

### Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `ANNUART_RPC_URL` | `http://127.0.0.1:8545` | The chain's JSON-RPC endpoint. One running instance talks to one chain. |
| `ANNUART_DEPLOYMENTS` | `../deployments/localhost.json` (relative to `web/`) | The deployment file written by `scripts/deploy.ts`. |
| `ANNUART_PUBLIC_RPC_URL` | unset | An RPC URL the browser may see and use. Unset, the page carries the server's own URL only on chain 31337 and only when its host is a loopback address (`localhost`, `127.0.0.1`, `[::1]`); otherwise no RPC URL, and the server's URL stays on the server. |
| `ANNUART_CONFIRMATIONS` | `0` on chain 31337, `2` elsewhere | Blocks the indexer stays behind the chain head. |
| `ANNUART_LOG_CHUNK` | `2000` | Most blocks asked of the node in one `eth_getLogs` call; lower it on RPC plans that limit the range. |
| `ANNUART_POLL_MS` | `4000` on chain 31337, `12000` elsewhere | How often the indexer reads the chain, in milliseconds (at least 1000). Each poll costs RPC requests, which matters on a metered plan. |
| `PORT` | `4000` | HTTP port. |
| `ANNUART_LIVE_RELOAD` | on | Dev only: `false` turns off browser live reload (the e2e run does). |
| `DATABASE_PATH`, `SECRET_KEY_BASE`, `PHX_HOST`, `PHX_SERVER` | | Production, as usual for Phoenix. |

### Tests

```bash
# Contracts (repo root)
forge test

# Server (web/)
mix test

# Browser code, in Node (web/). The *.local tests need a running Hardhat node with all
# three variants deployed, and are skipped without one.
node --test "assets/test/**/*.test.js"

# Browser end to end (web/e2e/). Starts its own Hardhat node, deploys the three variants and starts
# the Phoenix dev server, so ports 8545 and 4000 must be free.
cd e2e
npm install
npx playwright install chromium
npx playwright test
```

The e2e run rewrites `deployments/localhost.json` and the dev database, and stops whatever is
listening on port 8545.

`E2E_REUSE=1 npx playwright test` reuses a node and server that are already running, which is
quicker while working on the flows; the final flow restarts the node, so run it on its own or
skip it with `--grep-invert restarted` then. `web/docs/manual-checklist.md` is the same ground by
hand with a real wallet on Sepolia, plus what an automated run cannot judge.

To check that a production build carries no dev code:

```bash
MIX_ENV=prod mix assets.deploy
grep -rlE "test test test test|createDevSigner|MockFhevmInstance" priv/static/assets/   # prints nothing
mix phx.digest.clean --all
```

---

## License

MIT
