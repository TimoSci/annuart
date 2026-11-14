# Contract Red Team Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to run this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Before the Sepolia deploy, attack `EndowmentNFT`, `AutoPayoutEndowmentNFT` and `ConfidentialWETH` as an adversary would, and produce a report of every way found to steal funds, learn hidden amounts, or break the contracts, each with a proof-of-concept test.

**Architecture:** Each attack is a hypothesis (ids `C2-1` … `C5-6`) with a test that tries to make it succeed. A test showing the attack fails is a regression guard; a test showing it succeeds is a finding. Stateful fuzzing covers what hand-written attacks miss. Nothing outside `test/redteam/` and `docs/security/` changes; fixes are a separate decision after the report.

**Tech Stack:** Foundry (`forge test`, fuzz and invariant tests, `FhevmTest` from `lib/forge-fhevm`), Hardhat with the FHEVM plugin (`npx hardhat test`, in-process network), Slither run through `uvx` without installing it.

**Spec:** `docs/superpowers/specs/2026-06-21-zk-endowment-nft-design.md` (sections 2, 3, 8), `docs/superpowers/specs/2026-11-13-automatic-payout-enft-design.md` (sections 2, 3, 4, 9). These define intended behaviour; an attack that contradicts them is a finding, and one they accept is recorded as "by design" with the section that accepts it.

## Global Constraints

