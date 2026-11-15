import { expect } from "chai";
import { ethers, fhevm } from "hardhat";
import { readFileSync } from "fs";
import { join } from "path";
import { time, setBalance, setCode } from "@nomicfoundation/hardhat-network-helpers";
import { runKeeperPass, type KeeperContract } from "../../tasks/keeper";

// Task 8: C4-2 (keeper drain) and C5-5 (keeper script review). Everything runs on Hardhat's
// in-process network with the FHEVM mock: the keeper's real pass logic (runKeeperPass) is driven
// against a real AutoPayoutEndowmentNFT. Nothing here touches a real network, a key or .env.
//
// Units: the wrapper has rate 1e9, so one confidential unit is 1e9 wei.

const UNIT = 10n ** 9n;
const HOUR = 3600;
const DECRYPT = (h: string[]) => fhevm.publicDecrypt(h as `0x${string}`[]) as any;

async function env() {
  const [deployer, attacker, keeper, rival, honest] = await ethers.getSigners();
  const weth = await (await ethers.getContractFactory("MockWETH")).deploy();
  const cweth = await (await ethers.getContractFactory("ConfidentialWETH")).deploy(await weth.getAddress());
  const nft = await (await ethers.getContractFactory("AutoPayoutEndowmentNFT")).deploy(await cweth.getAddress());
  const nftAddr = await nft.getAddress();
  const rate = await cweth.rate();
  expect(rate).to.equal(UNIT);
  for (const s of [attacker, honest]) {
    await (await cweth.connect(s).setOperator(nftAddr, (await time.latest()) + 365 * 24 * 3600)).wait();
  }
  // A never-funded account cannot spend at all (ERC7984ZeroBalance), so the attacker holds one unit once
  // (1e9 wei) and then "mints" tokens asking for more than that: the transfer moves nothing.
  await (await weth.connect(attacker).deposit({ value: UNIT })).wait();
  await (await weth.connect(attacker).approve(await cweth.getAddress(), UNIT)).wait();
  await (await cweth.connect(attacker).wrap(attacker.address, UNIT)).wait();
  return { deployer, attacker, keeper, rival, honest, weth, cweth, nft, nftAddr };
}
type Env = Awaited<ReturnType<typeof env>>;

type MintOpts = {
  creator?: any; // default attacker
  to?: string; // default creator
  funded?: bigint; // units really held and deposited (0 = the creator holds nothing)
  asked?: bigint; // units asked for (default 1000)
  rate?: number; // ratePerSec
  fee?: bigint;
  interval?: number;
  enabled?: boolean;
};

// Mints one automatic token. Returns its id and the gas the mint cost the creator.
async function mintOne(e: Env, o: MintOpts = {}) {
  const creator = o.creator ?? e.attacker;
  const funded = o.funded ?? 0n;
  if (funded > 0n) {
    const wei = funded * UNIT;
    await (await e.weth.connect(creator).deposit({ value: wei })).wait();
    await (await e.weth.connect(creator).approve(await e.cweth.getAddress(), wei)).wait();
    await (await e.cweth.connect(creator).wrap(creator.address, wei)).wait();
  }
  const enc = await fhevm.createEncryptedInput(e.nftAddr, creator.address).add64(funded > 0n ? funded : (o.asked ?? 1000n)).encrypt();
  const tx = await e.nft.connect(creator).mintAuto(
    o.to ?? creator.address, enc.handles[0], enc.inputProof,
    [{ duration: 1_000_000, ratePerSec: o.rate ?? 1 }], 0, false, ethers.ZeroHash,
    o.enabled ?? true, o.interval ?? HOUR, o.fee ?? 10n ** 18n,
  );
  const r = (await tx.wait())!;
  return { id: await e.nft.totalMinted(), mintGas: r.gasUsed };
}

type Hooks = { beforeRequest?: (id: bigint) => Promise<void> };

