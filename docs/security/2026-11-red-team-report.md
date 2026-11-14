# Red team report: EndowmentNFT, AutoPayoutEndowmentNFT, ConfidentialWETH

## Scope and versions

In scope: `src/EndowmentNFT.sol`, `src/AutoPayoutEndowmentNFT.sol`, `src/ConfidentialWETH.sol`, `src/libraries/Schedule.sol`. Out of scope (trusted): Zama coprocessor/KMS/relayer, OpenZeppelin and FHEVM library internals (integration is in scope), canonical WETH.

| Item | Value |
|---|---|
| Baseline commit | `8c80d58` (branch `security/red-team`, working tree clean) |
| `forge test` | 117 passed, 0 failed, 0 skipped (4 suites) |
| `npx hardhat test` | 78 passing, 0 failing (default in-process network) |
| solc | 0.8.27 (Foundry: optimizer 200 runs, cancun; Hardhat: optimizer 800 runs, cancun) |
| forge | 1.7.1 (4072e48705, 2026-05-08) |
| `@fhevm/solidity` | 0.11.1 (installed and pinned in package.json) |
| `@openzeppelin/confidential-contracts` | 0.4.1 (installed and pinned) |
| `@openzeppelin/contracts` | 5.6.1 installed (package.json range `^5.6.1`) |
| `forge-fhevm` (lib/forge-fhevm) | git `ff2b790db8cdc34894754d670b174b2b7e27e373`, 2026-05-27, "Implement helper function to get recorded logs with processed fhe events (#16)"; no tag on that commit |
| `@fhevm/mock-utils` / hardhat plugin | 0.4.2 / ^0.4.2 |

### Dependency advisories (looked up by library name and version only)

