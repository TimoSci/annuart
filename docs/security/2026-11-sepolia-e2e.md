# Sepolia end-to-end test: contracts and app

Run on 2026-11-23 against the Sepolia test network, through a local Erigon full node, with a
throwaway wallet and throwaway contracts. It covers what the local mock cannot show: the real
key service and relayer, the access list as the network enforces it, the FHE cost limits, real
WETH, gas estimation on a real chain, and the app in a browser against all of that.

These contracts are **not** the permanent Sepolia deployment. Their addresses are in
`deployments/sepolia-test.json`, which git ignores; `deployments/sepolia.json` does not exist.

## Result

The contracts behaved on Sepolia exactly as on the mock: 36 of 37 checks passed, and the one
that failed was a wrong expectation in the test script (it ignored the contract's cap on the
payout fee), since corrected and not rerun. The app did
not work on Sepolia as it stood. Two faults stopped it, both invisible on a local chain, and
both are fixed in the working tree and confirmed on Sepolia:

| ID | Severity | Fault | Status |
|---|---|---|---|
| S-1 | High (app unusable off the local chain) | Every encryption in the app failed with "Contract address is not a valid address": the relayer SDK accepts only checksummed addresses, and the page carries them in lower case. Create, donate and unwrap could not start. | Fixed in `web/assets/js/chain/fhe.js`, with a test |
| S-2 | Medium (a normal sequence fails and costs gas) | A claim, transfer or accrual sent straight after an accrual of the same token ran out of gas. The wallet estimates at the latest block's timestamp, where the token has nothing new to accrue, so the estimate leaves out the accrual the transaction really does. "Update accrual" then "Claim" reverted. | Fixed for the app in `web/assets/js/chain/actions.js`, with a test. Other callers (scripts, other front ends, a marketplace) must add headroom themselves |

One more thing to know, not a fault:

- **S-3 (note): the encryption library runs single-threaded in the browser.** It logs that the
  page lacks the `Cross-Origin-Opener-Policy` and `Cross-Origin-Embedder-Policy` headers that
  allow threads. Encryption and decryption still took about 3 seconds each.

## What the earlier reports left open, and what this run found

| Open item | Outcome on Sepolia |
|---|---|
| Access list enforced as the mock does (gating for production, F-C3-4a) | Yes. The key service refused every decryption by an address not on the list: a stranger, the creator of a token they do not own, a previous owner on the new distribution, and anyone on the remaining endowment. A probe contract confirmed that an FHE operation succeeds when the contract holds access to every operand and reverts when it does not. Nothing looser than the mock was seen |
| First 128-bit decryption through the real relayer (private rate) | Works, from the Hardhat plugin and from the browser. Creator, owner and a later owner read the rate; a stranger is refused; a previous owner still reads it, as designed |
| FHE limits (PR-2) | `HCULimit` v0.5.0: 20,000,000 per transaction and 5,000,000 in sequence, as in the mock. **The per-block cap is 2^48 − 1, in effect none**, so the shared-budget concern in PR-2 does not apply on Sepolia today. Every call ran within the limits |
| Private rate over wrapped ETH (not covered by the red-team review) | Mint, rate reveal, accrue, claim and transfer all work, and the amounts are exactly `floor(rate × weight × elapsed / 2^32)` |
| Automatic payout through canonical WETH's `withdraw` (C5-4) | Paid in ETH (`paidInWeth` false), owner's ETH rose by the payout minus the fee, no ETH left in the contract. Run once by the keeper script and once from the app by a second account |
| Decryption timing | Public decryption took about 2 seconds; a user decryption about 3 seconds |
| Zama versions | ACL v0.5.0, FHEVMExecutor v0.6.0, HCULimit v0.5.0, KMSVerifier v0.4.0, at the addresses the contracts are compiled against |

Not settled here: PR-1 (a zero rate on a schedule with no end) is a design decision, and PR-3
and the handle-reconstruction argument stay on paper, as decided before.

## Contracts: what was run

`scripts/sepolia-e2e.ts`, in stages, from three throwaway accounts: A (creator, payer), B
(owner), C (a stranger holding nothing).

- **Mock token ENFT.** Mint to B with two segments and donations on, top up, accrue. B
  decrypts the distribution and it equals rate × elapsed to the unit. Five decryptions that
  must be refused are refused. B claims and is paid exactly; B transfers to A; A reads the
  new distribution and B cannot.