// A KeeperContract over the keeper's signer that records the keeper's gas.
function meter(e: Env, hooks: Hooks = {}) {
  const real = e.nft.connect(e.keeper) as any;
  const m = { reqGas: 0n, finGas: 0n, gasWei: 0n, calls: 0 };
  const rec = (tx: any, kind: "reqGas" | "finGas") => ({
    hash: tx.hash as string,
    wait: async () => {
      const r = await tx.wait();
      m[kind] += r.gasUsed;
      m.gasWei += r.gasUsed * r.gasPrice;
      return r;
    },
  });
  const finalizePayout: any = async (id: bigint, a: bigint, p: string, o?: { gasLimit: bigint }) =>
    rec(await real.finalizePayout(id, a, p, o), "finGas");
  finalizePayout.estimateGas = (id: bigint, a: bigint, p: string) => real.finalizePayout.estimateGas(id, a, p);
  const count = <T extends (...a: any[]) => any>(f: T) => ((...a: any[]) => (m.calls++, f(...a))) as T;
  const c = {
    totalMinted: count(() => real.totalMinted()),
    payoutDue: count((i: bigint) => real.payoutDue(i)),
    pendingPayoutOf: count((i: bigint) => real.pendingPayoutOf(i)),
    lastPayoutOf: count((i: bigint) => real.lastPayoutOf(i)),
    autoPayoutOf: count((i: bigint) => real.autoPayoutOf(i)),
    requestPayout: async (id: bigint, min: bigint) => {
      await hooks.beforeRequest?.(id);
      return rec(await real.requestPayout(id, min), "reqGas");
    },
    finalizePayout,
  };
  return { m, c: c as unknown as KeeperContract & Record<string, any> };
}

async function pass(e: Env, o: { includeDry?: boolean; minFee?: bigint; hooks?: Hooks; contract?: any; decrypt?: any; timeoutMs?: number } = {}) {
  const { m, c } = meter(e, o.hooks);
  const lines: string[] = [];
  const bal0 = await ethers.provider.getBalance(e.keeper.address);
  const res = await runKeeperPass({
    contracts: [{ label: "auto", contract: o.contract ?? c }],
    publicDecrypt: o.decrypt ?? DECRYPT,
    includeDry: o.includeDry ?? false,
    minFee: o.minFee ?? 0n,
    timeoutMs: o.timeoutMs,
    log: (l) => lines.push(l),
  });
  const bal1 = await ethers.provider.getBalance(e.keeper.address);
  // What the keeper received as fees: balance change plus the gas it paid.
  const income = bal1 - bal0 + m.gasWei;
  return { res, m, lines, income };
}

const eth = (w: bigint) => ethers.formatEther(w);

