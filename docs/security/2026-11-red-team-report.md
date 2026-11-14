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

- `@openzeppelin/confidential-contracts` GHSA-29h2-jr22-frmh, "Unchecked ACL on a returned handle leaks private data in VestingWalletConfidential and ERC7984", Moderate, published 2026-07-31. Affected: below 0.3.2, 0.4.0-rc.0 up to below 0.4.2, 0.5.0-rc.0 up to below 0.5.2. **The installed 0.4.1 is in the affected range; patched in 0.4.2.** Two places: VestingWalletConfidential (not used here) and the ERC7984 `*AndCall` transfer callback, where the `ebool` a recipient returns drives refund logic without an ACL check on it, so a malicious recipient contract can learn the plaintext of an `ebool` the token can access (limited to `ebool` handles; advisory says no loss of funds). The `*AndCall` functions are public on ConfidentialWETH (inherited), so the path is reachable even though neither NFT contract uses it. Which `ebool`s cWETH can access (the `success` flags of transfers) and what they reveal is left to Task 5 (C5). Source: https://github.com/OpenZeppelin/openzeppelin-confidential-contracts/security/advisories/GHSA-29h2-jr22-frmh
- `@openzeppelin/confidential-contracts` GHSA-hqf9-8xv5-x8xw (CVE-2026-73645), wrapper silently fails to mint once total supply is full; affected <= 0.3.0, patched 0.3.1. Does not affect 0.4.1. With rate 1e9 the wrapper fills at about 18.4 billion WETH, far above supply. Source: https://github.com/OpenZeppelin/openzeppelin-confidential-contracts/security/advisories/GHSA-hqf9-8xv5-x8xw (list: .../security/advisories)
- `@fhevm/solidity` / zama-ai/fhevm: "There aren't any published security advisories." Source: https://github.com/zama-ai/fhevm/security/advisories. Release notes (https://github.com/zama-ai/fhevm/releases) mention only Rust dependency advisories and fuzzing fixes in the coprocessor, nothing about `@fhevm/solidity` 0.11.1.
- `@openzeppelin/contracts`: the advisory list (https://github.com/OpenZeppelin/openzeppelin-contracts/security/advisories, first page) shows nothing published in 2026; latest is GHSA-9rcw-c2f9-2j55 (2025-07-17, `Bytes.lastIndexOf`, Low). Only the first page was read and per-advisory version ranges were not opened; no OZ `Bytes`/`Base64` function is used by in-scope code (ERC721, ReentrancyGuard, SafeERC20 only), so none is expected to apply. Unconfirmed for page 2 (older advisories).
- forge-fhevm: repo has a SECURITY.md; no advisory lookup done (test harness only, not deployed).

## Summary

<!-- Left for Task 10. -->

## Findings

| ID | Severity | Title | Contract.function | PoC test | Status |
|---|---|---|---|---|---|

## Finding details

## By design

| ID | Behaviour | Spec reference | User-facing wording needed |
|---|---|---|---|

## Hypotheses tested

| Hypothesis | Result | Tests |
|---|---|---|

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
