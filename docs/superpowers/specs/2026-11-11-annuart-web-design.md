# Annuart web app: design

Date: 2026-11-11
Status: draft, awaiting owner approval

Decisions are marked **(owner)** when the project owner made them in conversation and
**(my call)** when the designer chose a default the owner has not explicitly confirmed.
Anything not marked is left to the builder.

## 1. Intent

Annuart's `EndowmentNFT` (ENFT) is an ERC-721 that wraps a secret, FHE-encrypted
endowment of a confidential ERC-7984 token and pays it out to the current owner on a
public schedule. Today it can only be used from Hardhat tasks and Node scripts.

This project gives it a web frontend, built with Phoenix/Elixir, where a person can:

- browse existing ENFTs without a wallet,
- create (mint) an ENFT on a contract the project owner has already deployed,
- transfer an ENFT they own,
- donate (top up) to any ENFT that accepts donations,
- see and claim the payouts of ENFTs they own.

It also makes four small changes to the ENFT contract that the frontend exposed as
necessary, and adds a confidential wrapper for Sepolia ETH.

## 2. Goals, non-goals, anti-goals

### Goals

- **(owner)** Passive browsing needs no wallet or login.
- **(owner)** Wallet login (MetaMask or similar) for everything that sends a transaction.
- **(owner)** A development mode with a dummy login that needs no real wallet and sends
  real transactions to the local Hardhat node.
- **(owner)** An ENFT's page shows owner, payout schedule, top-up status and creation date.
- **(owner)** Excess endowment can never be locked forever, enforced by the contract.
- **(owner)** The final period of a schedule can be indefinite.
- **(owner)** The app is ready for future ENFTs with private schedules: it treats the
  schedule as possibly hidden and reads from a configurable list of contracts.
- **(owner)** A working Sepolia instance is part of this project, with two ENFT
  contracts: one over the mock token and one over real Sepolia ETH (section 3.7).
- **(my call)** Every user-callable contract function that matters without a marketplace
  is reachable from the UI: `mint`, `topUp`, `claim`, `accrue`, `safeTransferFrom`, plus
  the token's `setOperator`, and in development the mock token's `mint`.

### Non-goals

- **(owner)** Buying and selling. The Market page is a static "coming soon" page.
- **(owner)** Users deploying contracts. Deployment stays with Hardhat scripts.
- Private schedules themselves. That is a future contract redesign.
- **(my call)** ERC-721 `approve` / `setApprovalForAll`. They only matter to
  marketplaces and are a common phishing vector; they arrive with the Market.
- **(my call)** Server-side accounts, sign-in signatures, or cross-device sync of
  anything.
- **(my call)** Public hosting. "Sepolia instance" means contracts deployed on Sepolia
  and the app, run in a release build on the owner's machine, pointed at them and
  verified with a real wallet. Hosting it on the internet is a separate step.
- **(my call)** Supporting several chains in one running instance. One instance talks
  to one chain (local Hardhat or Sepolia), and to any number of ENFT contracts on it.

### Anti-goals (failures even if everything "works")

- A plaintext amount (endowment, donation, revealed balance, token balance) ever reaches
  the Phoenix server, its logs, or a LiveView socket.
- The server ever holds or sees a private key.
- The development login or its test keys are usable in a production build or against any
  chain other than chain id 31337.
- The UI implies the remaining endowment can be seen by anyone.

## 3. Contract changes

All in `src/EndowmentNFT.sol` and `src/libraries/Schedule.sol`. The contract is not
upgradeable, so this means a redeploy; there are no deployments that need preserving.
Existing Foundry and Hardhat tests must be updated and extended to cover each change.

### 3.1 Public read access **(owner agreed to a getter)**

Add view functions so the app can read, per token: the schedule segments,
`scheduleStart`, and `lastAccrualAt`. `topUpsAllowedOf` already exists. Exact function
shape is the builder's choice. No encrypted value gains any new ACL grant.

### 3.2 Mint event **(owner)**

Emit an event on mint carrying token id, creator (`msg.sender`), recipient,
`scheduleStart` and `topUpsAllowed`. **It must not contain the schedule**, so the same
event shape works for future private-schedule ENFTs. Creation date is the block
timestamp of this event.

No events are added for `topUp`, `claim` or `accrue` **(my call)**; the history shown in
the app is "created" and "transferred" only, which the owner saw and accepted.

### 3.3 Leftover release at schedule end **(owner)**

For a schedule with a fixed end:

- Until the end time, accrual is unchanged: `min(owed, endowmentRemaining)` moves from
  the endowment to the distribution.
- The first accrual at or after the end time moves **all** of `endowmentRemaining` into
  `distribution`, for the current owner to claim. Nothing is revealed in plaintext.