describe("Task 8 / C4-2: what can an attacker make a keeper spend", () => {
  const N = 3;
  const INTERVALS = 3;

  // Runs `INTERVALS` passes over N attacker tokens; returns per-interval keeper figures.
  async function campaign(label: string, cfg: { includeDry?: boolean; minFee?: bigint }, tok: MintOpts) {
    const e = await env();
    let mintGas = 0n;
    for (let i = 0; i < N; i++) mintGas += (await mintOne(e, tok)).mintGas;
    const rows: { requested: number; finished: number; keeperGas: bigint; gasWei: bigint; income: bigint }[] = [];
    for (let k = 0; k < INTERVALS; k++) {
      await time.increase(HOUR + 1);
      const p = await pass(e, cfg);
      rows.push({ requested: p.res.requested, finished: p.res.finished, keeperGas: p.m.reqGas + p.m.finGas, gasWei: p.m.gasWei, income: p.income });
      expect(p.res.failed).to.equal(0);
    }
    const paid = await e.nft.queryFilter(e.nft.filters.PayoutPaid());
    const fees = paid.reduce((a, ev) => a + ev.args.feeWei, 0n);
    console.log(`    [C4-2] ${label}: attacker mint gas/token ${mintGas / BigInt(N)}; per interval (keeper gas/token, gas wei/token, fee income/token):`);
    rows.forEach((r, k) =>
      console.log(`      interval ${k + 1}: ${r.requested} req, ${r.finished} fin, gas/token ${r.keeperGas / BigInt(N)}, ${eth(r.gasWei / BigInt(N))} ETH, income/token ${eth(r.income / BigInt(N))} ETH`));
    return { rows, mintGas: mintGas / BigInt(N), fees, e };
  }

  const unfunded: MintOpts = { funded: 0n, fee: 10n ** 18n };

  it("C4-2: unfunded tokens, default settings: two transactions per token once, then skipped; pays the keeper nothing", async () => {
    const r = await campaign("unfunded / default", {}, unfunded);
    expect(r.rows[0].requested).to.equal(N);
    expect(r.rows[0].finished).to.equal(N);
    expect(r.rows[0].keeperGas).to.be.gt(0n);
    expect(r.rows[0].income).to.equal(0n);
    // The zero payout is remembered: later intervals cost the keeper nothing.
    for (const row of r.rows.slice(1)) {
      expect(row.requested).to.equal(0);
      expect(row.keeperGas).to.equal(0n);
    }
    expect(r.fees).to.equal(0n);
    // The keeper's one round trip costs about what the attacker's mint did (no large amplification, and only once).
    console.log(`    [C4-2] ratio keeper-first-interval gas / attacker mint gas per token = ${Number(r.rows[0].keeperGas / BigInt(N)) / Number(r.mintGas)}`);
    expect(r.rows[0].keeperGas / BigInt(N)).to.be.lt(r.mintGas * 2n);
  });

  it("C4-2: unfunded tokens advertising a fee still pass KEEPER_MIN_FEE (the threshold sees the advertised fee, not the payout)", async () => {
    const e0 = await campaign("unfunded / minFee=0.001 ETH (advertised 1 ETH)", { minFee: 10n ** 15n }, unfunded);
    expect(e0.rows[0].requested).to.equal(N);
    expect(e0.rows[0].income).to.equal(0n);
    expect(e0.rows[1].requested).to.equal(0);
    // A threshold above the advertised fee does stop it (the attacker just advertises more).
    const e = await env();
    await mintOne(e, { ...unfunded, fee: 10n ** 14n });
    await time.increase(HOUR + 1);
    const p = await pass(e, { minFee: 10n ** 15n });
    expect(p.res).to.deep.equal({ requested: 0, finished: 0, failed: 0 });
  });

  it("C4-2: unfunded tokens with KEEPER_INCLUDE_DRY: the keeper pays every interval, the attacker nothing after the mint", async () => {
    const r = await campaign("unfunded / includeDry", { includeDry: true }, unfunded);
    for (const row of r.rows) {
      expect(row.requested).to.equal(N);
      expect(row.finished).to.equal(N);
      expect(row.income).to.equal(0n);
    }
    // Per interval the keeper spends the same again; the attacker's cost per interval is zero.
    expect(r.rows[2].keeperGas).to.be.gt(0n);
    expect(r.fees).to.equal(0n);
  });

  it("F-C4-2a (fixed): dust-funded tokens: a keeper with a minimum fee pays for one payout per token, then judges the fee by what was paid and stops", async () => {
    // 100k units (0.0001 ETH) in each token, 1 unit/s, hourly: a payout of ~3600 units (3.6e-6 ETH),
    // so a fee of ~3.6e-7 ETH however much is advertised. The attacker is the recipient.
    const tok: MintOpts = { funded: 100_000n, rate: 1, fee: 10n ** 18n };
    const r = await campaign("dust / minFee=0.001 ETH", { minFee: 10n ** 15n }, tok);
    // Never paid before, so only the advertised fee is known: requested once.
    expect(r.rows[0].requested).to.equal(N);
    expect(r.rows[0].income).to.be.lt(10n ** 15n * BigInt(N));
    for (const row of r.rows.slice(1)) {
      expect(row.requested).to.equal(0);
      expect(row.finished).to.equal(0);
      expect(row.keeperGas).to.equal(0n);
    }
  });

  it("F-C4-2a: without a minimum fee the keeper still requests dust payouts every interval (the operator asked for no minimum)", async () => {
    const tok: MintOpts = { funded: 100_000n, rate: 1, fee: 10n ** 18n };
    for (const [label, cfg] of [["dust / default", {}], ["dust / includeDry", { includeDry: true }]] as const) {
      const r = await campaign(label, cfg, tok);
      for (const row of r.rows) {
        expect(row.requested).to.equal(N);
        expect(row.finished).to.equal(N);
        expect(row.income).to.be.gt(0n);
        expect(row.income).to.be.lt(row.gasWei / 100n); // earns under 1% of its gas
      }
    }
  });

  it("C4-2: a fee lowered after the scan makes that request revert with FeeTooLow: no transaction is sent, the other tokens still pay", async () => {
    const e = await env();
    for (let i = 0; i < 3; i++) await mintOne(e, { funded: 100_000n, fee: 5000n * UNIT, rate: 1000 });
    await time.increase(HOUR + 1);
    let nonceBefore = 0, nonceAfter = 0;
    const p = await pass(e, {
      hooks: {
        beforeRequest: async (id) => {
          if (id === 2n) {
            await (await e.nft.connect(e.attacker).setAutoPayout(2n, true, HOUR, 1n)).wait();
            nonceBefore = await ethers.provider.getTransactionCount(e.keeper.address);
          }
        },
      },
    });
    nonceAfter = await ethers.provider.getTransactionCount(e.keeper.address);
    // Token 2 failed in "requesting" and cost nothing (the estimate reverted, nothing was broadcast);
    // tokens 1 and 3 were requested and finished.
    expect(p.res).to.deep.equal({ requested: 2, finished: 2, failed: 1 });
    expect(p.lines.join("\n")).to.match(/auto #2: requesting: FAILED/);
    expect(p.lines.join("\n")).to.match(/FeeTooLow/);
    expect(nonceBefore).to.be.gt(0);
    // Between token 2's failure and the end, the keeper sent: token 3 request, then 3 finalises... tx for #2: none.
    const sentForTwo = (await e.nft.queryFilter(e.nft.filters.PayoutRequested(2n))).length;
    expect(sentForTwo).to.equal(0);
    expect(nonceAfter).to.be.gte(nonceBefore);
  });

  it("C4-2: settings toggled around the request: disabled before is a free per-token failure; changes after the request cannot change fee or recipient", async () => {
    const e = await env();
    const a = await mintOne(e, { funded: 100_000_000n, fee: 5000n * UNIT, rate: 1000 });
    const b = await mintOne(e, { funded: 100_000_000n, fee: 5000n * UNIT, rate: 1000 });
    await time.increase(HOUR + 1);
    // Before: token a disabled between scan and request.
    const p = await pass(e, {
      hooks: {
        beforeRequest: async (id) => {
          if (id === a.id) await (await e.nft.connect(e.attacker).setAutoPayout(a.id, false, HOUR, 5000n * UNIT)).wait();
        },
      },
    });
    expect(p.res).to.deep.equal({ requested: 1, finished: 1, failed: 1 });
    expect(p.lines.join("\n")).to.match(/AutoPayoutDisabled/);
    // After: owner of token b zeroes the fee and disables payouts after the request, before the finalise.
    await time.increase(HOUR + 1);
    const real = e.nft.connect(e.keeper) as any;
    await (await real.requestPayout(b.id, 0n)).wait();
    const pendingFee = (await e.nft.pendingPayoutOf(b.id)).fee;
    await (await e.nft.connect(e.attacker).setAutoPayout(b.id, false, HOUR, 0n)).wait();
    expect((await e.nft.pendingPayoutOf(b.id)).fee).to.equal(pendingFee);
    const p2 = await pass(e);
    expect(p2.res.finished).to.equal(1);
    expect(p2.income).to.be.gt(0n); // the fee fixed at request time is still paid
  });

  it("C4-2 / D-C4-2b: a rival who requests first makes the keeper finalise for no fee (finalise ignores skip-zero and min-fee), at 3x the rival's cost", async () => {
    // Unfunded tokens (payout zero), attacker is the requester every interval. The keeper's plan is
    // "finish every pending payout, whatever its fee", so the keeper pays the finalise each time.
    const e = await env();
    const ids: bigint[] = [];
    for (let i = 0; i < N; i++) ids.push((await mintOne(e, { funded: 0n, fee: 10n ** 18n })).id);
    let attackerGas = 0n, keeperGas = 0n;
    for (let k = 0; k < INTERVALS; k++) {
      await time.increase(HOUR + 1);
      for (const id of ids) {
        const r = await (await e.nft.connect(e.rival).requestPayout(id, 0n)).wait();
        attackerGas += r!.gasUsed;
      }
      // The keeper runs with the strictest settings: default skip-zero and a minimum fee.
      const p = await pass(e, { minFee: 10n ** 15n });
      keeperGas += p.m.finGas;
      // The keeper finalises each, unpaid, every interval.
      expect(p.res).to.deep.equal({ requested: 0, finished: N, failed: 0 });
      expect(p.income).to.equal(0n);
      expect(p.m.reqGas).to.equal(0n);
    }
    console.log(`    [C4-2] rival requests: attacker gas ${attackerGas}, keeper finalise gas ${keeperGas} (ratio ${Number(keeperGas) / Number(attackerGas)})`);
    // No amplification: the rival pays more than three times what the keeper does.
    expect(keeperGas).to.be.gt(0n);
    expect(attackerGas).to.be.gt(keeperGas * 3n);
  });

  it("C4-2: a competing requester front-running the keeper: the keeper's request fails PayoutPending for free, the rival earns the fee", async () => {
    const e = await env();
    const t = await mintOne(e, { funded: 100_000n, fee: 5000n * UNIT, rate: 1000 });
    await time.increase(HOUR + 1);
    const rivalBal0 = await ethers.provider.getBalance(e.rival.address);
    let rivalGas = 0n;
    const p = await pass(e, {
      hooks: {
        beforeRequest: async (id) => {
          const r = await (await e.nft.connect(e.rival).requestPayout(id, 0n)).wait();
          rivalGas += r!.gasUsed * r!.gasPrice;
        },
      },
    });
    expect(p.res).to.deep.equal({ requested: 0, finished: 0, failed: 1 });
    expect(p.lines.join("\n")).to.match(/PayoutPending/);
    expect(p.m.gasWei).to.equal(0n); // the failed request cost the keeper nothing
    // Next pass the keeper finalises, at its cost, and the fee goes to the rival.
    const p2 = await pass(e);
    expect(p2.res.finished).to.equal(1);
    expect(p2.income).to.equal(0n);
    const rivalBal1 = await ethers.provider.getBalance(e.rival.address);
    expect(rivalBal1 - rivalBal0 + rivalGas).to.be.gt(0n);
    const ev = (await e.nft.queryFilter(e.nft.filters.PayoutPaid(t.id)))[0];
    expect(ev.args.feeWei).to.be.gt(0n);
  });

  it("C4-2: the owner claims just before the request: the keeper gets a near-zero payout, then the token is skipped", async () => {
    const e = await env();
    const t = await mintOne(e, { funded: 100_000n, fee: 5000n * UNIT, rate: 1000 });
    await time.increase(HOUR + 1);
    const p = await pass(e, {
      hooks: { beforeRequest: async (id) => void (await (await e.nft.connect(e.attacker).claim(id)).wait()) },
    });
    expect(p.res).to.deep.equal({ requested: 1, finished: 1, failed: 0 });
    const last = await e.nft.lastPayoutOf(t.id);
    // Only the one or two seconds between the claim and the request are left: a payout around 1000-3000 units, vs 3.6M for the interval.
    expect(last.amountWei).to.be.lt(10_000n * UNIT);
    expect(p.income).to.be.lt(10_000n * UNIT / 10n);
    expect(p.income).to.be.lt(p.m.gasWei / 100n);
  });

  it("C4-2: a recipient that burns all gas: the payment still completes, for at most the 100k send gas extra", async () => {
    const e = await env();
    const honestT = await mintOne(e, { funded: 100_000n, fee: 5000n * UNIT, rate: 1000 });
    // Mint to a plain address, then give it code that spins forever. Its ETH receive burns all of SEND_GAS.
    const burner = ethers.Wallet.createRandom().address;
    const burnT = await mintOne(e, { funded: 100_000n, fee: 5000n * UNIT, rate: 1000, to: burner });
    await setCode(burner, "0x5b600056");
    await time.increase(HOUR + 1);
    const p = await pass(e);
    expect(p.res).to.deep.equal({ requested: 2, finished: 2, failed: 0 });
    const evs = await e.nft.queryFilter(e.nft.filters.PayoutPaid());
    const byId = (id: bigint) => evs.find((x) => x.args.tokenId === id)!;
    expect(byId(burnT.id).args.paidInWeth).to.equal(true);
    expect(byId(honestT.id).args.paidInWeth).to.equal(false);
    // Fee still reaches the keeper from the burner token.
    expect(byId(burnT.id).args.feeWei).to.be.gt(0n);
    const rBurn = await (await e.nft.queryFilter(e.nft.filters.PayoutPaid(burnT.id)))[0].getTransactionReceipt();
    const rHonest = await (await e.nft.queryFilter(e.nft.filters.PayoutPaid(honestT.id)))[0].getTransactionReceipt();
    const extra = rBurn.gasUsed - rHonest.gasUsed;
    console.log(`    [C4-2] finalise gas honest ${rHonest.gasUsed}, burner recipient ${rBurn.gasUsed}, extra ${extra}`);
    expect(extra).to.be.gt(0n);
    expect(extra).to.be.lt(200_000n);
  });
});

describe("Task 8 / C5-5: keeper script review", () => {
  it("C5-5: the script never reads or prints a key; the only PRIVATE_KEY mention is an error string", () => {
    const root = join(__dirname, "..", "..");
    const src = readFileSync(join(root, "scripts", "keeper.ts"), "utf8") + readFileSync(join(root, "tasks", "keeper.ts"), "utf8");
    expect(src).to.not.match(/privateKey|mnemonic|process\.env\.PRIVATE_KEY|readFileSync|dotenv/i);
    const hits = src.match(/PRIVATE_KEY/g) ?? [];
    expect(hits).to.have.length(1);
    expect(src).to.match(/throw new Error\(`PRIVATE_KEY is not set/);
    // Printed: network, keeper address, balance, min fee. Never a signer object.
    const logs = (src.match(/console\.log\([^\n]*\)/g) ?? []).join("\n");
    expect(logs).to.not.match(/signers?\b(?!\.length)|keeper\b(?!\.address)/);
    // The key is the hardhat config's (process.env.PRIVATE_KEY, sepolia accounts); there it stays in the config.
    expect(readFileSync(join(root, "hardhat.config.ts"), "utf8")).to.match(/accounts: process\.env\.PRIVATE_KEY \?/);
  });

  async function threeTokens() {
    const e = await env();
    for (let i = 0; i < 3; i++) await mintOne(e, { funded: 100_000n, fee: 5000n * UNIT, rate: 1000 });
    await time.increase(HOUR + 1);
    return e;
  }

  it("C5-5: a token whose request reverts does not stop the others (also covered by the C4-2 FeeTooLow test)", async () => {
    const e = await threeTokens();
    const p = await pass(e, {
      hooks: { beforeRequest: async (id) => void (id === 1n && (await (await e.nft.connect(e.attacker).setAutoPayout(1n, false, HOUR, 0n)).wait())) },
    });
    expect(p.res).to.deep.equal({ requested: 2, finished: 2, failed: 1 });
  });

  it("C5-5: a token whose finalise always fails (decrypt throws, or returns malformed data) is counted and the others finish", async () => {
    for (const bad of [
      async () => { throw new Error("relayer 500"); },
      async (h: string[]) => ({ clearValues: {}, decryptionProof: "0x" }), // value missing
      async (h: string[]) => ({ clearValues: { [h[0]]: "not a number" }, decryptionProof: "0x" }),
      async (h: string[]) => ({ clearValues: { [h[0]]: 123456789n }, decryptionProof: "0x1234" }), // wrong amount and proof
      async (h: string[]) => null, // malformed response
    ]) {
      const e = await threeTokens();
      let n = 0;
      const decrypt = async (h: string[]) => {
        n++;
        // The first decrypt of each phase (token 1's) is the bad one; the rest are real.
        return n === 1 || n === 4 ? (bad as any)(h) : DECRYPT(h);
      };
      const p = await pass(e, { decrypt });
      expect(p.res.requested).to.equal(3);
      expect(p.res.finished).to.equal(2);
      expect(p.res.failed).to.equal(1);
      // No transaction was sent for the bad finalise (the estimate reverted or the decrypt threw first).
      expect((await e.nft.pendingPayoutOf(1n)).requestId).to.not.equal(ethers.ZeroHash);
      // A later pass with a working relayer finishes it.
      const later = await pass(e);
      expect(later.res).to.deep.equal({ requested: 0, finished: 1, failed: 0 });
    }
  });

  it("F-C5-5a (fixed): a decrypt that never answers times out: that token fails, the others finish, and a later pass finishes it", async () => {
    const e = await threeTokens();
    let first = true;
    const decrypt = (h: string[]) => {
      if (first) { first = false; return new Promise<never>(() => {}); } // relayer accepts the request and never answers
      return DECRYPT(h);
    };
    const p = await pass(e, { decrypt, timeoutMs: 300 });
    expect(p.res).to.deep.equal({ requested: 3, finished: 2, failed: 1 });
    expect(p.lines.join("\n")).to.match(/auto #1: finishing: FAILED: the decryption timed out after 0\.3 s/);
    expect((await e.nft.queryFilter(e.nft.filters.PayoutPaid())).length).to.equal(2);
    expect((await pass(e)).res).to.deep.equal({ requested: 0, finished: 1, failed: 0 });
  });

  it("F-C5-5a (fixed): a transaction wait that never returns times out: that token fails and the others are requested and finished", async () => {
    const e = await threeTokens();
    const { c } = meter(e);
    const request = c.requestPayout;
    c.requestPayout = async (id: bigint, min: bigint) => {
      const tx = await request(id, min);
      return id === 1n ? { hash: tx.hash, wait: () => new Promise<never>(() => {}) } : tx;
    };
    const p = await pass(e, { contract: c, timeoutMs: 300 });
    expect(p.res).to.deep.equal({ requested: 2, finished: 2, failed: 1 });
    expect(p.lines.join("\n")).to.match(/auto #1: requesting: FAILED: the transaction 0x[0-9a-f]{64} was not mined within 0\.3 s/);
    // Token 1's request was in fact mined, so the next pass finds it pending and finishes it.
    expect((await pass(e)).res).to.deep.equal({ requested: 0, finished: 1, failed: 0 });
  });

  it("F-C5-5b (fixed): one unreadable token fails alone: a pending payout is still finished and a due one still requested", async () => {
    const e = await threeTokens();
    // Token 1 has a pending payout. Token 2's read fails (a transient RPC error or rate limit).
    await (await (e.nft.connect(e.keeper) as any).requestPayout(1n, 0n)).wait();
    const real = e.nft.connect(e.keeper) as any;
    const stub = {
      ...Object.fromEntries(["totalMinted", "payoutDue", "pendingPayoutOf", "lastPayoutOf", "requestPayout", "finalizePayout"].map((k) => [k, real[k]])),
      autoPayoutOf: async (i: bigint) => { if (i === 2n) throw new Error("eth_call exceeded gas cap"); return real.autoPayoutOf(i); },
    };
    const p = await pass(e, { contract: stub });
    expect(p.res).to.deep.equal({ requested: 1, finished: 2, failed: 1 });
    expect(p.lines.join("\n")).to.match(/auto #2: reading: FAILED: eth_call exceeded gas cap/);
    expect((await e.nft.pendingPayoutOf(1n)).requestId).to.equal(ethers.ZeroHash);
    expect((await e.nft.queryFilter(e.nft.filters.PayoutRequested(2n))).length).to.equal(0);
  });

  it("F-C5-5c (reduced): a token that is neither due nor pending costs two reads per pass, not four", async () => {
    const e = await env();
    for (let i = 0; i < 8; i++) await mintOne(e, { funded: 0n, enabled: false });
    const { m, res } = await pass(e);
    expect(res).to.deep.equal({ requested: 0, finished: 0, failed: 0 });
    // totalMinted, then pendingPayoutOf and payoutDue for each. The scan still grows with every token minted.
    expect(m.calls).to.equal(1 + 2 * 8);
  });
});
