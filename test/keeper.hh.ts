import { expect } from "chai";
import { ethers, fhevm } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import { keeperPlan, keeperRefusal, runKeeperPass, type KeeperToken } from "../tasks/keeper";

const t = (tokenId: bigint, o: Partial<KeeperToken> = {}): KeeperToken => ({
  tokenId, pending: false, due: false, lastPaidZero: false, ...o,
});

describe("keeperPlan", () => {
  it("finishes pending tokens", () =>
    expect(keeperPlan([t(1n, { pending: true }), t(2n)], { includeDry: false })).to.deep.equal({ finish: [1n], request: [] }));
  it("requests due tokens", () =>
    expect(keeperPlan([t(1n, { due: true }), t(2n, { due: true })], { includeDry: false })).to.deep.equal({ finish: [], request: [1n, 2n] }));
  it("leaves out due tokens whose last payout was zero", () =>
    expect(keeperPlan([t(1n, { due: true, lastPaidZero: true }), t(2n, { due: true })], { includeDry: false })).to.deep.equal({ finish: [], request: [2n] }));
  it("includes them with includeDry", () =>
    expect(keeperPlan([t(1n, { due: true, lastPaidZero: true })], { includeDry: true })).to.deep.equal({ finish: [], request: [1n] }));
  it("lists a pending and due token only in finish", () =>
    expect(keeperPlan([t(1n, { pending: true, due: true })], { includeDry: true })).to.deep.equal({ finish: [1n], request: [] }));
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

describe("runKeeperPass (Hardhat + fhevm mock)", () => {
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
          [{ duration: 1000, ratePerSec: 1 }], 0, false, ethers.ZeroHash, true, 3600, 0)
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
      includeDry: false, log: () => {},
    })).to.deep.equal({ requested: 0, finished: 0, failed: 0 });
  });

  it("counts a failed decryption and finishes the payout on a later pass", async () => {
    const { nft, keeper } = await setup();
    await time.increase(100);
    const lines: string[] = [];
    const res = await runKeeperPass({
      contracts: [{ label: "auto", contract: nft.connect(keeper) as any }],
      publicDecrypt: async () => { throw new Error("not ready"); },
      includeDry: false, log: (l) => lines.push(l),
    });
    expect(res).to.deep.equal({ requested: 2, finished: 0, failed: 2 });
    expect(lines.join("\n")).to.match(/not ready/);
    const later = await runKeeperPass({
      contracts: [{ label: "auto", contract: nft.connect(keeper) as any }],
      publicDecrypt: (h) => fhevm.publicDecrypt(h as `0x${string}`[]) as any,
      includeDry: false, log: () => {},
    });
    expect(later).to.deep.equal({ requested: 0, finished: 2, failed: 0 });
  });
});