- `topUp` reverts once the end time has passed, so donations cannot pass straight
  through to the owner.

A plaintext "settled" flag to avoid repeating FHE work after the sweep is acceptable;
the end time is already public.

Known and accepted: the owner learns the size of the leftover when decrypting their
final balance.

### 3.4 Indefinite final period **(owner)**

- The last segment of a schedule may be marked indefinite. It pays at its rate until the
  endowment is exhausted.
- An indefinite segment must be last and must have a rate above zero; `mint` reverts
  otherwise.
- A schedule with an indefinite segment has no end: 3.3's sweep never triggers and
  `topUp` is never rejected for lateness.
- Representation **(my call)**: `duration == type(uint64).max` as the sentinel.
  `Schedule.integrate` and `Schedule.scheduleEnd` must not overflow with it.

### 3.5 Tooling that must follow

- `tasks/endowment.ts`, `client/src/*`, `test/EndowmentNFT.hh.ts`, README: update for
  the new ABI.
- `scripts/deploy.ts` currently always writes `deployments/local.json`, whatever the
  network. Change it to write `deployments/<network>.json` and record the deploy block
  **(my call)**; the web app reads these files in development.

### 3.6 Rate precision **(owner: acceptable as is)**

`ratePerSec` stays whole base units per second. The Create form shows the effective
rate after rounding and refuses a rate that rounds to zero (which an indefinite period
would also revert on). With a 6-decimal token the smallest rate is about 0.086 tokens a
day.

### 3.7 Tokens on Sepolia **(owner: both the mock and real Sepolia ETH)**

Each ENFT contract is bound to one token, so Sepolia gets two ENFT deployments:

- **Mock token.** `MockConfidentialToken` and an ENFT contract over it. Its open `mint`
  backs a "Get test tokens" button, enabled for any token flagged as a mock in
  configuration, on any chain. This flag is independent of the dev login's
  "chain 31337 only" rule.
- **Sepolia ETH** **(my call on the mechanism)**. A new small contract, a confidential
  wrapper over Sepolia WETH built on OpenZeppelin's `ERC7984ERC20Wrapper` (already a
  dependency), and an ENFT contract over it. The wrapper overrides `_maxDecimals` to
  **9** instead of the default 6 **(my call)**: at 6 decimals the smallest payout rate
  would be about 0.086 ETH a day, which is unusable; at 9 it is about 0.0000864 ETH a
  day, and the `uint64` ceiling is still about 18 billion ETH.
  - Getting in: ETH → WETH (`deposit`) → approve → `wrap`. Amounts are public at this
    point, and the UI says so.
  - Getting out: `unwrap` then `finalizeUnwrap`, a two-step flow that waits on a public
    decryption. The unwrapped amount becomes public, and the UI says so.
  - No custom ETH-accepting wrapper is written; the stock OpenZeppelin wrapper keeps the
    new on-chain surface minimal.

The deploy script gains the ability to deploy either variant and records each in
`deployments/<network>.json`. Deploying to Sepolia needs the owner's RPC URL and funded
key; the owner runs or explicitly approves those deploys.

### 3.8 Existing behaviour the UI must explain

- On transfer, the unclaimed claimable balance travels with the ENFT to the new owner.
- `topUpsAllowed` and the schedule are fixed at mint.
- `mint` and `topUp` pull tokens with `confidentialTransferFrom`, so the sender must
  first make the ENFT contract an operator on the token (`setOperator(address, until)`).
- `distributionHandle` only reflects the last accrual. `claim` accrues first; a reveal
  does not.

## 4. Architecture **(my call throughout, owner saw and accepted the outline)**

```
Browser                                   Phoenix (web/)                 Chain
┌──────────────────────────────┐   WS    ┌─────────────────────┐  RPC  ┌────────────┐
│ LiveView pages               │◄───────►│ LiveViews           │       │ Hardhat    │
│ JS hooks:                    │         │ Indexer (GenServer) │──────►│ node or    │
│  signer  (MetaMask | dev)    │         │ SQLite cache        │       │ Sepolia    │
│  fhe     (relayer | mock)    │─────────┼─────────────────────┼──────►│            │
│  activity brightness         │  RPC (transactions, encrypted │       └────────────┘
└──────────────────────────────┘        inputs, user decryption)
```

- A new Phoenix app in `web/` (current Phoenix + LiveView; Elixir 1.20 is installed).
- **The server is read-only and public-data-only.** It indexes events and serves pages.
  It never signs, never encrypts, never decrypts.
- **The browser does everything secret**: encrypting amounts, signing transactions,
  signing the EIP-712 user-decryption request, displaying decrypted values.
