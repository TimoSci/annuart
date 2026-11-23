import { existsSync, readFileSync, writeFileSync } from "fs";
import { ethers, fhevm, network } from "hardhat";
import { FhevmType } from "@fhevm/hardhat-plugin";
import { readDeployments } from "../tasks/deployments";

// End-to-end checks of the contracts on Sepolia, for the things a local mock cannot show:
// decryption through the real key service, the access list as the real network enforces
// it, the FHE cost limits, real WETH, and a 128-bit decryption. It spends from a throwaway
// key and runs against throwaway contracts recorded in deployments/sepolia.json.
//
//   STAGE        info | setup | mock | mock-transfer | probe | wrapped | auto-mint | auto-verify | private
//   PRIVATE_KEY  account A: creator and payer (Hardhat's sepolia account)
//   KEY_B        account B: owner
//   KEY_C        account C: a stranger, holds nothing
//   E2E_STATE    a JSON file that carries token ids from one stage to the next
//   CONFIRM_E2E  must be "sepolia"

const INDEFINITE = (1n << 64n) - 1n;
const lines: string[] = [];
let failures = 0;
const say = (s: string) => { console.log(s); lines.push(s); };
const check = (name: string, ok: boolean, detail = "") => {
  if (!ok) failures++;
  say(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? `  (${detail})` : ""}`);
};

const statePath = process.env.E2E_STATE!;
const state: Record<string, any> = existsSync(statePath) ? JSON.parse(readFileSync(statePath, "utf8")) : {};
const save = () => writeFileSync(statePath, JSON.stringify(state, (_k, v) => (typeof v === "bigint" ? v.toString() : v), 2));

async function send(label: string, tx: Promise<any>) {
  const sent = await tx;
  const receipt = await sent.wait();
  say(`tx    ${label}: gas ${receipt.gasUsed} block ${receipt.blockNumber} ${receipt.hash}`);
  return receipt;
}

const short = (e: unknown) => String(e instanceof Error ? e.message : e).replace(/\s+/g, " ").slice(0, 140);

async function main() {
  if (network.name !== "sepolia" || process.env.CONFIRM_E2E !== "sepolia") {
    throw new Error("run with --network sepolia and CONFIRM_E2E=sepolia");
  }
  const stage = process.env.STAGE ?? "";
  const [A] = await ethers.getSigners();
  const B = new ethers.Wallet(process.env.KEY_B!, ethers.provider);
  const C = new ethers.Wallet(process.env.KEY_C!, ethers.provider);
  const dep = (label: string) => readDeployments("sepolia").contracts.find((c) => c.label === label)!;
  const now = async () => (await ethers.provider.getBlock("latest"))!.timestamp;
  const year = 365 * 24 * 3600;
  // Waits for a block after the one just mined. A wallet estimates gas at the latest
  // block's timestamp; straight after an accrual that is the accrual's own timestamp, the
  // token has nothing new to accrue there, and the estimate comes out too low for the
  // block the transaction really lands in.
  const nextBlock = async () => {
    const n = await ethers.provider.getBlockNumber();
    while ((await ethers.provider.getBlockNumber()) <= n) await new Promise((r) => setTimeout(r, 3000));
  };
  await fhevm.initializeCLIApi();

  const decrypt = (type: FhevmType, handle: string, contract: string, who: any) =>
    fhevm.userDecryptEuint(type as any, handle, contract, who);
  // A decryption that must be refused.
  const refused = async (name: string, type: FhevmType, handle: string, contract: string, who: any) => {
    try {
      const v = await decrypt(type, handle, contract, who);
      check(name, false, `decrypted to ${v}`);
    } catch (e) {
      check(name, true, short(e));
    }
  };
  const mintedId = (nft: any, receipt: any): bigint => {
    for (const log of receipt.logs) {
      try {
        const p = nft.interface.parseLog(log);
        if (p?.name === "EndowmentMinted") return p.args.tokenId;
      } catch { /* another contract's event */ }
    }
    throw new Error("no EndowmentMinted event");
  };
  const enc64 = async (contract: string, user: string, ...values: bigint[]) => {
    const input = fhevm.createEncryptedInput(contract, user);
    for (const v of values) input.add64(v);
    return input.encrypt();
  };

  say(`== stage ${stage}  A ${A.address}  B ${B.address}  C ${C.address}`);

  if (stage === "info") {
    const v = ["function getVersion() view returns (string)"];
    const acl = "0xf0Ffdc93b7E186bC2f8CB3dAA75D86d1930A433D";
    const exec = new ethers.Contract("0x92C920834Ec8941d2C77D188936E1f7A6f49c127",
      [...v, "function getHCULimitAddress() view returns (address)", "function getACLAddress() view returns (address)"], ethers.provider);
    say(`ACL            ${await new ethers.Contract(acl, v, ethers.provider).getVersion()}`);
    say(`Executor       ${await exec.getVersion()}`);
    check("the executor names the ACL the contracts are compiled against", (await exec.getACLAddress()) === acl);
    const hcuAddr = await exec.getHCULimitAddress();
    say(`HCULimit       ${await new ethers.Contract(hcuAddr, v, ethers.provider).getVersion()} at ${hcuAddr}`);
    say(`KMSVerifier    ${await new ethers.Contract("0xbE0E383937d564D7FF0BC3b46c51f0bF8d5C311A", v, ethers.provider).getVersion()}`);
    // Getters that exist only on versions with a per-block cap.
    for (const sig of ["getBlockMeter()", "getGlobalHCUCapPerBlock()", "getMaxHCUPerTx()", "getMaxHCUDepthPerTx()"]) {
      try {
        const out = await ethers.provider.call({ to: hcuAddr, data: ethers.id(sig).slice(0, 10) });
        say(`HCULimit.${sig} -> ${out}`);
      } catch (e) {
        say(`HCULimit.${sig} -> not available (${short(e).slice(0, 60)})`);
      }
    }
    const block = (await ethers.provider.getBlock("latest"))!;
    say(`Block gas limit ${block.gasLimit}, base fee ${block.baseFeePerGas} wei`);
  }

  if (stage === "setup") {
    if ((await ethers.provider.getBalance(B.address)) < ethers.parseEther("0.005")) {
      await send("fund B with 0.01 ETH", A.sendTransaction({ to: B.address, value: ethers.parseEther("0.01") }));
    }
    say(`A ${ethers.formatEther(await ethers.provider.getBalance(A.address))} ETH, B ${ethers.formatEther(await ethers.provider.getBalance(B.address))} ETH`);
  }

  if (stage === "mock") {
    const d = dep("mock");
    const token = await ethers.getContractAt("MockConfidentialToken", d.token, A);
    const nft = await ethers.getContractAt("EndowmentNFT", d.nft, A);
    await send("token.mint 1,000,000 to A", token.mint(A.address, 1_000_000n));
    await send("token.setOperator(nft)", token.setOperator(d.nft, (await now()) + year));
    check("A's token balance decrypts to what was minted (real key service)",
      (await decrypt(FhevmType.euint64, await token.confidentialBalanceOf(A.address), d.token, A)) >= 1_000_000n);

    const start = (await now()) - 120;
    const e = await enc64(d.nft, A.address, 500_000n);
    const segments = [{ duration: 3600n, ratePerSec: 100n }, { duration: INDEFINITE, ratePerSec: 10n }];
    const id = mintedId(nft, await send("mint (2 segments, to B, top-ups on)",
      nft.mint(B.address, e.handles[0], e.inputProof, segments, start, true, ethers.encodeBytes32String("Sepolia e2e"))));
    state.mock = { id, start };
    save();
    check("the ENFT belongs to B", (await nft.ownerOf(id)) === B.address);

    const t = await enc64(d.nft, A.address, 100_000n);
    await send("topUp 100,000 by A", nft.topUp(id, t.handles[0], t.inputProof));
    await send("accrue", nft.accrue(id));
    const accruedAt = Number(await nft.lastAccrualAtOf(id));
    const dist = await nft.distributionHandle(id);
    const owed = BigInt(accruedAt - start) * 100n;
    const shown = await decrypt(FhevmType.euint64, dist, d.nft, B);
    check("the owner decrypts the distribution, and it is rate x elapsed", shown === owed, `${shown} vs ${owed}`);

    await refused("a stranger cannot decrypt the distribution", FhevmType.euint64, dist, d.nft, C);
    await refused("the creator (not the owner) cannot decrypt the distribution", FhevmType.euint64, dist, d.nft, A);
    const remaining = await nft.endowmentHandle(id);
    await refused("the owner cannot decrypt the remaining endowment", FhevmType.euint64, remaining, d.nft, B);
    await refused("the creator cannot decrypt the remaining endowment", FhevmType.euint64, remaining, d.nft, A);
    await refused("a stranger cannot decrypt the remaining endowment", FhevmType.euint64, remaining, d.nft, C);

    await send("token.setOperator by B (so B can be asked later)", (token.connect(B) as any).setOperator(d.nft, (await now()) + year));
    await send("claim by B", (nft.connect(B) as any).claim(id));
    const claimedAt = Number(await nft.lastAccrualAtOf(id));
    state.mock.claimedAt = claimedAt;
    save();
    const paid = await decrypt(FhevmType.euint64, await token.confidentialBalanceOf(B.address), d.token, B);
    check("B's token balance is exactly what the claim paid", paid === BigInt(claimedAt - start) * 100n, `${paid}`);
    await refused("A cannot decrypt B's token balance", FhevmType.euint64, await token.confidentialBalanceOf(B.address), d.token, A);

  }

  if (stage === "mock-transfer") {
    const d = dep("mock");
    const nft = await ethers.getContractAt("EndowmentNFT", d.nft, A);
    const id = BigInt(state.mock.id);
    await nextBlock();
    await send("transferFrom B to A", (nft.connect(B) as any).transferFrom(B.address, A.address, id));
    check("the ENFT belongs to A after the transfer", (await nft.ownerOf(id)) === A.address);
    const after = await decrypt(FhevmType.euint64, await nft.distributionHandle(id), d.nft, A);
    const owedNow = BigInt(Number(await nft.lastAccrualAtOf(id)) - state.mock.claimedAt) * 100n;
    check("the new owner decrypts the distribution accrued since the claim", after === owedNow, `${after} vs ${owedNow}`);
    await refused("the previous owner cannot decrypt the new distribution", FhevmType.euint64, await nft.distributionHandle(id), d.nft, B);
  }

  if (stage === "probe") {
    const d = dep("mock");
    const nft = await ethers.getContractAt("EndowmentNFT", d.nft, A);
    if (!state.probe) {
      const probe = await (await ethers.getContractFactory("AclProbe", A)).deploy();
      await probe.waitForDeployment();
      state.probe = await probe.getAddress();
      save();
    }
    const probe = await ethers.getContractAt("AclProbe", state.probe, A);
    say(`AclProbe at ${state.probe}`);
    const own = await enc64(state.probe, A.address, 7n, 35n);
    const receipt = await send("probe.addOwn(7, 35)", probe.addOwn(own.handles[0], own.handles[1], own.inputProof));
    const result = receipt.logs.map((l: any) => { try { return probe.interface.parseLog(l); } catch { return null; } })
      .find((p: any) => p?.name === "Result");
    check("an operation on values the contract may use succeeds, and the caller is granted the result", result.args.callerAllowed === true);
    check("the granted result decrypts to the sum", (await decrypt(FhevmType.euint64, result.args.handle, state.probe, A)) === 42n);
    await refused("a stranger cannot decrypt that result", FhevmType.euint64, result.args.handle, state.probe, C);

    // A value the probe was never granted: the remaining endowment of the mock ENFT.
    const foreign = await nft.endowmentHandle(state.mock.id);
    const one = await enc64(state.probe, A.address, 1n);
    try {
      await probe.addForeign.staticCall(one.handles[0], one.inputProof, foreign);
      check("an operation on a value the contract was never granted is refused", false, "the call did not revert");
    } catch (e) {
      check("an operation on a value the contract was never granted is refused", true, short(e));
    }
  }

  if (stage === "wrapped") {
    const d = dep("wrapped");
    const token = await ethers.getContractAt("ConfidentialWETH", d.token, A);
    const nft = await ethers.getContractAt("EndowmentNFT", d.nft, A);
    const weth = new ethers.Contract(d.underlying!, [
      "function deposit() payable", "function approve(address,uint256) returns (bool)", "function balanceOf(address) view returns (uint256)",
    ], A);
    const rate: bigint = await token.rate();
    const units = 3_000_000n; // 0.003 ETH
    await send("WETH.deposit 0.003 ETH", weth.deposit({ value: units * rate }));
    await send("WETH.approve(cWETH)", weth.approve(d.token, units * rate));
    await send("cWETH.wrap", token.wrap(A.address, units * rate));
    await send("cWETH.setOperator(nft)", token.setOperator(d.nft, (await now()) + year));
    const balance = await decrypt(FhevmType.euint64, await token.confidentialBalanceOf(A.address), d.token, A);
    check("the wrapped balance decrypts to the wrapped amount", balance === units, `${balance}`);

    const start = (await now()) - 600;
    const e = await enc64(d.nft, A.address, 200_000n);
    const id = mintedId(nft, await send("mint over cWETH (to A)",
      nft.mint(A.address, e.handles[0], e.inputProof, [{ duration: INDEFINITE, ratePerSec: 50n }], start, false, ethers.ZeroHash)));
    state.wrapped = { id, start };
    save();
    await send("claim over cWETH", nft.claim(id));
    const claimed = BigInt(Number(await nft.lastAccrualAtOf(id)) - start) * 50n;
    const after = await decrypt(FhevmType.euint64, await token.confidentialBalanceOf(A.address), d.token, A);
    check("the claim paid rate x elapsed in cWETH", after === units - 200_000n + claimed, `${after}`);

    // Unwrap: a request, a public decryption by the real key service, and the finish.
    const wethBefore: bigint = await weth.balanceOf(A.address);
    const u = await enc64(d.token, A.address, 100_000n);
    const req = await send("cWETH.unwrap 100,000 (request)",
      (token as any)["unwrap(address,address,bytes32,bytes)"](A.address, A.address, u.handles[0], u.inputProof));
    const ev = req.logs.map((l: any) => { try { return token.interface.parseLog(l); } catch { return null; } })
      .find((p: any) => p?.name === "UnwrapRequested");
    const t0 = Date.now();
    const pub: any = await fhevm.publicDecrypt([ev.args.amount]);
    say(`public decryption took ${Math.round((Date.now() - t0) / 1000)}s`);
    const clear = BigInt(pub.clearValues[ev.args.amount]);
    await send("cWETH.finalizeUnwrap", token.finalizeUnwrap(ev.args.unwrapRequestId, clear, pub.decryptionProof));
    check("the unwrap returned exactly 100,000 units of WETH", (await weth.balanceOf(A.address)) - wethBefore === 100_000n * rate, `${clear}`);
  }

  if (stage === "auto-mint") {
    const d = dep("auto");
    const token = await ethers.getContractAt("ConfidentialWETH", d.token, A);
    const nft = await ethers.getContractAt("AutoPayoutEndowmentNFT", d.nft, A);
    await send("cWETH.setOperator(auto nft)", token.setOperator(d.nft, (await now()) + year));
    const start = (await now()) - 7200;
    const e = await enc64(d.nft, A.address, 300_000n);
    const fee = 10n ** 13n; // 10,000 units
    const id = mintedId(nft, await send("mintAuto (to B, hourly, fee 0.00001 ETH)",
      nft.mintAuto(B.address, e.handles[0], e.inputProof, [{ duration: INDEFINITE, ratePerSec: 10n }], start, false,
        ethers.encodeBytes32String("Sepolia auto"), true, 3600, fee)));
    state.auto = { id, start, fee, bBefore: await ethers.provider.getBalance(B.address), block: await ethers.provider.getBlockNumber() };
    save();
    check("a payout is due at once", (await nft.payoutDue(id)) === true);
  }

  if (stage === "auto-verify") {
    const d = dep("auto");
    const nft = await ethers.getContractAt("AutoPayoutEndowmentNFT", d.nft, A);
    const { id, start, fee, bBefore, block } = state.auto;
    const paid = await nft.queryFilter(nft.filters.PayoutPaid(id), block);
    check("the keeper's pass produced one PayoutPaid event", paid.length === 1);
    const args = (paid[0] as any).args;
    say(`PayoutPaid amountWei ${args.amountWei} feeWei ${args.feeWei} paidInWeth ${args.paidInWeth}`);
    const requested = await nft.queryFilter(nft.filters.PayoutRequested(id), block);
    const requestedAt = (await requested[0].getBlock()).timestamp;
    const rate: bigint = await nft.rate();
    check("the payout is rate x elapsed, converted to wei", args.amountWei === BigInt(requestedAt - start) * 10n * rate, `${args.amountWei}`);
    check("it was paid in ETH through real WETH's withdraw, not in WETH", args.paidInWeth === false);
    // The contract caps the fee at a tenth of the payout.
    const cap = args.amountWei / 10n;
    check("the fee is the one set, capped at a tenth of the payout", args.feeWei === (BigInt(fee) < cap ? BigInt(fee) : cap), `${args.feeWei}`);
    const bNow = await ethers.provider.getBalance(B.address);
    check("the owner's ETH rose by the payout minus the fee", bNow - BigInt(bBefore) === args.amountWei - args.feeWei, `${bNow - BigInt(bBefore)}`);
    check("no ETH is left in the contract", (await ethers.provider.getBalance(d.nft)) === 0n);
    check("no payout is due or pending now", (await nft.payoutDue(id)) === false);
  }

  if (stage === "private") {
    const d = dep("private");
    const token = await ethers.getContractAt("ConfidentialWETH", d.token, A);
    const nft = await ethers.getContractAt("PrivateRateEndowmentNFT", d.nft, A);
    await send("cWETH.setOperator(private nft)", token.setOperator(d.nft, (await now()) + year));
    const unit = (1n << 32n) / 20n; // weight 1000 pays just under 50 units a second
    const start = (await now()) - 300;
    const e = await enc64(d.nft, A.address, 400_000n, unit);
    const segments = [{ duration: 3600n, ratePerSec: 1000n }, { duration: INDEFINITE, ratePerSec: 500n }];
    const id = mintedId(nft, await send("mintPrivate over cWETH (to B)",
      nft.mintPrivate(B.address, e.handles[0], e.handles[1], e.inputProof, segments, start, true, ethers.encodeBytes32String("Sepolia private"))));
    state.private = { id, start };
    save();

    const unitHandle = await nft.unitHandle(id);
    check("the creator decrypts the 128-bit rate", (await decrypt(FhevmType.euint128, unitHandle, d.nft, A)) === unit);
    check("the owner decrypts the 128-bit rate", (await decrypt(FhevmType.euint128, unitHandle, d.nft, B)) === unit);
    await refused("a stranger cannot decrypt the rate", FhevmType.euint128, unitHandle, d.nft, C);
    await refused("the owner cannot decrypt the remaining endowment", FhevmType.euint64, await nft.endowmentHandle(id), d.nft, B);

    await send("accrue (private rate)", nft.accrue(id));
    const w1 = BigInt(Number(await nft.lastAccrualAtOf(id)) - start) * 1000n;
    const dist = await decrypt(FhevmType.euint64, await nft.distributionHandle(id), d.nft, B);
    check("the distribution is floor(rate x weight x elapsed / 2^32)", dist === (unit * w1) >> 32n, `${dist}`);

    await send("cWETH.setOperator by B", (token.connect(B) as any).setOperator(d.nft, (await now()) + year));
    await send("claim by B (private rate)", (nft.connect(B) as any).claim(id));
    const w2 = BigInt(Number(await nft.lastAccrualAtOf(id)) - start) * 1000n;
    const got = await decrypt(FhevmType.euint64, await token.confidentialBalanceOf(B.address), d.token, B);
    check("B was paid exactly the amount owed at the claim", got === (unit * w2) >> 32n, `${got}`);

    await nextBlock();
    await send("transferFrom B to C (private rate)", (nft.connect(B) as any).transferFrom(B.address, C.address, id));
    check("the new owner decrypts the rate", (await decrypt(FhevmType.euint128, unitHandle, d.nft, C)) === unit);
    check("the previous owner still decrypts the rate", (await decrypt(FhevmType.euint128, unitHandle, d.nft, B)) === unit);
  }

  say(`== stage ${stage}: ${failures === 0 ? "all checks passed" : `${failures} check(s) FAILED`}`);
  if (failures) process.exitCode = 1;
}

main().catch((e) => {
  console.error(short(e));
  process.exitCode = 1;
});
