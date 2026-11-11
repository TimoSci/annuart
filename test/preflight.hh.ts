import { expect } from "chai";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { passLine, problems, redact, warnings, wethProblem, SEPOLIA_FHEVM, type Facts } from "../tasks/preflight";

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

describe("pre-flight pass line", () => {
  it("is plain only when the relayer check ran and succeeded", () =>
    expect(passLine(good)).to.equal("Pre-flight passed"));
  it("says encryption was not tested when the relayer check was skipped", () =>
    expect(passLine({ ...good, relayerEncryptOk: null })).to.equal("Pre-flight passed (encryption not tested)"));
});

describe("wethProblem", () => {
  const weth = { address: WETH, hasCode: true, symbol: "WETH", decimals: 18 };
  it("accepts a WETH contract", () => expect(wethProblem(weth)).to.equal(null));
  it("refuses an address with no code", () =>
    expect(wethProblem({ ...weth, hasCode: false })).to.match(/WETH_ADDRESS .* is not a WETH contract \(code: no/));
  it("refuses another symbol", () => expect(wethProblem({ ...weth, symbol: "DAI" })).to.match(/symbol: DAI/));
  it("refuses unreadable metadata", () =>
    expect(wethProblem({ ...weth, symbol: null, decimals: null })).to.match(/symbol: unreadable, decimals: unreadable/));
  it("refuses other decimals", () => expect(wethProblem({ ...weth, decimals: 6 })).to.match(/decimals: 6/));
  it("is the rule problems() applies", () =>
    expect(problems({ ...good, weth: { ...good.weth!, symbol: "DAI" } })).to.deep.equal([
      wethProblem({ ...weth, symbol: "DAI" }),
    ]));
});

describe("redact", () => {
  const url = "https://eth-sepolia.example/v2/KEY123";
  it("hides the URL inside a message", () =>
    expect(redact(`request failed (requestUrl="${url}", code=SERVER_ERROR)`, [url]))
      .to.equal('request failed (requestUrl="<SEPOLIA_RPC_URL>", code=SERVER_ERROR)'));
  it("hides every occurrence", () =>
    expect(redact(`${url} then ${url}`, [url])).to.equal("<SEPOLIA_RPC_URL> then <SEPOLIA_RPC_URL>"));
  it("leaves the message alone with no secrets", () => expect(redact(`at ${url}`, [])).to.equal(`at ${url}`));
  it("ignores an unset or empty environment value", () => {
    expect(redact("nothing to hide", [process.env.ANNUART_TEST_UNSET_VARIABLE])).to.equal("nothing to hide");
    expect(redact("nothing to hide", [""])).to.equal("nothing to hide");
  });
  it("treats the secret as text, not a pattern", () =>
    expect(redact("a.b?c=1 and axb", ["a.b?c=1"])).to.equal("<SEPOLIA_RPC_URL> and axb"));
});

describe("SEPOLIA_FHEVM", () => {
  it("matches _getSepoliaConfig in @fhevm/solidity's ZamaConfig.sol", () => {
    const source = readFileSync(join(__dirname, "..", "node_modules", "@fhevm", "solidity", "config", "ZamaConfig.sol"), "utf8");
    const body = source.match(/function _getSepoliaConfig\(\)[^{]*\{([\s\S]*?)\n {4}\}/);
    expect(body, "_getSepoliaConfig not found").to.not.equal(null);
    const field = (name: string) => {
      const m = body![1].match(new RegExp(`${name}:\\s*(0x[0-9a-fA-F]{40})`));
      expect(m, `${name} not found`).to.not.equal(null);
      return m![1].toLowerCase();
    };
    expect({
      acl: field("ACLAddress"),
      coprocessor: field("CoprocessorAddress"),
      kmsVerifier: field("KMSVerifierAddress"),
    }).to.deep.equal({
      acl: SEPOLIA_FHEVM.acl.toLowerCase(),
      coprocessor: SEPOLIA_FHEVM.coprocessor.toLowerCase(),
      kmsVerifier: SEPOLIA_FHEVM.kmsVerifier.toLowerCase(),
    });
  });
});
