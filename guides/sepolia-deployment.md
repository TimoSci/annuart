# Deploying Annuart to Sepolia

These are the steps you (the owner) run yourself. They send real, public, permanent
transactions on the Sepolia test network, signed with your key. Nothing here is run by
Claude.

The result is three ENFT contracts on Sepolia, recorded in `deployments/sepolia.json`:

| Label | Token | What it is for |
|---|---|---|
| `mock` | `MockConfidentialToken` | Free test tokens from the "Get test tokens" button |
| `wrapped` | `ConfidentialWETH` over Sepolia WETH | Real Sepolia ETH, wrapped |
| `auto` | The same `ConfidentialWETH` as `wrapped` | Wrapped ETH with automatic payouts: anyone can trigger a payout, which arrives as plain ETH |

## 1. What you need

1. **A Sepolia RPC URL** from a provider such as Infura or Alchemy. It usually contains
   an API key, so treat it as private.
2. **A deployer key that holds nothing of value.** Create a fresh account in your wallet
   for this and export its private key. Do not use a key that holds funds on any real
   network.
3. **About 0.1 Sepolia ETH** in that account, from any Sepolia faucet. The four contract
   deployments cost far less; the pre-flight check warns below 0.05.
4. **Dependencies installed** in the repo root: `npm install`.

## 2. Set the environment

Run these in the terminal you will deploy from, at the repo root. `read -s` keeps the key
out of your shell history.

```bash
export SEPOLIA_RPC_URL="https://…your provider URL…"
read -s PRIVATE_KEY && export PRIVATE_KEY      # paste the key (0x…), press Enter
export WETH_ADDRESS=0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14   # Sepolia WETH
```

Do not write the key into a file in this repository.

## 3. Run the pre-flight check

This sends no transactions and costs nothing.

```bash
npx hardhat run scripts/preflight.ts --network sepolia
```

It checks, and prints one line for each:

- the RPC answers and is Sepolia (chain id 11155111);
- your deployer address and its balance;
- Zama's FHE contracts exist at the addresses the contracts are compiled against, and
  the browser's encryption library is configured for the same ones;
- Zama's relayer accepts an encrypted value from this library version;
- `WETH_ADDRESS` is a WETH contract (symbol `WETH`, 18 decimals).

It then prints any `Warning:` lines, and ends with `Pre-flight passed`, or with
`Pre-flight FAILED:` followed by a list of problems (and a non-zero exit code). Error
messages it prints show your RPC URL as `<SEPOLIA_RPC_URL>`, so you can pass them on. The
relayer check can take up to two minutes. **Do not deploy unless it passed.** If the relayer or address check fails, the encryption library is out of date
for the live network; stop and tell Claude, because deployed contracts would be unusable
from the app.

Check that the deployer address it prints is the throwaway account you intended.

If the relayer check alone is the problem and you want to look at everything else first,
`PREFLIGHT_SKIP_RELAYER=1` skips it. A passing run with that set ends with
`Pre-flight passed (encryption not tested)`; it did not test encryption, so run it again
without and get the plain `Pre-flight passed` before you deploy.

## 4. Deploy the mock-token variant

```bash
CONFIRM_DEPLOY=sepolia npx hardhat run scripts/deploy.ts --network sepolia
```

`CONFIRM_DEPLOY=sepolia` is required; without it the script refuses to send anything to
a public network. Expect the lines `Network:`, `Chain id:` (11155111), `Deployer:` and
`Balance:`, then two contract addresses (`MockConfidentialToken:` and `EndowmentNFT:`),
and then:

```
Wrote deployments/sepolia.json (label "mock")
```

Each deployment waits for its transaction to be mined, so this takes a minute or so. As
soon as a deployment is sent, its address and transaction hash are printed, as
`<Name>: <address> (tx <hash>, waiting…)`; the plain `<Name>: <address>` line follows once
it is mined.

## 5. Deploy the wrapped-ETH variant

```bash
CONFIRM_DEPLOY=sepolia TOKEN_KIND=wrapped npx hardhat run scripts/deploy.ts --network sepolia
```

This one needs `WETH_ADDRESS` from step 2. Expect `ConfidentialWETH:` and `EndowmentNFT:`
addresses, then:

```
Wrote deployments/sepolia.json (label "wrapped")
```

## 6. Deploy the automatic-payout variant

Do this after step 5: it shares the wrapped-ETH token that step 5 deployed, so it needs
the `wrapped` entry in `deployments/sepolia.json` and deploys no new token.

```bash
CONFIRM_DEPLOY=sepolia NFT_KIND=auto npx hardhat run scripts/deploy.ts --network sepolia
```

You do not need `WETH_ADDRESS` here. Expect `Using existing token:` followed by the
`ConfidentialWETH` address (the same one as the `wrapped` entry), then an
`AutoPayoutEndowmentNFT:` address, then:

```
Wrote deployments/sepolia.json (label "auto")
```