- `@openzeppelin/confidential-contracts` GHSA-29h2-jr22-frmh, "Unchecked ACL on a returned handle leaks private data in VestingWalletConfidential and ERC7984", severity differs by source: **Moderate** on the repository advisory page (no CVSS shown), **High**, CVSS v4 7.1 (`CVSS:4.0/AV:N/AC:L/AT:N/PR:L/UI:N/VC:H/VI:N/VA:N/SC:N/SI:N/SA:N`), CWE-284, on the GitHub Advisory Database page (https://github.com/advisories/GHSA-29h2-jr22-frmh); treat it as High until settled. Published 2026-07-31. Affected: below 0.3.2, 0.4.0-rc.0 up to below 0.4.2, 0.5.0-rc.0 up to below 0.5.2. **The installed 0.4.1 is in the affected range; patched in 0.4.2.** Two places: VestingWalletConfidential (not used here) and the ERC7984 `*AndCall` transfer callback, where the `ebool` a recipient returns drives refund logic without an ACL check on it, so a malicious recipient contract can learn the plaintext of an `ebool` the token can access (limited to `ebool` handles; advisory says no loss of funds). The `*AndCall` functions are public on ConfidentialWETH (inherited), so the path is reachable even though neither NFT contract uses it. Which `ebool`s cWETH can access (the `success` flags of transfers) and what they reveal is left to Task 5 (C5). Source: https://github.com/OpenZeppelin/openzeppelin-confidential-contracts/security/advisories/GHSA-29h2-jr22-frmh. Fix commits: VestingWalletConfidential `93e75ceed2b9648f53f9d133f431064353456805` (PR #423); ERC7984 transfer callback `fe0863af2c9dce7614acce98720a913bf6a767a5` (PR #428), with follow-up `ee47edf189ab681cebdad18bfb53dee541987be2` (PR #431, permits an uninitialized returned handle). Under https://github.com/OpenZeppelin/openzeppelin-confidential-contracts/commit/<sha> and .../pull/<n>; a later task should read #428 and #431 to judge reachability here.
- `@openzeppelin/confidential-contracts` GHSA-hqf9-8xv5-x8xw (CVE-2026-73645), wrapper silently fails to mint once total supply is full; affected <= 0.3.0, patched 0.3.1. Does not affect 0.4.1. With rate 1e9 the wrapper fills at about 18.4 billion WETH, far above supply. Source: https://github.com/OpenZeppelin/openzeppelin-confidential-contracts/security/advisories/GHSA-hqf9-8xv5-x8xw (list: .../security/advisories)
- `@fhevm/solidity` / zama-ai/fhevm: "There aren't any published security advisories." Source: https://github.com/zama-ai/fhevm/security/advisories. Release notes (https://github.com/zama-ai/fhevm/releases) mention only Rust dependency advisories and fuzzing fixes in the coprocessor, nothing about `@fhevm/solidity` 0.11.1.
- `@openzeppelin/contracts`: the advisory list (https://github.com/OpenZeppelin/openzeppelin-contracts/security/advisories, first page) shows nothing published in 2026; latest is GHSA-9rcw-c2f9-2j55 (2025-07-17, `Bytes.lastIndexOf`, Low). Only the first page was read and per-advisory version ranges were not opened; no OZ `Bytes`/`Base64` function is used by in-scope code (ERC721, ReentrancyGuard, SafeERC20 only), so none is expected to apply. Unconfirmed for page 2 (older advisories).
- forge-fhevm: repo has a SECURITY.md; no advisory lookup done (test harness only, not deployed).

## Summary

<!-- Left for Task 10. -->

## Findings

| ID | Severity | Title | Contract.function | PoC test | Status |
|---|---|---|---|---|---|
| F-C2-4a | Low | Deposits accept an existing handle with an empty input proof | `EndowmentNFT.mint`, `EndowmentNFT.topUp`, `AutoPayoutEndowmentNFT.mintAuto` (all through `_mintEndowment`/`topUp` calling `FHE.fromExternal`) | `test_FINDING_C2_4a_ownDistributionAsInput_acceptedWithoutProof`, `test_FINDING_C2_4a_previousOwnerOldDistributionAsInput_accepted`, `test_FINDING_C2_4a_operatorTransientHandleAsInput_accepted` (`test/redteam/Theft.t.sol`) | Open |

## Finding details

### F-C2-4a: Deposits accept an existing handle with an empty input proof

- **Severity:** Low (surprising but harmless: only the caller's own funds move, and the caller learns nothing it could not already learn).
- **Affected:** `EndowmentNFT.mint` and `EndowmentNFT.topUp`, and `AutoPayoutEndowmentNFT.mintAuto` through `_mintEndowment` (ET:82, ET:219).
- **PoC tests:** `test_FINDING_C2_4a_ownDistributionAsInput_acceptedWithoutProof`, `test_FINDING_C2_4a_previousOwnerOldDistributionAsInput_accepted`, `test_FINDING_C2_4a_operatorTransientHandleAsInput_accepted` in `test/redteam/Theft.t.sol`.
- **What happens:** `FHE.fromExternal(h, proof)` with `proof.length == 0` does not verify an input. It treats `h` as an existing handle and checks only that `msg.sender`, here the NFT contract's caller, is allowed on it (`@fhevm/solidity` FHE.sol:8598-8609; a zero `h` becomes a trivial 0). The NFT contract then calls `FHE.allowTransient(amount, token)` (ET:83, ET:220), which the host ACL allows only if the NFT contract itself holds access (`test_C2_4_existingHandleAsInput_reverts` sees `ACL.SenderNotAllowed(enft)` when it does not). The amount then goes into `confidentialTransferFrom(msg.sender, this, amount)`, whose `T:147` check the NFT contract passes for the same reason. So the usable handles are exactly those on which both the caller and the NFT contract hold access, persistent or transient in the same transaction. Funds always come from the caller (`from` is `msg.sender`, ET:84, ET:221); the handle only sets the amount.
- **The usable set, from the Access table and the tests, and whether the caller already knows the value** (a lower bound — see the caveat below and C3-4 in Task 5)**:**
  - The caller's own tokens' current `distribution` (ET:98-99, :238, :278, :291, :257): known, since the caller is the owner and can user-decrypt it. Tested (`..._ownDistributionAsInput_...`).
  - `distribution` handles from tokens the caller owned before (never revoked): known, because the caller held them while owner. Tested (`..._previousOwnerOldDistributionAsInput_...`): the old handle still carries `persistAllowed` for the previous owner, it is accepted, and the new owner's distribution is untouched.
  - The shared trivial-zero handle (`asEuint64(0)`, ET:90, :236): known (0).
  - `transferred`/`received` from the caller's own deposits (to the NFT contract: T:305-307; the caller is `from`): known. The caller can decrypt it, and as creator it chose the amount.
  - `transferred` from the caller's own claims (from the NFT contract to the owner: T:305-306): known, for the same reason.
  - The payout `unwrapAmount_` (W:218): public, but the caller holds no ACL on it (public decryption is not `isAllowed`), so it is not usable.
  - `endowmentRemaining`, `actual`, and the NFT contract's own balance: not reachable by passing the **stored** handle directly — the caller holds no ACL on it (`SenderNotAllowedToUseHandle`, tested).
  - **Caveat (lower bound, not the whole set):** the list above counts only handles the caller already holds ACL on. The set of handles a caller can *use at call time* is larger, because a handle derived purely from inputs a party itself holds can be reached by other means available to that party; whether and how that extends to `endowmentRemaining`/`actual` (for example for a creator, from data it already has) is a confidentiality question assessed under C3-4 in Task 5, not on the deposit path here. It does not change this finding's Low severity: on the deposit path the funds still come only from the caller (`from` is `msg.sender`), and the deeper question is whether such access could be used to disclose a value to others without the owner opting in, which Task 5 (C3-4, C3-5) owns.
  - **Transient grants in the same transaction:** the token grants the caller transient access to `transferred` in `confidentialTransferFrom` (T:138, T:150) and to `wrappedAmountSent` in `wrap` (W:88). The NFT contract also holds `transferred` only when it is `from` or `to`. It is `from` only in its own calls, where the caller of the token is the NFT contract. So the case that remains is a caller acting as operator of a third party X, moving X's tokens to the NFT contract. Tested (`..._operatorTransientHandleAsInput_...`). The caller holds only a transient grant on that `transferred` (no `persistAllowed`), so it cannot user-decrypt it. Its value is the amount the caller chose, or 0 if X was short, and that value now shows up in the caller's own balance. **The caller did not know this value beforehand.** It learns one bit about X's balance (at least the amount, or not), and X's tokens sit in the NFT contract's pool, credited to no token. The operator right X granted already gives the caller the same bit and the same power over X's funds: it could transfer from X to itself and decrypt its own balance. So the deposit path adds nothing beyond that right, and the severity is left at Low. `wrap` to the NFT contract gives a plaintext-derived amount the caller chose, which is known.
- **Impact in plain words:** anyone may size a deposit by a handle they can already use, instead of a fresh encrypted input. They pay it themselves. Nobody else's funds move through the NFT contract, and no value is revealed that the caller could not already obtain.
- **Suggested fix:** in `_mintEndowment` and `topUp`, `if (inputProof.length == 0) revert EmptyInputProof();` before `FHE.fromExternal`. Alternatively keep the behaviour and document it. It is documented upstream behaviour of `FHE.fromExternal`, meant for composability, since a contract caller can then pass a handle it computed. The owner can weigh rejecting empty proofs (simpler, closer to the spec, which mentions only `fromExternal(enc, proof)` at spec lines 105 and 128) against keeping it for contract callers that deposit computed amounts.

## By design

| ID | Behaviour | Spec reference | User-facing wording needed |
|---|---|---|---|
| D-C2-2 | An under-funded `mint` (or `mintAuto`) succeeds and produces a token whose endowment is zero (the token transfer is all-or-nothing, so asking for more than the creator holds moves nothing). The owner, and any later buyer, cannot tell: the endowment is readable by nobody, and the token looks the same as a funded one until accruals keep coming back zero. Only the creator knows (they hold `received`). No other token's funds become reachable through it (`test_C2_2_mintAboveBalance_creditsZeroAndCannotDrawOnPool`). | Endowment spec §2 "Endowment visibility", §3 (exhaustion observable only retroactively to the owner), §8 "Under-funding at mint/top-up → use the actual transferred handle" | Yes: a recipient or buyer must be told that the endowment cannot be verified from the token, that a token can hold nothing, and that only the creator's word (or a disclosure the creator chooses to make) vouches for it. |

## Hypotheses tested

| Hypothesis | Result | Tests |
|---|---|---|
| C2-2 Under-funded deposits (mint and topUp above the sender's balance, zero balance, never-funded sender) | Held | `test_C2_2_mintAboveBalance_creditsZeroAndCannotDrawOnPool`, `test_C2_2_topUpAboveBalance_creditsZero`, `test_C2_2_zeroBalance_creditsZero`, `test_C2_2_neverFundedSender_reverts` (`test/redteam/Theft.t.sol`). The token is credited exactly what moved: zero when the balance is short (all-or-nothing, not the part held), and a never-funded sender reverts `ERC7984ZeroBalance`. An under-funded token pays nothing after its schedule ends while a funded neighbour in the same pool is paid in full. Owner cannot detect the empty token: see D-C2-2. |
| C2-2a Schedule validation at deposit (empty schedule, zero-duration segment) | Held | `test_C2_2a_mintEmptySchedule_reverts`, `test_C2_2a_mintZeroDurationSegment_reverts` (covers EndowmentNFT.sol:77 and :112, confirmed by `forge coverage --ir-minimum` on this suite). Zero-duration is refused also when it is not the first segment. `_validName` line :132 (Coverage gaps, Task 2): a source-map artefact. Under `test_name_acceptsAllowedCharactersAndFullLength` alone, coverage reports :131 hit 2, :132 hit 0, :133 hit 14; :132 is a straight-line assignment between them, so it ran. |
| C2-2b Pre-funding a token id that does not exist yet (topUp on a nonexistent token) | Held | `test_C2_2b_topUpFutureId_reverts`: `topUp(1)` before any mint reverts `NonexistentToken` (covers EndowmentNFT.sol:214); the token later minted as id 1 holds only its own deposit. |
| C2-2c `topUpsAllowedOf` agrees with the topUp gate | Held | `test_C2_2c_topUpsAllowedOf_matchesTopUpGate` (covers EndowmentNFT.sol:194-195). Note: for a nonexistent token it returns false instead of reverting, unlike `nameOf`/`scheduleOf` (but like `distributionHandle`/`endowmentHandle`); harmless, not a finding. |
| C2-3 Spending someone else's tokens (victim made the NFT contract an operator; attacker calls mint, mintAuto, topUp) | Held | `test_C2_3_attackerMintCannotPullOperatorVictimFunds`, `test_C2_3_attackerTopUpCannotPullOperatorVictimFunds`, `test_C2_3_attackerMintAutoCannotPullOperatorVictimCweth`; also `test_C2_2_neverFundedSender_reverts` (revert names the attacker as holder). Every deposit pulls from `msg.sender` (ET:84, ET:221); no function takes a holder address. Victim balances unchanged on mock and cWETH. |
| C2-4 Encrypted input misuse (replayed proof, proof for another contract, existing handle as input) | Held | `test_C2_4_replayVictimInput_reverts` (`InvalidSigner`, before and after the victim used the input; the used input handle with an empty proof reverts `SenderNotAllowedToUseHandle`), `test_C2_4_inputForOtherContract_reverts` (inputs for the other NFT contract or for the token: `InvalidSigner`), `test_C2_4_existingHandleAsInput_reverts` (victim's balance, another token's `distribution` and `endowmentRemaining`: `SenderNotAllowedToUseHandle`; the attacker's own balance handle: `ACL.SenderNotAllowed(nft)` at the transient grant). |
| C2-4a A handle both the caller and the NFT contract may use, passed with an empty proof | Finding (F-C2-4a, Low) | `test_FINDING_C2_4a_ownDistributionAsInput_acceptedWithoutProof`, `test_FINDING_C2_4a_previousOwnerOldDistributionAsInput_accepted`, `test_FINDING_C2_4a_operatorTransientHandleAsInput_accepted`. Accepted without a proof by `FHE.fromExternal` (FHE.sol:8598-8609), contrary to C2-4's "all revert". The caller's own current and past `distribution` handles and a same-transaction transient `transferred` (caller acting as a third party's operator) were all accepted. The funds always came from the caller. See the details entry for the usable set and its lower-bound caveat (C3-4). |
| C2-5 Claim paths (non-owner, approved operator, previous owner, twice in a block, re-entry from onERC721Received and ETH receive) | Held | Non-owner: existing `test_claim_onlyOwner` (test/EndowmentNFT.t.sol, read: bob claims alice's token, `NotOwner`). New: `test_C2_5_claimByApprovedOperator_reverts` (`approve` and `setApprovalForAll`), `test_C2_5_claimByPreviousOwner_reverts`, `test_C2_5_claimTwiceSameBlock_paysOnce`, `test_C2_5_reenterFromMintReceiver_blocked` (claim, topUp, mint from the mint callback, on a schedule that started 2000 s before and still runs, so a claim would pay all 500 and a topUp would be accepted: all `ReentrancyGuardReentrantCall`), `test_C2_5_reenterFromTransferReceiver_paysCurrentOwnerOnce` (from a `safeTransferFrom` callback, which is not guarded, the receiver is already owner: two claims pay it once, the previous owner nothing), `test_C2_5_reenterFromEthReceive_blocked` (recipient and requester, both aimed at the real token with half the schedule still to run, each try claim, topUp, mint, requestPayout, mintAuto, finalizePayout from `receive` during `finalizePayout`: all blocked, both paid once in ETH. Without the guard, topUp, mint and mintAuto would succeed for both and claim for the recipient. The requester's claim (`NotOwner`), requestPayout (`PayoutTooSoon`) and finalizePayout (`NoPendingPayout`) would fail anyway. Extends the existing `test_reentrantRecipient_cannotReenter`, which tried only finalize and request). |
| C2-5a Change the staged id during mintAuto through the receiver callback (MintIdMismatch, AP.sol:121) | Held | `test_C2_5a_mintAutoReceiverReentry_cannotChangeId`: the receiver re-enters mint and mintAuto (and claim, topUp, requestPayout) from `onERC721Received`; all hit the guard, one token is minted with the staged settings, no payout is pending. |
| C2-5b Change the staged id during mintAuto through the token call | Held | `test_C2_5b_mintAutoTokenReentry_cannotChangeId`: an AutoPayoutEndowmentNFT over a wrapper that is attacker code, re-entering mint and mintAuto inside `confidentialTransferFrom`; both hit the guard. MintIdMismatch (AP.sol:121) is therefore unreachable: `_nextId` is written only in `_mintEndowment` (ET:86), reachable only through `mint` and `mintAuto`, both `nonReentrant`, and the only external calls between staging (AP:115) and the check (AP:121) are the token and the receiver callback, both tried here. The branch is defensive; it stays uncovered. |
| C2-6 Arithmetic limits (endowment and distribution near `type(uint64).max`, deposits into a full supply) | Held | `test_C2_6_endowmentAtUint64Max_noWrap`: mint MAX-10 plus topUp 10 gives an endowment of exactly MAX; a further topUp is credited zero instead of wrapping the endowment, because minting more to the donor silently mints zero once the supply is full. A new mint by the creator is also credited zero, but that is just C2-2's zero-balance case again: once the supply is full no sender can hold more, so no deposit can push a sum past MAX; two accruals plus the end sweep bring the distribution to exactly MAX; the claim pays MAX. The NFT contract's per-token sums cannot overflow because each is bounded by its balance, which is bounded by the token's total supply (`tryIncrease`, ERC7984.sol `_update`). Silent zero: on the mock, minting past a full supply mints zero silently, so later deposits move zero; the NFT's own `FHE.add` calls are unchecked but cannot be reached with a sum above MAX. With cWETH this cannot happen: `test_C2_6_cwethWrapPastUint64Max_reverts` shows wrapping past MAX units reverts `ERC7984TotalSupplyOverflow`, and MAX units are about 1.8e10 ETH. |

## Coverage gaps

Command: `forge coverage --ir-minimum --report lcov` (plain `forge coverage` fails with "Stack too deep" in the Yul code generator). Under `--ir-minimum` the optimizer is off, so source mapping can be imprecise. Totals for `src/` excluding mocks: AutoPayoutEndowmentNFT 105/107 lines, 26/27 branches; ConfidentialWETH 2/2; EndowmentNFT 129/132 lines, 18/22 branches, 1 function; Schedule 21/21 lines, 4/4 branches. No existing test is a Hardhat-only coverage source; Hardhat tests were not measured.

| Location | What is not covered | Owning task |
|---|---|---|
| EndowmentNFT.sol:77 (branch) | `EmptySchedule` revert in `_mintEndowment` never taken (no test mentions it) | Task 2 |
| EndowmentNFT.sol:112 (branch) | `ZeroDurationSegment` revert never taken (no test mentions it) | Task 2 |
| EndowmentNFT.sol:194-195 | `topUpsAllowedOf` view and function never called | Task 2 |
| EndowmentNFT.sol:199 (branch) | `accrue` on a nonexistent token (`NonexistentToken`) never taken | Task 7 |
| EndowmentNFT.sol:214 (branch) | `topUp` on a nonexistent token never taken | Task 2 |
| EndowmentNFT.sol:132 | `uint256 len = 31;` in `_validName` reported uncovered, although name tests exist. Probably a `--ir-minimum` source-map artefact, unverified | Task 2 |
| AutoPayoutEndowmentNFT.sol:121 (branch) | `MintIdMismatch` revert in `mintAuto` never taken (defensive; reachable only if the id could change during mint) | Task 2 |
| AutoPayoutEndowmentNFT.sol:219 | `paidInWeth = true;` reported uncovered although `test_recipientRejectsEth_paidInWeth` exists. Probably an artefact, unverified | Task 3 |
| AutoPayoutEndowmentNFT.sol:272 | `call` in `_sendEth` assembly reported uncovered although payouts are tested. Probably an artefact, unverified | Task 3 |

Task 2 follow-up (`forge coverage --ir-minimum --match-path test/redteam/Theft.t.sol`): EndowmentNFT.sol:77, :112, :194-195 and :214 are now covered. AutoPayoutEndowmentNFT.sol:121 (`MintIdMismatch`) stays uncovered and is unreachable (see C2-5b). EndowmentNFT.sol:132 is a source-map artefact (see C2-2a).

Not measured by coverage and worth noting for later tasks: the `InsufficientGas` revert in `_sendEth` (Task 3), `ScheduleTooLong`/overflow edges of `Schedule` (Task 7; branch coverage is full but with few boundary values), and everything that depends on real FHE limits (Task 4/C5-3, see Sepolia-only checks).

## Sepolia-only checks

- Zama Sepolia version match: **not confirmed.** `@fhevm/solidity` 0.11.1 hard-codes Sepolia addresses ACL `0xf0Ffdc93b7E186bC2f8CB3dAA75D86d1930A433D`, executor `0x92C920834Ec8941d2C77D188936E1f7A6f49c127`, KMS verifier `0xbE0E383937d564D7FF0BC3b46c51f0bF8d5C311A` (`ZamaConfig.sol` `_getSepoliaConfig`). Zama's docs list the same three addresses (https://docs.zama.org/protocol/solidity-guides/smart-contract/configure/contract_addresses), and the repo's own test `SEPOLIA_FHEVM` checks that the app config equals `_getSepoliaConfig`. The docs page does not state which library version Sepolia runs, and the zama-ai/fhevm releases page names no Sepolia upgrade. Manual check: compare against Zama's published compatibility/release notes and call the Sepolia ACL/executor `getVersion()` before deployment.
- Mock vs real FHE (C5-3): per-transaction homomorphic computation limits (HCU) and decryption timing are not reproduced locally. Check on Sepolia that `mint`, `topUp`, `claim`, `requestPayout` and a transfer of a long-scheduled token stay under the HCU limits, and that `finalizePayout` works once the real KMS has published the decryption.
- Upgrade `@openzeppelin/confidential-contracts` to 0.4.2 (GHSA-29h2-jr22-frmh) and confirm Sepolia behaviour matches.

## Access table

Notation: "A+" = `FHE.allow(h, X)`; "A-this" = `FHE.allowThis`; "A-tx" = `FHE.allowTransient`; "PUB" = `FHE.makePubliclyDecryptable`. `ET` = `src/EndowmentNFT.sol`, `AP` = `src/AutoPayoutEndowmentNFT.sol`, `T` = `node_modules/@openzeppelin/confidential-contracts/token/ERC7984/ERC7984.sol`, `W` = `.../ERC7984/extensions/ERC7984ERC20Wrapper.sol`. `FHESafeMath.sol` (`utils/FHESafeMath.sol`) contains no `allow*` or `makePubliclyDecryptable` calls (checked: grep finds none), so the handles it returns (`success`, `updated`) are granted only by the caller, as shown. Grants made by `FHE.fromExternal`, trivial encryption (`FHE.asEuint64`) and the implicit grant of an operation's result to the contract that ran it belong to `@fhevm/solidity` and the host ACL; they were not read here and are not listed. ACL grants are never revoked.

### Shared token step (T `_update`, used by every token call below)

`_update(from, to, amount)` at `T:275-308` creates these handles:

| Handle | Granted to | Cite |
|---|---|---|
| New `_balances[from]` (`ptr` after `tryDecrease`) | token (A-this), `from` (A+) | `T:287`, `T:288` |
| New `_totalSupply` on mint (`tryIncrease`) | token (A-this) | `T:281` |
| New `_totalSupply` on burn | token (A-this) | `T:296` |
| New `_balances[to]` | token (A-this), `to` (A+) | `T:300`, `T:301` |
| `transferred` (the amount actually moved) | `from` (A+, if not zero address), `to` (A+, if not zero address), token (A-this) | `T:305`, `T:306`, `T:307` |
| `transferred`, in `confidentialTransferFrom` only | caller of the token (A-tx) | `T:150` (handle form, the one the NFT contracts call, which also requires at `T:147` that the caller is allowed on `amount`); `T:138` is the external-input form |
| `transferred`, in `wrap` | caller of the wrapper (A-tx) | `W:88` |

`ERC7984ERC20Wrapper._update` (`W:204-209`) adds only a total-supply check on mint, no grants.

### EndowmentNFT (and inherited by AutoPayoutEndowmentNFT)

| Function | Handle created or stored | Addresses granted | Cite |
|---|---|---|---|
| `mint` / `_mintEndowment` (`ET:54-104`; also `mintAuto` `AP:99-122`, which calls it) | `amount` (from `fromExternal`) | token (A-tx) | `ET:83` |
| | `received` = return of `token.confidentialTransferFrom(msg.sender, this, amount)`; the token step above applies with from = creator, to = NFT contract: creator balance handle to token + creator; NFT balance handle to token + NFT contract; `transferred` to creator, NFT contract, token; and transient to NFT contract | creator, NFT contract, token | `ET:84`, `T:142-151` (handle form; `T:147` requires the NFT contract allowed on `amount`, `T:150` the transient grant), `T:287-307` |
| | `endowmentRemaining` = `add(received, 0)` (new handle, deliberately not `received`, which the creator can read) | NFT contract only (A-this). Never any owner. | `ET:89`, `ET:97` |
| | `distribution` = `asEuint64(0)` | NFT contract (A-this), `to` (A+, the first owner) | `ET:90`, `ET:98`, `ET:99` |
| | `_safeMint` runs `_update` override: `from == 0`, so no accrual and no grant | none | `ET:241-250` |
| `claim` (`ET:203-210`) | `amt` = old `distribution` handle (its ACL is whoever was ever granted: NFT contract and every owner that held the token while it was set) | token (A-tx) on `amt` | `ET:208` |
| | New `distribution` = `asEuint64(0)` (from `_takeDistribution`) | NFT contract (A-this), caller = current owner (A+) | `ET:236-238` |
| | `_accrue` handles, see `accrue` row | | `ET:231` |
| | `token.confidentialTransfer(msg.sender, amt)` requires the NFT contract to be allowed on `amt` (`T:125`); token step with from = NFT, to = owner: NFT balance handle to token + NFT; owner balance handle to token + owner; `transferred` to NFT, owner, token | NFT contract, owner, token | `ET:209`, `T:124-127`, `T:287-307` |
| `topUp` (`ET:212-225`) | `amount` (from `fromExternal`) | token (A-tx) | `ET:220` |
| | `received` from `confidentialTransferFrom(donor, NFT, amount)`: donor balance handle to token + donor; NFT balance handle to token + NFT; `transferred` to donor, NFT, token, and transient to NFT | donor, NFT contract, token | `ET:221`, `T:147`, `T:150`, `T:287-307` |
| | `endowmentRemaining` = `add(old, received)` | NFT contract only | `ET:223`, `ET:224` |
| `accrue` / `_accrue` (`ET:198-201`, `ET:261-294`), also reached from `claim`, `requestPayout`, transfers | Settled branch (`now >= end`): `distribution` = `add(distribution, endowmentRemaining)`; `endowmentRemaining` = `sub(x, x)` | `endowmentRemaining`: NFT contract only. `distribution`: NFT contract + `ownerOf(tokenId)` | `ET:270`, `ET:273`, `ET:276`, `ET:277`, `ET:278` |
| | Streaming branch: `actual` = `min(asEuint64(owed), endowmentRemaining)`; `endowmentRemaining` = `sub(.., actual)`; `distribution` = `add(.., actual)`. `actual` itself gets no explicit grant. | `endowmentRemaining`: NFT contract only. `distribution`: NFT contract + `ownerOf(tokenId)` | `ET:285-287`, `ET:289`, `ET:290`, `ET:291` |
| | No-op branches (`settled`, or `owed == 0`) | no new handle, no grant | `ET:263`, `ET:283` |
| ERC-721 transfer, `_update` override (`ET:241-259`; AP override `AP:280-294` adds no handles) | `_accrue` first, as above. Inside it `ownerOf` already returns the new owner (the super call ran first), so the post-accrue `distribution` is granted to the new owner | NFT contract, new owner | `ET:247`, `ET:251` |
| | `distribution` = `add(distribution, asEuint64(0))` (fresh handle) | NFT contract (A-this), `to` (A+) | `ET:255-257` |
| | Previous owner keeps access to every earlier `distribution` handle (including the one that was current at the moment of transfer, and any trivial `0` handle, which is deterministic and shared). Never revoked. | previous owner(s), read-only history | `ET:240-258` comment, ACL semantics |
| `setAutoPayout`, `payoutDue`, views, `constructor` | no encrypted handle created | none | `AP:125-134` |

### AutoPayoutEndowmentNFT

| Function | Handle created or stored | Addresses granted | Cite |
|---|---|---|---|
| `requestPayout` (`AP:151-177`) | `_takeDistribution(tokenId, recipient = current owner)`: `_accrue` handles as above; `amt` = old `distribution`; new `distribution` = `asEuint64(0)` | NFT contract (A-this), recipient/owner (A+) on the new `distribution` | `AP:169`, `ET:231-238` |
| | `amt` passed to the wrapper | wrapper (A-tx) | `AP:170` |
| | `_wrapper.unwrap(this, this, amt)` requires the caller, i.e. the NFT contract, allowed on `amt` (`W:95`; the wrapper's own access to `amt` comes from the transient grant at `AP:170`) and `from == msg.sender` (NFT contract). `_unwrap` burns: NFT balance handle to token + NFT (`T:287`, `T:288`); total supply to token (`T:296`); `transferred` (the burned amount) to NFT, token (`T:305`, `T:307`) (`to` is the zero address, so no `T:306`) | wrapper, NFT contract | `AP:171`, `W:94-97`, `W:217` |
| | `unwrapAmount_` = the `transferred` handle: **PUB**. Its handle is the request id, stored in `_pendingPayouts` and emitted in `PayoutRequested`. | everyone (public decryption) | `W:218` |
| `finalizePayout` (`AP:182-223`) | no new handle. `FHE.checkSignatures` verifies the proof; `finalizeUnwrap` (`W:114-135`) also only calls `checkSignatures` (`W:130`) and transfers WETH. No ACL grant. | none | `AP:192`, `AP:201`, `W:130` |
| `mintAuto` | as `mint`; the settings are plain storage | see `mint` | `AP:99-122` |

### ConfidentialWETH (inherits ERC7984 and ERC7984ERC20Wrapper)

| Function | Handle created or stored | Addresses granted | Cite |
|---|---|---|---|
| `wrap(to, amount)` (`W:82-90`) | `_mint(to, asEuint64(amount / rate))`: total supply to token; `to` balance to token + `to`; `transferred` to `to`, token (`from` is zero address) | token, `to` | `W:87`, `T:281`, `T:300`, `T:301`, `T:306`, `T:307` |
| | `wrappedAmountSent` | caller (A-tx) | `W:88` |
| `onTransferReceived` (`W:54-70`, ERC-1363 callback from WETH) | `_mint(to, asEuint64(amount / rate))`: same grants as `wrap`, no transient grant | token, `to` | `W:65`, `T:281`, `T:300`, `T:301`, `T:306`, `T:307` |
| `confidentialTransfer(to, extAmount, proof)` (`T:115-121`) | `FHE.fromExternal` amount; token step (from = caller) | caller, `to`, token | `T:287-307` |
| `confidentialTransfer(to, euint64)` (`T:124-127`) | requires caller allowed on `amount`; token step | caller, `to`, token | `T:125`, `T:287-307` |
| `confidentialTransferFrom` (both forms, `T:130-152`) | requires operator; token step (from = holder, to = recipient) and transient to the caller | holder, `to`, token, caller (A-tx) | `T:138` (external-input form), `T:150` (handle form), `T:287-307` |
| `confidentialTransferAndCall`, `confidentialTransferFromAndCall` (`T:154-200`, `T:258-273`) | Three handles. `sent` = first `_update(from, to, amount)` (`T:265`): `_update` grants to `from`, `to`, token (`T:287-307`). `refund` = second `_update(to, from, select(success, 0, sent))` (`T:271`, from and to swapped): `_update` grants to `to`, `from`, token. Final `transferred` = `FHE.sub(sent, refund)` (`T:272`), a new handle created after both `_update` calls: its only explicit grant is transient to the caller (`T:161`, `T:172`, `T:185`, `T:198`), plus the implicit grant to the token. The holder and recipient are NOT granted on the final `transferred`. | `sent` and `refund`: holder, recipient, token. Final `transferred`: caller (A-tx) and token only. Relevant to GHSA-29h2-jr22-frmh: the `ebool success` returned by the recipient is used without an ACL check (`T:268`, `T:271`). | `T:161`, `T:172`, `T:185`, `T:198`, `T:265-272` |
| `unwrap(from, to, amount)` and `unwrap(.., external, proof)` (`W:94-112`) | as in `requestPayout`: burn grants, then **PUB** on the burned amount. Callable by anyone for their own balance, or as operator. | `from`, token; public | `W:94-112`, `W:212-229`, `W:218` |
| `finalizeUnwrap` (`W:114-135`) | no handle; `checkSignatures` | none | `W:130` |
| `requestDiscloseEncryptedAmount(h)` (`T:208-216`) | **PUB** on handle `h`. Two checks are enforced: the caller must be allowed on `h` (`T:210`), and cWETH itself must be allowed on `h`, because `FHE.makePubliclyDecryptable` (`T:214`) calls the host `ACL.allowForDecryption`, which reverts with `SenderNotAllowed` unless `isAllowed(handle, msg.sender)` for msg.sender = cWETH (`node_modules/@fhevm/host-contracts/contracts/ACL.sol:222`). So only handles that both the caller and cWETH hold ACL on can be made public. | public | `T:208-214`, `ACL.sol:222` |
| `discloseEncryptedAmount` (`T:223-234`) | no handle; `checkSignatures` | none | `T:223-234` |
| `setOperator` (`T:110`) | no handle | none | `T:110-112` |

### Notes for Task 5 (not findings, hypotheses to test)

1. ACL is never revoked: after a transfer the previous owner can still read every `distribution` handle that was current while they owned the token. Check that none of them still holds a value that the new owner should not share, and that the handle at the moment of transfer is a pre-accrue value (so the new owner's claim is not readable by the old owner).
2. `requestDiscloseEncryptedAmount` (`T:208-216`) lets any address make a handle publicly decryptable provided both that address and cWETH hold ACL on it (`T:210`, `ACL.sol:222`). A previous owner (or a creator, donor) holds ACL on handles that the cWETH contract also holds ACL on: the creator on `received` at mint (`T:305`) and every owner/donor on their own `transferred` handles. Check whether any of those encodes a hidden amount (the endowment size is the obvious one: `received` at mint equals the endowment when the creator is not the owner, and the creator is granted on it at `T:305`; `endowmentRemaining` is a separate handle, but the amount equals it at mint).
3. The shared trivial-zero handle (`asEuint64(0)` at `ET:90`, `ET:236`) is held by many addresses; harmless, but confirms no owner-specific secret lives behind it.
4. `unwrapAmount_` is PUB, so each payout amount (before fee) is publicly decryptable by design (automatic-payout spec); confirm it is only the claimed amount and not the remaining endowment.

## Appendix: Slither triage

Command: `uvx --from slither-analyzer slither . --filter-paths "node_modules|lib|src/mocks"` (nothing installed permanently; compiled through Foundry; exit code 255 only because results were found). 39 results from 102 detectors on 49 contracts. Full output kept outside the repo.

| Detector | Location | Triage |
|---|---|---|
| reentrancy-no-eth (x8, cross-function) | `EndowmentNFT._accrue`, `_mintEndowment`, `topUp`, `AutoPayout.finalizePayout` | False positive. The "external calls" are `FHE.*` library calls, which are calls to the trusted FHEVM executor/ACL, not to user code. `mint`, `mintAuto`, `claim`, `topUp`, `requestPayout`, `finalizePayout` are `nonReentrant`. The real re-entry points (ERC-721 receiver in `_safeMint`, ETH sends) are covered by Tasks 2 and 3. |
| reentrancy-benign (x2) | `_mintEndowment` (`_nextId` written after `confidentialTransferFrom`), `finalizePayout` | False positive for the same reasons: the token is the configured trusted wrapper, and `nonReentrant` holds. `_nextId` after the transfer is by design (the id is staged by `mintAuto` and checked by `MintIdMismatch`). |
| incorrect-equality | `_accrue` `owed == 0` | False positive: integer comparison on a computed value, used only to skip a no-op. |
| uninitialized-local | `finalizePayout` `feeWei`, `paidInWeth` | False positive: default zero/false is intended. |
| unused-return | `FHE.allow*` calls, `confidentialTransfer` in `claim` | False positive: `allow*` return the handle for chaining. Ignoring the return of `confidentialTransfer` in `claim` is by design (a shortfall moves zero, the amount is already taken from the distribution); solvency across all functions is Task 4. |
| timestamp | `requestPayout`, `payoutDue`, `_storeSchedule`, `topUp`, `_accrue` | By design: second-level proposer skew is accepted (intervals are at least one hour, see code comment); timing hypotheses belong to Task 7. |
| assembly | `_sendEth` | By design: bounded-gas call without return data copy (spec: automatic payout 4.x). Gas rule is Task 3. |
| dead-code | `ConfidentialWETH._maxDecimals` | False positive: it overrides a virtual hook in the wrapper, which calls it. |
| too-many-digits | `SEND_GAS = 100000` | False positive: cosmetic. |

No Slither result is a finding.