- No transaction is sent to Sepolia, and no private key is read or handled. `.env` is never read. A Sepolia fork is used only if `SEPOLIA_RPC_URL` is already set in the shell environment.
- The owner's local chain (port 8545) and app (port 4000) are not used, restarted or stopped. All tests run on Foundry's EVM or Hardhat's in-process network (`npx hardhat test`, never `--network localhost`).
- Frozen: `src/`, `scripts/`, `tasks/`, `web/`, every existing test file, `foundry.toml`, `hardhat.config.ts`, `package.json`. A weakness found in any of them is reported, not fixed. Per-test Foundry settings use inline `/// forge-config:` comments.
- No dependency is added or installed. Web lookups never include the project's name, paths or the owner's details.
- New tests live in `test/redteam/`, named like the existing ones (`*.t.sol`, `*.hh.ts`). Foundry tests share `test/redteam/RedTeamBase.sol` (created by Task 2) instead of repeating deployment code.
- Test names carry the hypothesis id. Guard: `test_C2_8_<what>` / `it("C2-8: <what>")`. Finding: `test_FINDING_C2_8a_<what>` / `it("FINDING F-C2-8a: <what>")`.
- A guard test performs the attack for real and asserts a specific outcome: a named revert, a decrypted value, a balance. A test that would also pass if the attack were never attempted is a defect.
- A finding test passes while the weakness exists: it asserts the attack's effect, and carries a `// SECURE EXPECTATION:` comment saying what a fixed contract would do instead. The whole suite therefore stays green.
- Finding ids are `F-<hypothesis id>` with a letter when one hypothesis yields several (`F-C2-8a`). By-design ids are `D-<hypothesis id>`.
- The report is `docs/security/2026-11-red-team-report.md`. Every task records its results there: one row per hypothesis in **Hypotheses tested** (result: Finding, Held, By design, or Not testable locally), one row plus a details entry per finding, one row per by-design item.
- Every finding has: id, severity, affected contract and function, PoC test name, impact in plain words, and a suggested fix.
- Severity: **Critical** (funds stolen or locked for others; the hidden endowment readable by someone not entitled), **High** (owner's own funds lockable by a third party; a hidden amount forced public without the owner opting in), **Medium** (griefing with real cost, keeper drain beyond what the spec accepts), **Low** (cosmetic, self-harm only, surprising but harmless behaviour).
- Commits go on branch `security/red-team`, with subjects starting `test(redteam):` or `docs(security):`, each ending with the line `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`. Nothing is pushed.

## Threat Model

**Assets**

| Asset | Where | Who may touch it |
|---|---|---|
| Endowment funds | NFT contract's balance in the confidential token | Released only through the schedule, to the current owner |
| Remaining endowment (amount) | `endowmentRemaining` handle | Nobody but the contract |
| Claimable balance (amount) | `distribution` handle | Contract and current owner |
| Pending payout WETH/ETH | Wrapper, then NFT contract | Recipient and requester fixed at request time |
| Keeper's gas money | Keeper's account | Keeper |

**Adversaries:** an outsider with no ENFT; a creator; a donor; the current owner; a previous owner; an approved ERC-721 operator; a payout requester or finaliser; a contract as owner, recipient or requester (re-entry, gas burning, refusing ETH); a block proposer (ordering, small timestamp skew).

**Trusted, out of scope:** the Zama coprocessor, KMS and relayer; the OpenZeppelin and FHEVM libraries' internals (their integration is in scope); the canonical WETH contract.

## Review Focus

Leads from reading the code. None is confirmed; each belongs to a hypothesis below.

- **Keeper drain (C4-2).** The endowment is hidden, so a keeper cannot tell that a payout will be zero. An unfunded ENFT with payouts on and a large advertised fee costs the keeper two transactions and pays nothing, because the fee is capped at a tenth of the payout. The spec accepts the caller's risk (automatic-payout spec 4.5) and the keeper skips a token whose last payout was zero; the open question is what an attacker can still extract.
- **Unbounded schedule length (C4-1).** `mint` accepts any number of segments, and every accrual, claim, transfer and payout request loops over all of them. A long enough schedule could make a token impossible to claim or transfer.
- **Claim amounts are inferable (C3-3).** The schedule and every accrual time are public, so a claim's amount can be computed by anyone unless the endowment has run out.
- **Donations after the endowment runs dry (C4-8).** `topUp` does not accrue first. If nobody has accrued since the endowment ran out, a donation is released at once against the backlog; if someone accrued just before, it is streamed. The outcome depends on transaction order.
- **Mock and real FHE differ (C5-3).** Computation limits per transaction and decryption timing on Sepolia are not reproduced locally, so a path that passes locally could revert there.

---

### Task 1: Baseline and tooling

**Files:** Create `docs/security/2026-11-red-team-report.md`.

- [ ] **Step 1:** Create the report with these sections, in this order: `## Scope and versions`, `## Summary` (left empty for Task 10), `## Findings` (table: ID, Severity, Title, Contract.function, PoC test, Status), `## Finding details`, `## By design` (table: ID, Behaviour, Spec reference, User-facing wording needed), `## Hypotheses tested` (table: Hypothesis, Result, Tests), `## Coverage gaps`, `## Sepolia-only checks`, `## Access table`.
- [ ] **Step 2:** Run `forge test` and `npx hardhat test`; record pass counts and the commit hash under Scope and versions. A failure is reported as BLOCKED, not worked around.
- [ ] **Step 3:** Run `forge coverage` for `src/` excluding `src/mocks/` (try `--ir-minimum` if it fails to compile). List every uncovered line and branch under Coverage gaps, each with the task that owns its function (see the hypothesis lists below). If coverage cannot be produced within 15 minutes of trying, say so there and list instead the functions and branches no existing test name mentions.
- [ ] **Step 4:** Run `uvx --from slither-analyzer slither . --filter-paths "node_modules|lib|src/mocks"`. Nothing is installed permanently; if it cannot run, record why and move on. Triage each result in the report as finding, false positive (with the reason), or by design.
- [ ] **Step 5:** Record the exact versions of `@fhevm/solidity`, `@openzeppelin/confidential-contracts`, `@openzeppelin/contracts`, `forge-fhevm` and solc. Look up published security advisories and changelog security notes for those versions, and whether the FHEVM library version matches what Zama currently runs on Sepolia. Record sources. Anything that cannot be confirmed goes under Sepolia-only checks.
- [ ] **Step 6:** Write the Access table: for every state-changing function in the three contracts, each encrypted handle it creates or stores and every address granted access to it (`allow`, `allowThis`, `allowTransient`, `makePubliclyDecryptable`), including grants made inside the token and wrapper during the call. Cite `file:line` for each grant.
- [ ] **Step 7:** Commit.

### Task 2: Theft through deposits and claims

**Files:** Create `test/redteam/RedTeamBase.sol`, `test/redteam/Theft.t.sol`.

`RedTeamBase` is an abstract `FhevmTest` that deploys, in `setUp`: a `MockConfidentialToken` with an `EndowmentNFT` over it; a `MockWETH9`, a `ConfidentialWETH` over it, and an `AutoPayoutEndowmentNFT` over that. It names at least five actors and offers helpers to give an actor tokens (mock mint; ETH → WETH → cWETH), authorise an NFT contract as operator, encrypt an amount for a sender and contract, mint and mintAuto with chosen parameters, top up, request and finalise a payout, and decrypt a handle. Later tasks extend it; they do not copy it.

- [ ] **C2-2 Under-funded deposits.** Mint and topUp with an encrypted amount above the sender's balance, and with a zero balance. Pass: the token is credited exactly what the transfer moved, never the amount asked for, and no other token's funds become claimable through it.
- [ ] **C2-3 Spending someone else's tokens.** A victim has authorised the NFT contract as operator. An attacker calls `mint` and `topUp`. Pass: only the caller's own tokens can be pulled.
- [ ] **C2-4 Encrypted input misuse.** Replay another account's `(handle, inputProof)`; use a proof made for a different contract; pass an existing handle (a victim's balance, another token's `distribution` or `endowmentRemaining`) as the external input. Pass: all revert.
- [ ] **C2-5 Claim paths.** Claim as non-owner, approved operator and previous owner; claim twice in one block; re-enter `claim`, `requestPayout`, `mint`, `mintAuto` and `topUp` from `onERC721Received` and from an ETH `receive`. Pass: no path pays anyone but the current owner, and none pays twice.
- [ ] **C2-6 Arithmetic limits.** On the mock token, mint close to `type(uint64).max` and drive `endowmentRemaining + received` and `distribution + actual` toward overflow; fill the NFT contract's balance so that later deposits are reduced to zero. Pass: no wrap-around. Record the silent-zero behaviour and state whether it can occur with cWETH.
- [ ] Record results in the report; run `forge test`; commit.

### Task 3: Payout attacks

**Files:** Create `test/redteam/Payout.t.sol`. Extend `test/redteam/RedTeamBase.sol` if a helper is missing.

- [ ] **C2-7 Payout request ids.** Two tokens with zero claimable balance request payouts in the same block, then again across several intervals; a token requests again right after a zero payout; tokens in a zero-rate segment. Pass: every request gets a distinct id and none reverts on the wrapper's uniqueness `assert`.
- [ ] **C2-8 Finalising a payout.** Forged proof; wrong cleartext; a valid proof for a different handle; a replayed proof on a later payout; finalise twice; finalise after a third party finalised at the wrapper; an attacker unwraps their own tokens *to* the NFT contract before finalising. Pass: only the true amount is ever paid, once.
- [ ] **C2-9 ETH and WETH accounting.** The fee cap (`amount / 10`, including amounts below 10 wei of cWETH units and fee = `type(uint128).max`), requester = recipient, recipient = the NFT contract, the token, WETH. ETH, WETH and cWETH sent directly to the NFT contract: none can be extracted by anyone and none blocks or changes a payout. Pass: after each finalise the contract's ETH and WETH balances equal what was deliberately donated.
- [ ] **C2-10 Starving the payment.** Search gas limits around the `InsufficientGas` boundary for a value where the fee payment fails and the recipient payment succeeds, or the ETH payment fails and the WETH fallback runs. Recipients and requesters that revert, burn all gas, return large data, or re-enter. Pass: a finaliser cannot redirect the fee or force a WETH payment by choosing gas.
- [ ] Record results in the report; run `forge test`; commit.

### Task 4: Solvency invariant

**Files:** Create `test/redteam/Solvency.invariant.t.sol`. Extend `test/redteam/RedTeamBase.sol` if a helper is missing.

- [ ] **C2-1 Solvency invariant.** Stateful fuzz over both NFT contracts with at least four actors and three tokens per contract. Handlers: mint, mintAuto, topUp, accrue, claim, transferFrom, setAutoPayout, requestPayout, finalizePayout, time warp. After every call, using the test harness's decryption:
  - the contract's token balance ≥ Σ(`endowmentRemaining` + `distribution`) over its tokens;
  - for each contract, tokens paid out + pending payouts + balance held = tokens deposited;
  - no token has paid out more than was deposited into it;
  - the automatic contract's ETH and WETH balances are zero when no payout is pending.
- [ ] If Foundry's invariant runner cannot be used with `FhevmTest`, use a fuzz test that takes a seed and runs a bounded random sequence of the same handlers, and say so in the report.
- [ ] Run at least 256 sequences of depth 30 or more. Record the run counts, the number of calls per handler, and how many reverted, so that a handler that never succeeds is visible.
- [ ] Record results in the report; run `forge test`; commit.

### Task 5: Confidentiality

**Files:** Create `test/redteam/Confidentiality.t.sol`, `test/redteam/Confidentiality.hh.ts`. Extend `test/redteam/RedTeamBase.sol` if a helper is missing.

- [ ] **C3-1 Access table holds.** For each role (creator, donor, previous owner, approved operator, requester, finaliser, outsider) after each kind of action (mint, topUp, accrue, claim, transfer, settle at schedule end, requestPayout, finalizePayout), check access to `endowmentRemaining` and to the current `distribution`. Pass: only the current owner and the contract may read `distribution`; only the contract may read `endowmentRemaining`; the only publicly decryptable handles are payout unwrap amounts. In Hardhat, confirm through the plugin's user decryption that the owner can decrypt `distribution` and that the creator, a previous owner and an outsider are refused for both handles.
- [ ] **C3-2 Oracles on the remaining endowment.** For each role, enumerate every value they can decrypt that depends on `endowmentRemaining` (capped accrual, settlement, top-up `received`, self-transfer, public payouts) and write down exactly what each reveals. Finding if anything beyond what spec section 3 of each design accepts reaches anyone.
- [ ] **C3-4 Handle reuse.** Establish from the FHEVM library and host contract source how result handles and trivial-encryption handles are derived. Then look for any state cycle (claim → transfer → transfer back, zero balances across tokens, settlement, zero-rate segments) where an address keeps access to a handle that later holds a value it should not read. Pass: every retained handle holds a value that address already knew.
- [ ] **C3-5 Forced disclosure.** Without the owner opting in: `requestPayout` with payouts off; `setAutoPayout` by an approved operator or a previous owner; `mintAuto` settings surviving a transfer; staged settings left behind by a reverted `mintAuto`; the token's `requestDiscloseEncryptedAmount` on any handle an attacker can reach. Pass: no amount of a token whose current owner never enabled automatic payouts becomes public.
- [ ] Record results in the report; run `forge test` and `npx hardhat test`; commit.

### Task 6: Public-data inference and user-facing claims

**Files:** Create `test/redteam/Inference.t.sol`.

- [ ] **C3-3 Inference from public data.** In a test, run a scripted history (mints, accruals, claims, transfers, a top-up, an endowment that runs dry, a schedule that ends) and predict every claim amount from events, public views and block timestamps only. Compare with the decrypted truth. Report which amounts are predicted exactly, which are bounded, and which are hidden. Then read `README.md` and the user-facing text in `web/lib/annuart_web/live/` and list every statement that says more is hidden than is.
- [ ] **C3-6 Plaintext on the wire.** Mint, top up, claim and transfer with distinctive amounts while recording logs; search every event topic and data word, and every return value, for those amounts. Pass: the only cleartext amounts anywhere are fees, automatic payout amounts, wrap and finalised-unwrap amounts, and mock mints.
- [ ] **C4-7 Abuse without a bug.** Unfunded ENFTs presented as funded; look-alike names; unsolicited ENFTs sent to victims; a seller claiming, or requesting a payout, just before a sale; an approval phished from an owner. For each, state what the contract allows, what the app shows a user, and what warning is missing. Demonstrate the seller-front-run and the unfunded mint in tests.
- [ ] Record results in the report; run `forge test`; commit.

### Task 7: Breaking the contracts

**Files:** Create `test/redteam/Griefing.t.sol`, `test/redteam/Schedule.fuzz.t.sol`. Extend `test/redteam/RedTeamBase.sol` if a helper is missing.

- [ ] **C4-1 Gas bombs.** Measure gas of mint, accrue, claim, transferFrom and requestPayout for 1, 10, 100 and 1000 segments, and find the largest schedule one mint can create. Look up the current Sepolia block gas limit (if it cannot be confirmed, report against both 30 and 60 million). Finding if a token that can be minted can become unclaimable or untransferable, or if a creator can hand a recipient such a token. Record the size of `scheduleOf` at that length for the web indexer.
- [ ] **C4-3 Stuck payouts.** A payout is requested and never finalised. List what still works for the owner (claim, transfer, settings) and what is locked. A griefer requests with fee zero and never finalises. Pass: anyone can finalise, and the owner's manual claim is never blocked. Automatic-payout spec section 9 accepts the pause itself.
- [ ] **C4-4 Schedule mathematics.** Fuzz `Schedule.integrate`: additive over adjacent intervals, monotonic in `to`, zero outside the window, never above the largest rate × elapsed time, saturating without revert. Fuzz `scheduleEnd` against the mint checks: any schedule `mint` accepts has an end that is either `type(uint64).max` with an indefinite last segment or the exact sum.
- [ ] **C4-5 Time edges.** Start in the past, start far in the future, accrual exactly at a segment boundary and exactly at the end, zero-rate segments. Payout requests at exactly `last + interval`, one second before, at the schedule end, after the end (one final request, then `NothingLeft`), with the interval changed between requests, and with 15 seconds of proposer skew. Pass: no interval is skipped or doubled, and no funds are left unreachable.
- [ ] **C4-6 ERC-721 edges.** Transfer to self, to the NFT contract, to the token, to WETH; approved-operator transfers; `safeTransferFrom` to a receiver that re-enters `accrue`, `transferFrom` and `setAutoPayout`. Record where funds become permanently stuck and whether that is self-harm only.
- [ ] **C4-8 Donation order dependence.** An endowment runs dry with no accrual since. Compare: donation then accrue, against accrue then donation. Record how much of the donation is claimable at once in each case, who can choose the order, and whether the app's donate flow or the spec tells donors.
- [ ] Record results in the report; run `forge test`; commit.

### Task 8: Keeper

**Files:** Create `test/redteam/keeperDrain.hh.ts`.

- [ ] **C4-2 Keeper drain.** Mint N unfunded tokens with payouts on, the minimum interval and a large fee, and run the keeper's pass logic (as `test/keeper.hh.ts` does) over several intervals. Report keeper gas spent per token per interval against the attacker's cost per token, with the default settings, with `KEEPER_MIN_FEE`, and with the option that includes zero-payout tokens. Also: a fee lowered just before the request, settings toggled around the request, a competing requester front-running the keeper, an owner claiming just before the request, recipients that burn the whole payment gas.
- [ ] **C5-5 Keeper script review.** Read `scripts/keeper.ts` and `tasks/keeper.ts` for: where the key comes from and whether it can reach a log; behaviour on a reverting token, on a token whose finalise always fails, and on malformed RPC responses; whether one bad token stops the pass. Demonstrate in a test anything that stops or stalls a pass.
- [ ] Record results in the report; run `npx hardhat test`; commit.

### Task 9: Deployment and environment

**Files:** Create `test/redteam/deploy.hh.ts` only if a gap needs a demonstration; create `test/redteam/WethGas.t.sol`.

- [ ] **C5-1 Deploy script as a target.** Read `scripts/deploy.ts`, `tasks/deployGuard.ts`, `tasks/preflight.ts` and their tests. For each wrong input, find the existing test that proves it is refused before anything is sent, or write one: a non-WETH address, a wrapper over another token, the mock token on a production chain, a wrong chain id, a reused deployments file, a missing confirmation variable. The contract itself only checks that the underlying is non-zero, so the script is the only guard.
- [ ] **C5-2 Configuration.** Confirm the addresses `ZamaEthereumConfig` selects for chain 11155111 against Zama's published Sepolia addresses, and that solc 0.8.27 with EVM version cancun is valid on Sepolia. Note that Hardhat (the deploy path) compiles with 800 optimizer runs and Foundry (most tests) with 200. Record sources; what cannot be confirmed goes under Sepolia-only checks.
- [ ] **C5-3 Mock versus Sepolia.** List every result in the report that depends on the local mock: per-transaction FHE computation limits on the heaviest paths (`requestPayout`, transfer of an automatic token, `mint`, `topUp`), decryption delay, proof formats. Find out whether the library version in use enforces a per-transaction limit and whether the local test environments enforce it. For each item write the manual check the owner runs on Sepolia after deploying.
- [ ] **C5-4 Real WETH gas.** `MockWETH9.withdraw` pays with a 2300-gas `transfer`, as the canonical WETH9 does. In `WethGas.t.sol`, finalise a payout through it and measure the gas `receive()` uses. Pass: it fits in 2300 with margin. If `SEPOLIA_RPC_URL` is set in the environment, repeat against the canonical Sepolia WETH on a fork; otherwise add the check to Sepolia-only checks.
- [ ] **C5-6 No admin, no fix.** Confirm there is no owner role, pause, upgrade path or self-destruct in the three contracts. State in the report what that means: any Critical or High finding must be resolved before deploying, and a fix after deploying means a new contract and no migration for existing ENFTs.
- [ ] Record results in the report; run `forge test` and `npx hardhat test`; commit.

### Task 10: Report and decision

**Files:** Modify `docs/security/2026-11-red-team-report.md`.

- [ ] **Step 1:** Check the report against this plan: every hypothesis `C2-1` … `C5-6` has a row in Hypotheses tested; every finding row has a details entry with all required fields and a PoC test that exists under that exact name; every by-design row cites a spec section. Fix gaps in the report; do not write new attack tests.
- [ ] **Step 2:** Run `forge test` and `npx hardhat test` once more and record the counts and commit hash next to the baseline counts.
- [ ] **Step 3:** Write the Summary in plain language for the owner: findings by severity, what an attacker could actually do, the by-design behaviours users should be warned about, the checks that can only be done on Sepolia, and a go / no-go recommendation. Go only with no open Critical or High finding. Proposed fixes are listed for the owner to approve; none is applied.
- [ ] **Step 4:** Commit.
