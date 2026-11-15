import { expect } from "chai";
import { ethers, fhevm } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import { keeperExitCode, keeperMinFee, keeperPlan, keeperTimeoutMs, keeperRefusal, runKeeperPass, type KeeperToken } from "../tasks/keeper";

const t = (tokenId: bigint, o: Partial<KeeperToken> = {}): KeeperToken => ({
  tokenId, pending: false, due: false, lastPaidWei: null, fee: 0n, ...o,
});

describe("keeperPlan", () => {
  it("finishes pending tokens", () =>
    expect(keeperPlan([t(1n, { pending: true }), t(2n)], { includeDry: false, minFee: 0n })).to.deep.equal({ finish: [1n], request: [] }));
  it("requests due tokens", () =>
    expect(keeperPlan([t(1n, { due: true }), t(2n, { due: true })], { includeDry: false, minFee: 0n })).to.deep.equal({ finish: [], request: [1n, 2n] }));
  it("leaves out due tokens whose last payout was zero", () =>
    expect(keeperPlan([t(1n, { due: true, lastPaidWei: 0n }), t(2n, { due: true })], { includeDry: false, minFee: 0n })).to.deep.equal({ finish: [], request: [2n] }));
  it("includes them with includeDry", () =>
    expect(keeperPlan([t(1n, { due: true, lastPaidWei: 0n })], { includeDry: true, minFee: 0n })).to.deep.equal({ finish: [], request: [1n] }));
  it("lists a pending and due token only in finish", () =>
    expect(keeperPlan([t(1n, { pending: true, due: true })], { includeDry: true, minFee: 0n })).to.deep.equal({ finish: [1n], request: [] }));
  it("leaves out a due token whose fee is below minFee and requests one at or above it", () =>
    expect(keeperPlan([t(1n, { due: true, fee: 99n }), t(2n, { due: true, fee: 100n }), t(3n, { due: true, fee: 101n })],
      { includeDry: false, minFee: 100n })).to.deep.equal({ finish: [], request: [2n, 3n] }));
  // The contract pays the requester min(fee, payout / 10), so an advertised fee says little.
  it("judges minFee by a tenth of the last payout when that is less than the advertised fee", () =>
    expect(keeperPlan([
      t(1n, { due: true, fee: 10n ** 18n, lastPaidWei: 999n }),  // would pay 99
      t(2n, { due: true, fee: 10n ** 18n, lastPaidWei: 1000n }), // would pay 100
      t(3n, { due: true, fee: 50n, lastPaidWei: 1_000_000n }),   // would pay its fee, 50
      t(4n, { due: true, fee: 100n, lastPaidWei: null }),        // never paid: only the fee is known
    ], { includeDry: false, minFee: 100n })).to.deep.equal({ finish: [], request: [2n, 4n] }));
  it("with a minFee, leaves out a token whose last payout was zero even with includeDry", () =>
    expect(keeperPlan([t(1n, { due: true, fee: 10n ** 18n, lastPaidWei: 0n })], { includeDry: true, minFee: 1n }))
      .to.deep.equal({ finish: [], request: [] }));
  it("still finishes a pending token whose fee is below minFee", () =>
    expect(keeperPlan([t(1n, { pending: true, fee: 0n })], { includeDry: false, minFee: 100n })).to.deep.equal({ finish: [1n], request: [] }));
});

describe("keeperMinFee", () => {
  it("is 0 when unset or empty", () => {
    expect(keeperMinFee(undefined)).to.equal(0n);
    expect(keeperMinFee("")).to.equal(0n);
  });
  it("reads a decimal number of wei", () => {
    expect(keeperMinFee("0")).to.equal(0n);
    expect(keeperMinFee("1000000000000000")).to.equal(10n ** 15n);
  });
  for (const bad of ["-1", "1.5", "1e15", "0x10", "abc", " 12", "12 "]) {
    it(`refuses ${JSON.stringify(bad)}`, () => expect(() => keeperMinFee(bad)).to.throw(/KEEPER_MIN_FEE must be a whole number of wei/));
  }
});

describe("keeperTimeoutMs", () => {
  it("is 60 seconds when unset or empty", () => {
    expect(keeperTimeoutMs(undefined)).to.equal(60_000);
    expect(keeperTimeoutMs("")).to.equal(60_000);
  });
  it("reads whole seconds", () => expect(keeperTimeoutMs("300")).to.equal(300_000));
  for (const bad of ["0", "-1", "1.5", "abc", " 12"]) {
    it(`refuses ${JSON.stringify(bad)}`, () => expect(() => keeperTimeoutMs(bad)).to.throw(/KEEPER_TIMEOUT must be a whole number of seconds/));
  }
});

