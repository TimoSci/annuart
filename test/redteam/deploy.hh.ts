import { expect } from "chai";
import { existsSync } from "fs";
import { spawnSync } from "child_process";
import { ethers } from "hardhat";
import { reusedWrappedUnderlying } from "../../tasks/wethCheck";

// Task 9 (C5-1): the deploy script is the only guard that the token under an AutoPayoutEndowmentNFT
// is a WETH wrapper (the contract itself only checks that underlying() is not the zero address).
// The wrong inputs already refused by existing tests are cited in the report (test/deployGuard.hh.ts,
// test/preflight.hh.ts). This file adds what those do not reach: the script run for real
// (in-process network, refusals only, nothing is deployed or written), and one gap.

// Runs scripts/deploy.ts on the default in-process network. The environment is built from scratch:
// no SEPOLIA_RPC_URL, no PRIVATE_KEY, no CONFIRM_*; `.env` is not read.
function runDeploy(env: Record<string, string>) {
  const r = spawnSync("npx", ["hardhat", "run", "scripts/deploy.ts"], {
    env: { PATH: process.env.PATH ?? "", HOME: process.env.HOME ?? "", ...env },
    encoding: "utf8",
    timeout: 120_000,
  });
  return { code: r.status, out: (r.stdout ?? "") + (r.stderr ?? "") };
}

describe("C5-1 deploy script refusals (script run for real, nothing sent)", function () {
  this.timeout(300_000);
  const noFile = () => expect(existsSync("deployments/hardhat.json"), "nothing recorded").to.equal(false);

  it("C5-1: WETH_ADDRESS with no contract code is refused before any deploy", () => {
    const r = runDeploy({ TOKEN_KIND: "wrapped", WETH_ADDRESS: "0x000000000000000000000000000000000000dEaD" });
    expect(r.code).to.not.equal(0);
    expect(r.out).to.match(/is not a WETH contract \(code: no/);
    expect(r.out).to.not.match(/ConfidentialWETH: 0x|\(tx 0x/); // no deploy line printed
    noFile();
  });

  it("C5-1: a reused TOKEN_ADDRESS with no code is refused before any deploy", () => {
    const r = runDeploy({ TOKEN_KIND: "mock", TOKEN_ADDRESS: "0x000000000000000000000000000000000000dEaD" });
    expect(r.code).to.not.equal(0);
    expect(r.out).to.match(/has no contract code/);
    expect(r.out).to.not.match(/\(tx 0x/);
    noFile();
  });

  it("C5-1: NFT_KIND=auto with a non-wrapped TOKEN_KIND is refused", () => {
    const r = runDeploy({ NFT_KIND: "auto", TOKEN_KIND: "mock" });
    expect(r.code).to.not.equal(0);
    expect(r.out).to.match(/NFT_KIND=auto needs the wrapped token/);
    expect(r.out).to.not.match(/\(tx 0x/);
    noFile();
  });

  it("C5-1: unknown NFT_KIND and TOKEN_KIND are refused", () => {
    const a = runDeploy({ NFT_KIND: "evil" });
    expect(a.out).to.match(/NFT_KIND must be standard or auto/);
    const b = runDeploy({ TOKEN_KIND: "evil" });
    expect(b.out).to.match(/TOKEN_KIND must be mock, wrapped or plain/);
    noFile();
  });
});

describe("C5-1 the deploy script is the only WETH guard", () => {
  async function wrapperOver(factory: string) {
    const underlying = await (await ethers.getContractFactory(factory)).deploy();
    const wrapper = await (await ethers.getContractFactory("ConfidentialWETH")).deploy(await underlying.getAddress());
    return { underlying: await underlying.getAddress(), wrapper: await wrapper.getAddress() };
  }

  it("F-C5-1a (fixed): a reused wrapper over a non-WETH token is refused, with WETH_ADDRESS unset or set to that token", async () => {
    // Any contract can stand in as the "underlying": here the mock confidential token (symbol MOCK, 6 decimals).
    const bad = await wrapperOver("MockConfidentialToken");
    for (const wethAddress of [undefined, bad.underlying]) {
      const r = await reusedWrappedUnderlying(ethers.provider, { token: bad.wrapper, wethAddress, isLocal: true });
      expect(r).to.have.property("refusal").match(/does not wrap WETH/);
      expect(r).to.have.property("refusal").match(/symbol: MOCK, decimals: 6/);
    }
    const noCode = await reusedWrappedUnderlying(ethers.provider, { token: bad.underlying, wethAddress: undefined, isLocal: true });
    expect(noCode).to.have.property("refusal").match(/not a ConfidentialWETH/);
  });

  it("F-C5-1a (fixed): a reused wrapper over WETH is accepted; on a public network only with WETH_ADDRESS naming that WETH", async () => {
    const good = await wrapperOver("MockWETH");
    expect(await reusedWrappedUnderlying(ethers.provider, { token: good.wrapper, wethAddress: undefined, isLocal: true }))
      .to.deep.equal({ underlying: good.underlying });
    expect(await reusedWrappedUnderlying(ethers.provider, { token: good.wrapper, wethAddress: good.underlying, isLocal: false }))
      .to.deep.equal({ underlying: good.underlying });
    // A token can call itself WETH, so on a public network the owner must name the WETH they expect.
    expect(await reusedWrappedUnderlying(ethers.provider, { token: good.wrapper, wethAddress: undefined, isLocal: false }))
      .to.have.property("refusal").match(/Set WETH_ADDRESS/);
  });

  it("C5-1: the contract itself refuses only a zero underlying, so the script's check is the only WETH guard", async () => {
    const bad = await wrapperOver("MockConfidentialToken");
    const nft = await (await ethers.getContractFactory("AutoPayoutEndowmentNFT")).deploy(bad.wrapper);
    expect(await nft.weth()).to.equal(bad.underlying);
  });
});
