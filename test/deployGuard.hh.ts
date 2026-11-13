import { expect } from "chai";
import { autoToken, deployRefusal, reusedUnderlying, sentLine } from "../tasks/deployGuard";
import type { Deployment } from "../tasks/deployments";

const base = { network: "sepolia", isLocal: false, chainId: 11155111, expectedChainId: 11155111,
               confirm: "sepolia", label: "mock", existingLabels: [] as string[], replace: false };

describe("deployRefusal", () => {
  it("allows a confirmed first deploy", () => expect(deployRefusal(base)).to.equal(null));
  it("refuses a public network without CONFIRM_DEPLOY", () =>
    expect(deployRefusal({ ...base, confirm: undefined })).to.match(/CONFIRM_DEPLOY=sepolia/));
  it("refuses a confirmation for another network", () =>
    expect(deployRefusal({ ...base, confirm: "mainnet" })).to.match(/CONFIRM_DEPLOY=sepolia/));
  it("refuses when the RPC is not the configured chain", () =>
    expect(deployRefusal({ ...base, chainId: 1 })).to.match(/chain id 1.*11155111/));
  it("refuses to overwrite a recorded label", () =>
    expect(deployRefusal({ ...base, existingLabels: ["mock"] })).to.match(/label "mock" is already deployed.*REPLACE=1.*LABEL=/s));
  it("overwrites with REPLACE=1", () =>
    expect(deployRefusal({ ...base, existingLabels: ["mock"], replace: true })).to.equal(null));
  it("asks for nothing on a local network", () =>
    expect(deployRefusal({ ...base, network: "localhost", isLocal: true, chainId: 31337,
                           expectedChainId: undefined, confirm: undefined, existingLabels: ["mock"] })).to.equal(null));
  it("refuses a public network whose chain id is not configured", () =>
    expect(deployRefusal({ ...base, expectedChainId: undefined })).to.match(/no chainId in hardhat\.config\.ts/));
  it("checks the chain before the confirmation", () =>
    expect(deployRefusal({ ...base, chainId: 1, confirm: undefined })).to.match(/chain id 1/));
  it("reports a label conflict only once confirmed", () =>
    expect(deployRefusal({ ...base, confirm: undefined, existingLabels: ["mock"] })).to.match(/CONFIRM_DEPLOY=sepolia/));
});

describe("reusedUnderlying", () => {
  const w = "0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14";
  it("takes what the token reports", () =>
    expect(reusedUnderlying({ reported: w, wethAddress: undefined })).to.deep.equal({ underlying: w }));
  it("accepts WETH_ADDRESS in a different case", () =>
    expect(reusedUnderlying({ reported: w, wethAddress: w.toLowerCase() })).to.deep.equal({ underlying: w }));
  it("refuses a WETH_ADDRESS that differs, naming both", () => {
    const other = "0x" + "2".repeat(40);
    const r = reusedUnderlying({ reported: w, wethAddress: other }) as { refusal: string };
    expect(r.refusal).to.include(w).and.include(other);
  });
  it("refuses the zero address", () =>
    expect(reusedUnderlying({ reported: "0x" + "0".repeat(40), wethAddress: undefined })).to.have.property("refusal").match(/not a ConfidentialWETH/));
  it("refuses an unreadable underlying", () =>
    expect(reusedUnderlying({ reported: null, wethAddress: w })).to.have.property("refusal").match(/not a ConfidentialWETH/));
});

describe("sentLine", () => {
  it("names the contract, its address and the transaction before the wait", () =>
    expect(sentLine("EndowmentNFT", "0x" + "1".repeat(40), "0x" + "a".repeat(64)))
      .to.equal(`EndowmentNFT: 0x${"1".repeat(40)} (tx 0x${"a".repeat(64)}, waiting…)`));
});

describe("autoToken", () => {
  const wrapped: Deployment = { label: "wrapped", nft: "0x" + "1".repeat(40), token: "0x" + "2".repeat(40),
    tokenKind: "wrapped", underlying: "0x" + "3".repeat(40), deployBlock: 5 };
  const mock: Deployment = { ...wrapped, label: "mock", token: "0x" + "4".repeat(40), tokenKind: "mock", underlying: null };
  it("shares the token of the wrapped entry", () =>
    expect(autoToken({ tokenKind: undefined, tokenAddress: undefined, contracts: [mock, wrapped] }))
      .to.deep.equal({ token: wrapped.token }));
  it("lets TOKEN_ADDRESS win over the wrapped entry", () => {
    const t = "0x" + "9".repeat(40);
    expect(autoToken({ tokenKind: "wrapped", tokenAddress: t, contracts: [wrapped] })).to.deep.equal({ token: t });
  });
  it("refuses a token kind other than wrapped", () =>
    expect(autoToken({ tokenKind: "mock", tokenAddress: undefined, contracts: [wrapped] }))
      .to.deep.equal({ refusal: "NFT_KIND=auto needs the wrapped token" }));
  it("refuses a token kind other than wrapped even with TOKEN_ADDRESS", () =>
    expect(autoToken({ tokenKind: "plain", tokenAddress: "0x" + "9".repeat(40), contracts: [] }))
      .to.have.property("refusal"));
  it("refuses when there is no wrapped entry", () =>
    expect(autoToken({ tokenKind: undefined, tokenAddress: undefined, contracts: [mock] }))
      .to.deep.equal({ refusal: 'No "wrapped" entry to share a token with. Deploy it first, or set TOKEN_ADDRESS.' }));
});