describe("keeperRefusal", () => {
  it("passes on a local chain", () =>
    expect(keeperRefusal({ network: "localhost", isLocal: true, confirm: undefined })).to.equal(null));
  it("refuses a public network without confirmation", () =>
    expect(keeperRefusal({ network: "sepolia", isLocal: false, confirm: undefined })).to.match(/CONFIRM_KEEPER=sepolia/));
  it("refuses a confirmation for another network", () =>
    expect(keeperRefusal({ network: "sepolia", isLocal: false, confirm: "mainnet" })).to.match(/CONFIRM_KEEPER=sepolia/));
  it("passes with the confirmation", () =>
    expect(keeperRefusal({ network: "sepolia", isLocal: false, confirm: "sepolia" })).to.equal(null));
});

describe("keeperExitCode", () => {
  it("is 0 without failures and 1 with any", () => {
    expect(keeperExitCode({ failed: 0 })).to.equal(0);
    expect(keeperExitCode({ failed: 2 })).to.equal(1);
  });
});

describe("runKeeperPass (Hardhat + fhevm mock)", () => {
  const FEE = 5000n;
  async function setup() {
    const [creator, ownerA, ownerB, keeper] = await ethers.getSigners();
    const weth = await (await ethers.getContractFactory("MockWETH")).deploy();
    const cweth = await (await ethers.getContractFactory("ConfidentialWETH")).deploy(await weth.getAddress());
    const cwethAddr = await cweth.getAddress();
    const nft = await (await ethers.getContractFactory("AutoPayoutEndowmentNFT")).deploy(cwethAddr);
    const nftAddr = await nft.getAddress();
    const rate = await cweth.rate();
    await (await weth.deposit({ value: 2000n * rate })).wait();
    await (await weth.approve(cwethAddr, 2000n * rate)).wait();
    await (await cweth.wrap(creator.address, 2000n * rate)).wait();
    await (await cweth.setOperator(nftAddr, (await time.latest()) + 365 * 24 * 3600)).wait();
    for (const owner of [ownerA, ownerB]) {
      const enc = await fhevm.createEncryptedInput(nftAddr, creator.address).add64(1000).encrypt();
      await (
        await nft.mintAuto(owner.address, enc.handles[0], enc.inputProof,
          [{ duration: 1000, ratePerSec: 1 }], 0, false, ethers.ZeroHash, true, 3600, FEE)
      ).wait();
    }
    return { nft, keeper, ownerA, ownerB, rate };
  }

  it("requests and finishes both due payouts", async () => {
    const { nft, keeper, ownerA, ownerB } = await setup();
    await time.increase(100);
    const a0 = await ethers.provider.getBalance(ownerA.address);
    const b0 = await ethers.provider.getBalance(ownerB.address);
    const lines: string[] = [];
    const res = await runKeeperPass({
      contracts: [{ label: "auto", contract: nft.connect(keeper) as any }],
      publicDecrypt: (h) => fhevm.publicDecrypt(h as `0x${string}`[]) as any,
      includeDry: false,
      minFee: 0n,
      log: (l) => lines.push(l),
    });
    expect(res).to.deep.equal({ requested: 2, finished: 2, failed: 0 });
    expect(await ethers.provider.getBalance(ownerA.address)).to.be.gt(a0);
    expect(await ethers.provider.getBalance(ownerB.address)).to.be.gt(b0);
    expect((await nft.pendingPayoutOf(1n)).requestId).to.equal(ethers.ZeroHash);
    expect(lines.join("\n")).to.match(/auto #1: requesting payout/);
    // Nothing is due straight afterwards.
    expect(await runKeeperPass({
      contracts: [{ label: "auto", contract: nft.connect(keeper) as any }],
      publicDecrypt: (h) => fhevm.publicDecrypt(h as `0x${string}`[]) as any,
      includeDry: false, minFee: 0n, log: () => {},
    })).to.deep.equal({ requested: 0, finished: 0, failed: 0 });
  });

  it("counts a failed decryption and finishes the payout on a later pass", async () => {
    const { nft, keeper } = await setup();
    await time.increase(100);
    const lines: string[] = [];
    const res = await runKeeperPass({
      contracts: [{ label: "auto", contract: nft.connect(keeper) as any }],
      publicDecrypt: async () => { throw new Error("not ready"); },
      includeDry: false, minFee: 0n, log: (l) => lines.push(l),
    });
    expect(res).to.deep.equal({ requested: 2, finished: 0, failed: 2 });
    expect(lines.join("\n")).to.match(/not ready/);
    const later = await runKeeperPass({
      contracts: [{ label: "auto", contract: nft.connect(keeper) as any }],
      publicDecrypt: (h) => fhevm.publicDecrypt(h as `0x${string}`[]) as any,
      includeDry: false, minFee: 0n, log: () => {},
    });
    expect(later).to.deep.equal({ requested: 0, finished: 2, failed: 0 });
  });

  it("passes the token's fee as minFee and sends finalizePayout with estimate + 20% gas", async () => {
    const { nft, keeper } = await setup();
    await time.increase(100);
    const real = nft.connect(keeper) as any;
    const mins: bigint[] = [];
    const gas: { est: bigint; limit: bigint }[] = [];
    let lastEst = 0n;
    const finalizePayout: any = (id: bigint, a: bigint, p: string, o?: { gasLimit: bigint }) => {
      gas.push({ est: lastEst, limit: o!.gasLimit });
      return real.finalizePayout(id, a, p, o);
    };
    finalizePayout.estimateGas = async (id: bigint, a: bigint, p: string) =>
      (lastEst = await real.finalizePayout.estimateGas(id, a, p));
    const spy = {
      totalMinted: () => real.totalMinted(),
      payoutDue: (i: bigint) => real.payoutDue(i),
      pendingPayoutOf: (i: bigint) => real.pendingPayoutOf(i),
      lastPayoutOf: (i: bigint) => real.lastPayoutOf(i),
      autoPayoutOf: (i: bigint) => real.autoPayoutOf(i),
      requestPayout: (i: bigint, m: bigint) => (mins.push(m), real.requestPayout(i, m)),
      finalizePayout,
    };
    const res = await runKeeperPass({
      contracts: [{ label: "auto", contract: spy as any }],
      publicDecrypt: (h) => fhevm.publicDecrypt(h as `0x${string}`[]) as any,
      includeDry: false, minFee: 0n, log: () => {},
    });
    expect(res).to.deep.equal({ requested: 2, finished: 2, failed: 0 });
    expect(mins).to.deep.equal([FEE, FEE]);
    expect(gas).to.have.length(2);
    for (const g of gas) expect(g.limit).to.equal((g.est * 120n) / 100n);
    const paid = (await nft.queryFilter(nft.filters.PayoutPaid())).map((e) => e.args.feeWei);
    expect(paid).to.deep.equal([FEE, FEE]);
  });

  it("does not request a due payout whose fee is below minFee", async () => {
    const { nft, keeper } = await setup();
    await time.increase(100);
    const lines: string[] = [];
    const res = await runKeeperPass({
      contracts: [{ label: "auto", contract: nft.connect(keeper) as any }],
      publicDecrypt: (h) => fhevm.publicDecrypt(h as `0x${string}`[]) as any,
      includeDry: false, minFee: FEE + 1n, log: (l) => lines.push(l),
    });
    expect(res).to.deep.equal({ requested: 0, finished: 0, failed: 0 });
    expect(lines.join("\n")).to.match(/auto: 2 token\(s\), 0 to finish, 0 to request/);
    expect(await nft.payoutDue(1n)).to.equal(true);
  });

  it("counts a failed scan of one contract and still processes the next", async () => {
    const { nft, keeper } = await setup();
    await time.increase(100);
    const broken = { totalMinted: async () => { throw new Error("rpc down https://secret.example/key"); } };
    const lines: string[] = [];
    const res = await runKeeperPass({
      contracts: [
        { label: "broken", contract: broken as any },
        { label: "auto", contract: nft.connect(keeper) as any },
      ],
      publicDecrypt: (h) => fhevm.publicDecrypt(h as `0x${string}`[]) as any,
      includeDry: false, minFee: 0n, log: (l) => lines.push(l),
      secrets: ["https://secret.example/key"],
    });
    expect(res).to.deep.equal({ requested: 2, finished: 2, failed: 1 });
    const out = lines.join("\n");
    expect(out).to.match(/broken: reading tokens: FAILED: rpc down <SEPOLIA_RPC_URL>/);
    expect(out).to.not.match(/secret\.example/);
  });
});
