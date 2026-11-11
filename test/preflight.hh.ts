import { expect } from "chai";
import { problems, warnings, SEPOLIA_FHEVM, type Facts } from "../tasks/preflight";

const WETH = "0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14";
const good: Facts = {
  chainId: 11155111,
  deployer: "0x1111111111111111111111111111111111111111",
  balanceWei: 100_000_000_000_000_000n,
  codeAt: {
    [SEPOLIA_FHEVM.acl.toLowerCase()]: true,
    [SEPOLIA_FHEVM.coprocessor.toLowerCase()]: true,
    [SEPOLIA_FHEVM.kmsVerifier.toLowerCase()]: true,
    [WETH.toLowerCase()]: true,
  },
  sdk: { acl: SEPOLIA_FHEVM.acl, kmsVerifier: SEPOLIA_FHEVM.kmsVerifier },
  relayerEncryptOk: true,
  weth: { address: WETH, symbol: "WETH", decimals: 18 },
};

describe("pre-flight problems and warnings", () => {
  it("passes a good Sepolia setup silently", () => {
    expect(problems(good)).to.deep.equal([]);
    expect(warnings(good)).to.deep.equal([]);
  });
  it("rejects a network that is not Sepolia", () =>
    expect(problems({ ...good, chainId: 1 }).join("\n")).to.match(/not Sepolia/));
  it("needs a deployer", () =>
    expect(problems({ ...good, deployer: null }).join("\n")).to.match(/PRIVATE_KEY/));
  it("rejects an empty balance", () =>
    expect(problems({ ...good, balanceWei: 0n }).join("\n")).to.match(/no Sepolia ETH/));
  it("warns about a low balance without failing", () => {
    const f = { ...good, balanceWei: 10_000_000_000_000_000n };
    expect(problems(f)).to.deep.equal([]);
    expect(warnings(f)).to.have.length(1);
    expect(warnings(f)[0]).to.match(/below 0\.05/);
  });
  it("rejects missing FHE contracts", () =>
    expect(problems({ ...good, codeAt: { ...good.codeAt, [SEPOLIA_FHEVM.acl.toLowerCase()]: false } }).join("\n")).to.match(/FHE contracts/));
  it("rejects an SDK ACL that differs, ignoring case", () => {
    expect(problems({ ...good, sdk: { ...good.sdk!, acl: SEPOLIA_FHEVM.acl.toLowerCase() } })).to.deep.equal([]);
    expect(problems({ ...good, sdk: { ...good.sdk!, acl: "0x" + "2".repeat(40) } }).join("\n")).to.match(/encryption library.*different/);
  });
  it("rejects an SDK KMS verifier that differs", () =>
    expect(problems({ ...good, sdk: { ...good.sdk!, kmsVerifier: "0x" + "3".repeat(40) } }).join("\n")).to.match(/encryption library.*different/));
  it("rejects a missing SDK config", () =>
    expect(problems({ ...good, sdk: null }).join("\n")).to.match(/encryption library/));
  it("rejects a failing relayer", () =>
    expect(problems({ ...good, relayerEncryptOk: false }).join("\n")).to.match(/relayer/));
  it("warns when the relayer check was skipped", () => {
    const f = { ...good, relayerEncryptOk: null };
    expect(problems(f)).to.deep.equal([]);
    expect(warnings(f).join("\n")).to.match(/relayer check was skipped/);
  });
  it("warns when WETH_ADDRESS is unset", () => {
    const f = { ...good, weth: null };
    expect(problems(f)).to.deep.equal([]);
    expect(warnings(f).join("\n")).to.match(/WETH_ADDRESS is not set.*wrapped/);
  });
  it("rejects a WETH that is not WETH", () => {
    expect(problems({ ...good, weth: { ...good.weth!, symbol: "DAI" } }).join("\n")).to.match(/WETH_ADDRESS/);
    expect(problems({ ...good, weth: { ...good.weth!, decimals: 6 } }).join("\n")).to.match(/WETH_ADDRESS/);
    expect(problems({ ...good, codeAt: { ...good.codeAt, [WETH.toLowerCase()]: false } }).join("\n")).to.match(/WETH_ADDRESS/);
  });
});