- Cache store: SQLite through Ecto, so there is no database server to run.

### 4.1 Configuration

A list of ENFT contracts for the instance's chain. Per contract: label, ENFT address,
token address, deploy block, and the token's kind (mock, wrapped, or plain). Plus chain id and
RPC URL(s). The list is read from `deployments/<network>.json`, overridable by environment in a release.

Every ENFT is identified in the app by (contract, token id); URLs include both.

### 4.2 Indexer

- Follows the mint event and ERC-721 `Transfer` for each configured contract, from its
  deploy block, by polling.
- Stores per ENFT: contract, id, creator, owner, created-at, `scheduleStart`,
  `topUpsAllowed`, schedule segments (or "hidden" if the contract has no readable
  schedule), and the transfer history.
- Schedule and `topUpsAllowed` are immutable, so read once. `lastAccrualAt` is read
  live when a page is shown.
- Pushes updates to open LiveViews (PubSub) so lists and pages refresh after a
  transaction confirms.
- Must notice a restarted local Hardhat node (chain shorter than its cursor) and
  rebuild its cache. Reorg handling on Sepolia: a small confirmation depth is enough.

### 4.3 Signer: one interface, two implementations

- **Wallet signer**: any injected EIP-1193 wallet. "Logged in" means the wallet has
  shared an address; there is no sign-in message, because the server guards nothing
  private. Handles account and chain changes, and prompts to switch when the wallet is
  on the wrong chain.
- **Dev signer** **(owner: dummy auth, real local transactions)**: a dropdown of the
  Hardhat node's well-known pre-funded accounts; the browser signs with the matching
  well-known test key. Only bundled and enabled in the dev environment, and it refuses
  to work unless the chain id is 31337.

The rest of the app cannot tell which one is active.

### 4.4 FHE: one interface, two implementations

- **Sepolia**: `@zama-fhe/relayer-sdk` web build, as `client/src/*` already does in Node.
- **Local Hardhat**: Zama's mock (`@fhevm/mock-utils`), the same mechanism the Hardhat
  plugin uses, talking to a node started with `npx hardhat node`.

Operations needed: encrypt a `uint64` input bound to (contract, sender); user-decrypt a
handle (ENFT distribution, token balance) with an EIP-712 signature. The decryption
keypair and signature should be reused for the browser session so repeated reveals do
not prompt again.

**Biggest technical risk.** Getting both FHE implementations bundled and working in the
browser (WASM for the SDK; the mock against a local node) is unproven here. Do this
first, as a spike, before building pages. If the mock cannot run in a browser, the
fallback is a dev-only local helper process that performs mock encryption/decryption;
it must be impossible to enable outside dev.

### 4.5 Keeping secrets off the server

- Amount inputs are not bound to LiveView (`phx-change`/`phx-submit` must not carry
  them). Hooks read them in the browser.
- Revealed values are rendered by hooks into regions LiveView does not manage.
- Checks that need the amount (section 5.3 warnings) run in the browser.
- The schedule, options, addresses and transaction hashes are public and may go through
  LiveView normally.

## 5. Pages

Navigation: **Browse · Create · My ENFTs · Market (soon) · Tokens**, then the wallet
control and "Clear my activity history". The owner approved wireframes of the page set,
the ENFT page and the Create page; they are in `.superpowers/brainstorm/` (not
committed) and described here.

### 5.1 Browse (no wallet)

List of all indexed ENFTs: id, owner, schedule summary (or "Private schedule"),
donations on/off, created date. Filter by donations on/off and by contract; sort by
created date. Each row links to the ENFT page.

### 5.2 ENFT page (no wallet to view)

- **Details (everyone):** owner, creator, created, payouts start, payouts end (a date,
  or "When the endowment runs out" for an indefinite schedule), donations accepted or
  not, last accrued, and "Remaining: secret. Nobody can read this."
- **Payout schedule (everyone):** a simple step chart and a table of periods with start,
  length, rate and maximum payable. An indefinite period shows "Indefinitely" and
  "until empty". A fixed-end schedule notes that any leftover is paid to the owner at
  the end. A hidden schedule shows "Private schedule".
- **History (everyone):** created; each transfer.
- **Yours (owner only):** claimable amount, hidden until **Reveal**; **Claim**;
  **Transfer** (address input, with the warning that unclaimed balance goes with the
  ENFT, and a confirmation). Reveal notes that the figure is as of the last accrual.
- **Donate (any connected wallet):** amount and Donate. Not shown when donations are
  off or a fixed schedule has ended.
- **Maintenance (any connected wallet):** "Update accrual".
- **Sell:** disabled, "coming soon".

### 5.3 Create (wallet)

