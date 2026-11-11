import { expect } from "chai";
import { deployRefusal } from "../tasks/deployGuard";

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
});
