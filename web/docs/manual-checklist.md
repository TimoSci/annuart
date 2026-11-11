# Manual checklist: a real wallet on Sepolia

The browser flows in `web/e2e/flows.spec.js` run on a local Hardhat node with the dev login and
the mock FHE client. This checklist runs the same flows by hand against Sepolia, with a browser
wallet (MetaMask or another EIP-1193 wallet) and the Zama relayer, and adds what an automated run
cannot judge.

## Before you start

1. Follow `guides/sepolia-deployment.md`: it deploys the `mock` and `wrapped` variants and starts
   the app with `ANNUART_RPC_URL` set to a Sepolia RPC and `ANNUART_DEPLOYMENTS` set to
   `../deployments/sepolia.json`.
2. Use two wallet accounts, A and B, each holding some Sepolia ETH.
3. Start from a browser profile with no site data for the app (or click "Clear my activity
   history" and disconnect).
4. Keep the browser's developer tools open on the Network tab, with "Preserve log" on, for step 8.

On Sepolia the lists wait on the server: a new ENFT or a transfer shows up after about half a
minute (two confirmations of about 12 seconds, plus the server's polling), and `Created. Waiting
for it to appear…` can last that long. Wait before deciding something failed.

## 1. Anonymous visitor

1. Open the app without connecting a wallet. Browse lists the ENFTs on this chain, newest first,
   and the wallet control shows `Connect wallet`.
2. Open an ENFT. Details, payout schedule (table and chart) and history show. The schedule shows
   periods, not `Private schedule`.
3. There is no Yours panel, no Claim, no Transfer. The Donate panel (if donations are open) says
   `Connect a wallet to donate.`
4. Remaining reads `Secret. Nobody can read this.`

## 2. Connect, get tokens, create

1. Click `Connect wallet` and approve in the wallet. The control shows A's short address. If the
   wallet is on another network, the first action asks to switch to Sepolia.
2. Move between Browse, Create, My ENFTs, Market and Tokens with the navigation. The address stays
   shown and the wallet is not asked to connect again. Reload the page: it reconnects without a
   prompt.
3. Tokens: on the wrapped card, wrap `0.01` ETH. Steps: Convert ETH to WETH, Approve WETH, Wrap,
   Done; the wallet asks for each. Reveal the balance (the wallet asks to sign once): it shows
   `0.01 cWETH`.
4. Create: pick the wrapped token, amount `0.005`, one period of 1 month paying `0.001` per month,
   donations on. Every amount field echoes the parsed value (`= 0.005 cWETH`).
5. Click Create ENFT. A summary appears and nothing is sent yet. Cancel, change the amount, and
   check the summary is gone and comes back with the new amount.
6. Confirm. Steps: Check your balance, Authorise the contract (first time only), Encrypt the amount, Confirm in your
   wallet, Done. The page shows `Created. Waiting for it to appear…` (or moves on at once) and
   lands on `/enft/wrapped/<id>`, with A as owner and the Yours panel present.

## 3. Owner reveals and claims; a second account donates; owner transfers

1. Wait a while (or come back later), then click Update accrual. Last accrued changes to the time of
   that transaction.
2. Reveal Claimable: a positive amount. Claim; after Done the value is hidden again. Reveal: `0`.
3. My ENFTs lists the ENFT; its reveal shows the same claimable.
4. Switch the wallet to account B. Every revealed value on screen goes back to `•••••`; the Yours
   panel goes. Donate `0.001`: Authorise, Encrypt, Confirm, Done.
5. Switch back to A. Transfer to B's address: the page first asks to confirm that the unclaimed
   balance goes with the ENFT. After it is mined, the owner shown becomes B, the Yours panel goes,
   and History reads `Transferred to …`.

## 3b. The mock token

1. Tokens, mock card: click `Get test tokens`. Reveal the balance (the wallet asks to sign once): a
   positive amount of the mock token.
2. Create: pick the mock token, an amount you can see in the balance, one period, donations off. Create
   it as in section 2 and wait for it to appear.
3. After a short while, click Update accrual on the new ENFT. Reveal Claimable: a positive amount.
   Claim; after Done the value is hidden again. Reveal Claimable: `0`.

## 4. Unwrap

1. Tokens, wrapped card: unwrap `0.005`. Steps: Check your balance, Encrypt the amount, Request unwrap, Wait for
   decryption (this takes a while on Sepolia), Finalise unwrap, Convert WETH to ETH, Done. ETH in
   your wallet goes up by about that amount.
2. Interrupt one: start an unwrap and close the tab once Request unwrap is done. Reopen Tokens: an
   `Unfinished unwraps` list offers `Finish unwrap`, which completes it.
3. If a `WETH in your wallet` line appears (an interrupted wrap or unwrap), `Convert to ETH` empties
   it.

## 5. A failed action

1. Reject a transaction in the wallet: the step reads `failed: You cancelled the request in your
   wallet.` and `Try again` is offered. Try again succeeds.
2. On an ENFT whose fixed schedule has ended but whose page still offers Donate (open it shortly
   before the end and wait), Donate: `failed: This ENFT's schedule has ended, so it no longer accepts
   donations.`

## 6. Activity brightness

1. Click three panels on an ENFT page. The last is brightest, the others a step dimmer each. Time
   alone does not dim anything.
2. Reload, and navigate away and back: the levels are kept.
3. Hover a list row you never clicked: it gets an outline, not brighter.
4. Switch account: the other account's history shows. Switch back: yours returns.
5. Clear my activity history: everything returns to the resting shade.

## 7. Another chain

1. With the wallet on a network other than Sepolia, a write asks to switch; refusing gives
   `Switch your wallet to the right network.`
2. In a wallet that does not know Sepolia yet (remove it from the wallet's networks first, if you
   can), the first write offers to add the network; approve, and the wallet then switches to it.
3. A transaction left pending for three minutes after it was broadcast adds a `Still waiting.`
   note that says to reload and check your balance before trying again.

## 8. Nothing secret reaches the server

1. During a create with amount `0.00731337` and a donation of `0.00027183`, check in the Network
   tab every request and websocket frame sent to the app's own host: none contains the amounts
   (as typed, or in base units). Requests to the relayer and the RPC are not the app's server.
2. View the page source: the `annuart-chain` meta tag has `"rpcUrl":null`, and the server's RPC URL
   (the one in `ANNUART_RPC_URL`) appears nowhere in the Network tab or the page source.
3. The server log shows only `tx:confirmed` with action, label, token id and hash.

## What the automated run cannot judge

1. Readability: dimmed text (resting `#86868b` on `#141415`) and the step and note lines at 12 to
   13 px are readable, in daylight and on a dim screen. Brightness differences between adjacent
   levels are visible but not distracting.
2. Phone width (about 375 px): no horizontal scroll on any page; the navigation, wallet control
   and Clear link wrap cleanly; the ENFT page stacks its columns; Create's period rows wrap without
   overlapping; the Tokens cards and step lists fit; buttons are large enough to tap.
3. The page never suggests the remaining endowment can be seen: no figure, bar, progress, estimate
   or "runs out" wording next to an existing ENFT implies its remaining balance (the Create form's
   warning is about the amount the creator is entering, before it is sealed). The only text for it
   is `Secret. Nobody can read this.`
4. The wallet's own prompts (connect, switch network, sign the decryption permit, each
   transaction) read sensibly and appear only when the step list says they will.