1. **Endowment:** amount in token units, with the user's token balance alongside once
   revealed.
2. **Payout schedule:** rows of "lasts N (days | weeks | months | years)" and "pays R
   per (day | month | year)"; add/remove rows; the last row may be set to
   "indefinitely". A live chart and the schedule's total. The app converts to seconds
   and integer base units per second and shows the rounded effective rate
   **(my call: a month is 30 days, a year 365 days, and the form says so)**.
3. **Options:** start now or on a date; allow donations (with "cannot be changed
   later"); recipient is me or another address.

Warnings, computed in the browser:

- Amount below the schedule total: payouts stop early, with an estimated date.
- Amount above a fixed schedule's total: "X extra will be paid to the owner as a lump
  sum when the schedule ends."
- Indefinite schedule: estimated date the endowment runs out.

On success, link to the new ENFT's page.

### 5.4 My ENFTs (wallet)

ENFTs owned by the connected address, each with reveal and claim, linking to its page.

### 5.5 Tokens (wallet) **(my addition, owner accepted)**

Per configured token: symbol and decimals read from the token; balance hidden until
revealed; whether the ENFT contract is authorised and until when; an **Authorise**
button (`setOperator`, **my call: one year**).

- Token flagged as a mock: a "Get test tokens" button (section 3.7).
- Wrapped token: the wallet's ETH balance, and **Wrap** (ETH → WETH → confidential)
  and **Unwrap** (two steps, back to WETH, then to ETH) using the step display of
  section 5.7, with the notes that wrapped and unwrapped amounts are public. Amounts
  entered here are public anyway and may be handled normally.

### 5.6 Market

Static: buying and selling is coming soon.

### 5.7 Transaction steps

Every action shows the same step list, e.g. for Create: **Authorise** (skipped if
already authorised) → **Encrypt** → **Confirm in wallet** → **Done**. Each step is
waiting, in progress, done, or failed with a plain-language reason and a retry. Contract
custom errors are translated (`TopUpsDisabled`, `NotOwner`, and the new ones).

## 6. Look and feel

- **(owner)** Clean, minimal, dark theme. Greyscale; no accent colour **(my call)**.
- **(owner)** Activity brightness. Each clickable area (navigation items, page panels,
  list rows) has a brightness that depends on how recently the user clicked it,
  measured in clicks on *other* areas, never in time:
  - The area just clicked is brightest: lighter grey background, near-white text.
  - Each click on a different area dims every earlier area one step.
  - Never-clicked or fully dimmed areas use the resting dark background and dimmer text.
  - **(my call)** Fully dim after 8 other clicks; dimmed text keeps readable contrast;
    keyboard activation counts as a click.
- **(owner)** The page remembers. Brightness survives reloads and navigation. List rows
  are keyed by ENFT, so recently opened ENFTs stand out on Browse.
- **(owner)** Two histories, **stored only in the browser**:
  - no wallet connected: lasts for the browser session;
  - wallet connected: tied to that address, persists between visits.
  - **(my call)** Connecting does not merge the session history into the wallet's.
- **(owner)** "Clear my activity history" is always available and clears whichever
  history is active.
- The owner approved an interactive mockup of this
  (`.superpowers/brainstorm/.../look-and-feel-v2.html`). Brightness must be reapplied
  after LiveView updates the page.

## 7. Testing

- Contract: Foundry tests for the getter, event, sweep (including transfer and top-up
  around the end time), and indefinite segments; Hardhat smoke test updated.
- Elixir: indexer against a local node or recorded logs; unit conversion; LiveView
  tests for public pages.
- Sepolia: both ENFT contracts deployed; then a manual pass with a real wallet and the
  real relayer SDK covering wrap → create → accrue → reveal → claim → donate →
  transfer → unwrap on the ETH contract, and faucet → create → claim on the mock
  contract. The work is not done until this pass succeeds.
- Browser: the brightness logic; an end-to-end pass of create → accrue → reveal →
  claim → donate → transfer in dev mode against a local Hardhat node, automated if
  practical, otherwise a written checklist that is run before calling the work done.

## 8. Order of work **(my call)**

1. Contract changes, the WETH wrapper, and tooling (section 3), verified locally.
2. FHE-in-browser spike (section 4.4), both implementations.
3. Phoenix app: indexer and public pages, then signer and transactions, then Tokens
   page with wrap/unwrap, then look and feel.
4. Sepolia deploys and the manual wallet pass.

## 9. Left to the builder

Library choices (Ethereum JSON-RPC and ABI handling in Elixir, JS bundling, charting),
schema, module layout, exact function and event names, polling intervals, how many dev
accounts to offer, pagination, and responsive layout details.