If it says `No "wrapped" entry to share a token with`, step 5 has not been recorded yet.

## 7. Check and record the result

```bash
cat deployments/sepolia.json
```

It should show `"chainId": 11155111` and three entries, `mock`, `wrapped` and `auto`, each with an
`nft` address, a `token` address and a `deployBlock`. You can look the addresses up on
`https://sepolia.etherscan.io`.

This file is the only record of where your contracts are. It is tracked by git (unlike
the local deployment files), so commit it:

```bash
git add deployments/sepolia.json
git commit -m "chore: record Sepolia deployments"
```

Then remove the key from your shell:

```bash
unset PRIVATE_KEY
```

## 8. If something goes wrong

- **The script stopped after deploying the token but before the ENFT contract.** The
  token's address and transaction hash were printed as soon as it was sent, before the
  wait (`<Name>: <address> (tx <hash>, waiting…)`); check the transaction on
  `https://sepolia.etherscan.io` to see that it was mined. If the script died before
  printing anything, look up your deployer address on `https://sepolia.etherscan.io` to
  see whether a contract was created, and if so use its address. Re-run the same command
  with `TOKEN_ADDRESS=<that address>` added; the script reuses the token instead of
  deploying another. For the wrapped variant it reads the WETH address from the token
  itself, and refuses if your `WETH_ADDRESS` differs from it.
- **"WETH_ADDRESS … is not a WETH contract".** Before deploying the wrapper the script
  checks that `WETH_ADDRESS` has code, the symbol `WETH` and 18 decimals, as the
  pre-flight does. Fix the address (step 2) and re-run.
- **"label … is already deployed".** The script will not overwrite an entry in
  `deployments/sepolia.json`, because that would lose the old address. To deploy a
  replacement on purpose, add `REPLACE=1`. To keep both, add `LABEL=<new name>`.
- **"Refusing to deploy to the public network "sepolia" without confirmation".** You left
  out `CONFIRM_DEPLOY=sepolia`. Add it; it is deliberate.
- **"PRIVATE_KEY is not set".** Export the key as in step 2, in the same terminal.
- **"Error in plugin @fhevm/hardhat-plugin: Missing network url".** `SEPOLIA_RPC_URL` is
  not set (or empty) in this terminal, so Hardhat stopped before the script ran. This
  can happen at the pre-flight check as well as at a deploy. Export it as in step 2.
- **"insufficient funds".** Top the deployer account up from a faucet and re-run.
- **A transaction seems stuck.** Sepolia can be slow. Wait a few minutes before
  re-running; check the deployer address on Etherscan to see whether it was mined.

Contracts on Sepolia cannot be deleted. A mistaken deployment is harmless: it is simply
never listed in `deployments/sepolia.json`.

## 9. Run the app against Sepolia

From `web/`:

```bash
export ANNUART_RPC_URL="$SEPOLIA_RPC_URL"
export ANNUART_DEPLOYMENTS=../deployments/sepolia.json
mix phx.server
```

Open `http://localhost:4000`. The header shows `Connect wallet`. The dev login is not
offered, because it only works on the local chain.

Things that differ from the local chain:

- **Lists update more slowly.** The server stays two blocks behind the chain head
  (`ANNUART_CONFIRMATIONS`, default 2 off the local chain) before it records an event, and
  it reads the chain every 12 seconds (`ANNUART_POLL_MS`), so a new ENFT or a transfer
  takes half a minute to a minute to appear.
- **The first start reads the chain from the deploy block**, which is quick right after
  deploying and slower the older the contracts get.
- **Some free RPC plans only allow log queries over a small block range.** If the server
  log shows repeated range errors from the indexer, restart with a smaller
  `ANNUART_LOG_CHUNK` (the default is 2000 blocks; some plans need 10).
- **Your RPC URL stays on the server.** The browser talks to the chain through the
  wallet, and the page it serves carries no RPC URL. If the wallet does not know Sepolia,
  the app offers to add it and then switches to it. Set `ANNUART_PUBLIC_RPC_URL` only if
  you have a URL you are happy for every visitor to see.
- **Do not leave the server running unattended against a metered RPC plan.** It polls
  the chain every 12 seconds (`ANNUART_POLL_MS`), around the clock, and each poll uses
  your plan's requests.
- Switching the same checkout back to the local chain makes the server rebuild its
  index; that is expected. Before you go back, unset both `ANNUART_RPC_URL` and
  `ANNUART_DEPLOYMENTS` (or close the terminal), so the server reads the local node and
  `deployments/localhost.json` again.

## 10. Tell Claude, then do the wallet pass

Once all three deployments are recorded and the app starts, say so. Claude then runs the
read-only checks: that the server indexes the contracts, and that the browser's
encryption library works against the live network.

After that, the remaining step is yours: `web/docs/manual-checklist.md`, with MetaMask
(or another browser wallet) and two accounts that each hold a little Sepolia ETH. The
design counts the work as done only when that pass succeeds. Report anything that fails
or reads badly, with the step number.
