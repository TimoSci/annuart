import { expect } from "chai";
import { existsSync, readFileSync, rmSync } from "fs";
import { spawnSync } from "child_process";

// NFT_KIND=private: the deploy script run for real on the in-process network (no --network, so
// "hardhat"; nothing is sent anywhere). Its only file is deployments/hardhat.json, which is not a
// real deployment file; each test removes it afterwards (test/redteam/deploy.hh.ts expects it absent).
const FILE = "deployments/hardhat.json";

function runDeploy(env: Record<string, string>) {
  const r = spawnSync("npx", ["hardhat", "run", "scripts/deploy.ts"], {
    env: { PATH: process.env.PATH ?? "", HOME: process.env.HOME ?? "", ...env },
    encoding: "utf8",
    timeout: 240_000,
  });
  return { code: r.status, out: (r.stdout ?? "") + (r.stderr ?? "") };
}

describe("NFT_KIND=private deploy", function () {
  this.timeout(600_000);
  const clean = () => rmSync(FILE, { force: true });
  beforeEach(function () {
    // Never delete a file somebody else left: stop instead.
    if (existsSync(FILE)) this.skip();
  });
  afterEach(clean);

  const entries = () => JSON.parse(readFileSync(FILE, "utf8")).contracts;

  it("an unknown NFT_KIND is refused with the three kinds named", () => {
    const r = runDeploy({ NFT_KIND: "secret" });
    expect(r.code).to.not.equal(0);
    expect(r.out).to.include('NFT_KIND must be standard or auto or private (got "secret")');
    expect(existsSync(FILE)).to.equal(false);
  });

  it("private over the mock token is labelled private-mock and carries nftKind private", () => {
    const r = runDeploy({ NFT_KIND: "private" });
    expect(r.out).to.match(/PrivateRateEndowmentNFT: 0x/);
    expect(r.code).to.equal(0);
    const [e] = entries();
    expect(e).to.include({ label: "private-mock", nftKind: "private", tokenKind: "mock" });
  });

  it("private over a wrapped token is labelled private", () => {
    const r = runDeploy({ NFT_KIND: "private", TOKEN_KIND: "wrapped" });
    expect(r.code, r.out).to.equal(0);
    const e = entries().find((c: { nftKind?: string }) => c.nftKind === "private");
    expect(e).to.include({ label: "private", tokenKind: "wrapped" });
  });

  it("private over a plain token still needs TOKEN_ADDRESS (the plain kind, labelled private-plain, takes an existing token)", () => {
    const r = runDeploy({ NFT_KIND: "private", TOKEN_KIND: "plain" });
    expect(r.code).to.not.equal(0);
    expect(r.out).to.match(/TOKEN_ADDRESS is required for TOKEN_KIND=plain/);
  });

  it("a wrapped token is reused under the same guard as the standard kind", () => {
    const r = runDeploy({
      NFT_KIND: "private",
      TOKEN_KIND: "wrapped",
      TOKEN_ADDRESS: "0x000000000000000000000000000000000000dEaD",
    });
    expect(r.code).to.not.equal(0);
    expect(r.out).to.match(/has no contract code/);
  });
});
