import { expect } from "chai";
import { existsSync } from "fs";
import { spawnSync } from "child_process";
import { ethers } from "hardhat";
import { reusedUnderlying } from "../../tasks/deployGuard";
import { wethProblem } from "../../tasks/preflight";

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
  // SECURE EXPECTATION: refuses a TOKEN_ADDRESS whose underlying() is not a WETH contract, as
  // checkWeth already does for a WETH_ADDRESS the script wraps itself.
  it("FINDING F-C5-1a: a wrapper over a non-WETH token passes the reused-token path and the contract accepts it", async () => {
    const [deployer] = await ethers.getSigners();
    // Any contract can stand in as the "underlying": here the mock confidential token (symbol MOCK, 6 decimals).
    const notWeth = await (await ethers.getContractFactory("MockConfidentialToken")).deploy();
    const notWethAddr = await notWeth.getAddress();
    const wrapper = await (await ethers.getContractFactory("ConfidentialWETH")).deploy(notWethAddr);

    // scripts/deploy.ts, reuse path, TOKEN_KIND=wrapped (also NFT_KIND=auto): it reads underlying()...
    const reported = await new ethers.Contract(
      await wrapper.getAddress(),
      ["function underlying() view returns (address)"],
      ethers.provider,
    )
      .underlying()
      .then(String, () => null);
    // ...and hands it to reusedUnderlying, with WETH_ADDRESS unset or set to that same address.
    expect(reusedUnderlying({ reported, wethAddress: undefined })).to.deep.equal({ underlying: notWethAddr });
    expect(reusedUnderlying({ reported, wethAddress: notWethAddr })).to.deep.equal({ underlying: notWethAddr });

    // The WETH rule exists and would refuse it, but this path never applies it (checkWeth runs only
    // when the script deploys the wrapper itself).
    const symbol = await new ethers.Contract(notWethAddr, ["function symbol() view returns (string)"], ethers.provider)
      .symbol()
      .then(String, () => null);
    expect(symbol).to.equal("MOCK");
    expect(wethProblem({ address: notWethAddr, hasCode: true, symbol, decimals: 6 })).to.match(/is not a WETH contract/);

    // And the contract takes it: NotWethWrapper fires only for the zero address.
    const nft = await (await ethers.getContractFactory("AutoPayoutEndowmentNFT")).connect(deployer).deploy(await wrapper.getAddress());
    expect(await nft.weth()).to.equal(notWethAddr);
  });
});