- **Access probe** (`src/mocks/AclProbe.sol`, test only). Two fresh inputs added: allowed,
  and the sum decrypts to 42. A fresh input added to the remaining endowment of another
  contract's token: reverts.
- **Wrapped ETH.** Deposit, approve, wrap real Sepolia WETH; the balance decrypts to the
  amount wrapped. Mint, claim, then unwrap: request, public decryption, finalise; exactly the
  requested WETH comes back.
- **Automatic payout.** `mintAuto` with a start two hours back, then `scripts/keeper.ts`
  with `CONFIRM_KEEPER=sepolia`: one requested, one finished. The fee paid was a tenth of the
  payout, the contract's cap, not the larger fee set.
- **Private rate over cWETH.** As listed in the table above.

Gas used on Sepolia (its gas rules charge new storage heavily, so these are above the mock's):

| Call | Standard | Private rate |
|---|---|---|
| mint | 2,817,373 (mock token), 2,583,920 (cWETH), 2,819,962 (`mintAuto`) | 3,559,660 |
| accrue | 519,314 | 728,888 |
| claim | 1,812,590 (mock token), 1,702,996 (cWETH) | 2,022,306 |
| transfer | 902,447 | 1,227,196 |
| topUp | 1,360,164 | |
| wrap / unwrap request / finalise | 1,057,583 / 1,178,369 / 482,946 | |

The block gas limit was 200,000,000 and the base fee about 20 wei.

## App: what was run

A second instance of the app on port 4020, pointed at the node and the test contracts, with
its own database, driven in a browser. The wallet was a stand-in that implements the browser
wallet interface and signs with the throwaway keys; it took gas limits from the page as a
wallet does. The page carried no RPC URL, so every read went through the wallet, as in
production.

| Flow | Outcome |
|---|---|
| Browse without a wallet | Lists the ENFTs the contract stage made, indexed from the deploy block |
| Connect wallet | Works |
| Get test tokens, reveal balance | Mined in 34 s; balance correct |
| Create on the mock token | Failed (S-1). After the fix: 61 s to the new ENFT's page |
| Update accrual, reveal, claim | Claim reverted (S-2). After the fix, accrue then claim at once: both mined |
| Wrap 0.002 ETH, reveal | Works; balance correct to the unit |
| Unwrap 0.001 | All seven steps done in 95 s |
| Create with a private rate over cWETH, reveal the rate | Works; shows `0.0864 cWETH / day at 100%` in 3 s; accrue and claim work |
| Create with automatic payouts; second account triggers | Request, decryption and pay-out done in 44 s; "0.000072 ETH was paid to the owner" |
| Second account donates; owner transfers | Both work; the page follows the new owner in 49 s |
| Transactions page, reveal past amounts | Three create amounts revealed correctly |
| Nothing typed reaches the server | The amounts and rate typed into the forms do not appear in the server log |
| Browser console | No errors |

## The two fixes

**S-1.** `fheFromInstance` now passes the contract and user addresses through `getAddress`
before `createEncryptedInput`, as it already did for decryption. The dev mock accepts lower
case, which is why no local test caught it.

**S-2.** Claim, accrue, transfer, claim-to-ETH and the payout request now send with a gas
limit of the estimate, a fifth more, and 1,000,000 for one accrual. Measured: a claim estimated
at 1,307,544 needed 1,812,590 a block later; a transfer estimated at 585,036 needed 923,792.
Unused gas is not charged. A local chain estimates in the next block, so it cannot show this.

The contract is behaving as written; the fix is in the caller. Anything else that calls these
functions right after an accrual needs the same headroom. `scripts/keeper.ts` adds a fifth to
`finalizePayout` only; its `requestPayout` was fine in this run because nothing had accrued
that token in the same block, but it is exposed in principle.

## Not covered

- A real browser wallet (MetaMask or another). The stand-in follows the same interface, but
  wallet-specific behaviour, such as its own gas padding or how it shows a typed-data request,
  was not seen.
- Checklist items that need a person's eye: activity brightness, wording, layout.
- `web/e2e` and `web/assets/test/actions.local.test.js` were not rerun after the two fixes.
  The other suites pass: Hardhat 126, Foundry 258, browser-code 283.
- Long schedules on Sepolia (the 256-segment mint) and the per-transaction limit under load.
- Mainnet. Its limits and gas rules may differ from Sepolia's.

## Leftovers

- Test contracts stay on Sepolia; they cannot be removed and are listed nowhere permanent.
- The throwaway wallet holds about 0.0325 SepoliaETH and account B about 0.0101.
