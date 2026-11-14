import { expect } from "chai";
import { ethers, fhevm } from "hardhat";
import { FhevmType } from "@fhevm/hardhat-plugin";
import { time } from "@nomicfoundation/hardhat-network-helpers";

// Task 5 (Confidentiality), C3-1, through the Hardhat FHEVM plugin's real user-/public-
// decryption path (the same the relayer SDK drives off-chain). It confirms the access table:
//   - the current owner CAN user-decrypt `distribution`;
//   - the creator, a previous owner and an outsider are REFUSED `distribution`;
//   - nobody (owner included) can user-decrypt `endowmentRemaining`;
//   - the only publicly decryptable handle is a payout's unwrap amount; `distribution` and
//     `endowmentRemaining` are refused public decryption.
//
// The handle-derivation vector (C3-4) is analysed in task-5-report.md, not exercised here.

const min = (a: bigint, b: bigint) => (a < b ? a : b);

/// Asserts a promise rejects with a message containing `needle` (the plugin throws, it does
/// not return an EVM revert, so hardhat-chai-matchers' revertedWith does not apply here).
async function expectRefused(p: Promise<unknown>, needle: string) {
  let threw = false;
  try {
    await p;
  } catch (e: unknown) {
    threw = true;
    expect(String((e as { message?: string })?.message ?? e)).to.contain(needle);
  }
  expect(threw, `expected a refusal containing "${needle}"`).to.equal(true);
}

describe("Confidentiality: access table (Hardhat + fhevm mock)", function () {
  it("C3-1: only the current owner user-decrypts distribution; nobody reads the endowment", async function () {
    const [creator, owner, newOwner, outsider] = await ethers.getSigners();

    const token = await (await ethers.getContractFactory("MockConfidentialToken")).deploy();
    await token.waitForDeployment();
    const tokenAddr = await token.getAddress();
    const nft = await (await ethers.getContractFactory("EndowmentNFT")).deploy(tokenAddr);
    await nft.waitForDeployment();
    const nftAddr = await nft.getAddress();

    // Creator funds and mints a 500-unit endowment to `owner`.
    const endowment = 500n;
    const rate = 1n;
    await (await token.connect(creator).mint(creator.address, Number(endowment))).wait();
    await (await token.connect(creator).setOperator(nftAddr, (await time.latest()) + 365 * 24 * 3600)).wait();
    const enc = await fhevm.createEncryptedInput(nftAddr, creator.address).add64(Number(endowment)).encrypt();
    const segments = [{ duration: 1000, ratePerSec: Number(rate) }];
    const mintRcpt = await (
      await nft.connect(creator).mint(owner.address, enc.handles[0], enc.inputProof, segments, 0, false, ethers.ZeroHash)
    ).wait();
    const scheduleStart = BigInt((await ethers.provider.getBlock(mintRcpt!.blockNumber))!.timestamp);
    const tokenId = 1n;

    // Accrue, then exercise the ACL.
    await time.increase(100);
    const accrueRcpt = await (await nft.accrue(tokenId)).wait();
    const accrueTs = BigInt((await ethers.provider.getBlock(accrueRcpt!.blockNumber))!.timestamp);
    const expectedDist = min(rate * (accrueTs - scheduleStart), endowment);

    const distHandle = await nft.distributionHandle(tokenId);
    const endowHandle = await nft.endowmentHandle(tokenId);

    // Owner CAN decrypt the distribution, and it matches the schedule.
    const dist = await fhevm.userDecryptEuint(FhevmType.euint64, distHandle, nftAddr, owner);
    expect(dist).to.equal(expectedDist);
    expect(dist).to.be.greaterThan(0n);

    // Creator and outsider are REFUSED the distribution.
    await expectRefused(
      fhevm.userDecryptEuint(FhevmType.euint64, distHandle, nftAddr, creator),
      "not authorized",
    );
    await expectRefused(
      fhevm.userDecryptEuint(FhevmType.euint64, distHandle, nftAddr, outsider),
      "not authorized",
    );

    // NOBODY (owner included) may decrypt the remaining endowment.
    for (const signer of [owner, creator, outsider]) {
      await expectRefused(
        fhevm.userDecryptEuint(FhevmType.euint64, endowHandle, nftAddr, signer),
        "not authorized",
      );
    }

    // Transfer owner -> newOwner. The distribution handle is refreshed and re-granted.
    await (await nft.connect(owner).transferFrom(owner.address, newOwner.address, tokenId)).wait();
    const distHandle2 = await nft.distributionHandle(tokenId);
    expect(distHandle2, "distribution handle refreshed on transfer").to.not.equal(distHandle);

    // The NEW owner can decrypt the current distribution.
    const dist2 = await fhevm.userDecryptEuint(FhevmType.euint64, distHandle2, nftAddr, newOwner);
    expect(dist2).to.be.greaterThanOrEqual(0n);

    // The PREVIOUS owner is now refused the current distribution (ACL refreshed away from her),
    // as are the creator and an outsider.
    for (const signer of [owner, creator, outsider]) {
      await expectRefused(
        fhevm.userDecryptEuint(FhevmType.euint64, distHandle2, nftAddr, signer),
        "not authorized",
      );
    }
    // The endowment stays unreadable to everyone after transfer too.
    await expectRefused(
      fhevm.userDecryptEuint(FhevmType.euint64, endowHandle, nftAddr, newOwner),
      "not authorized",
    );
  });

  it("C3-1: the only publicly decryptable handle is the payout unwrap amount", async function () {
    const [creator, owner, keeper] = await ethers.getSigners();

    const weth = await (await ethers.getContractFactory("MockWETH")).deploy();
    await weth.waitForDeployment();
    const cweth = await (await ethers.getContractFactory("ConfidentialWETH")).deploy(await weth.getAddress());
    await cweth.waitForDeployment();
    const cwethAddr = await cweth.getAddress();
    const nft = await (await ethers.getContractFactory("AutoPayoutEndowmentNFT")).deploy(cwethAddr);
    await nft.waitForDeployment();
    const nftAddr = await nft.getAddress();

    const units = 1000n;
    const rate = await cweth.rate();
    await (await weth.connect(creator).deposit({ value: units * rate })).wait();
    await (await weth.connect(creator).approve(cwethAddr, units * rate)).wait();
    await (await cweth.connect(creator).wrap(creator.address, units * rate)).wait();
    await (await cweth.connect(creator).setOperator(nftAddr, (await time.latest()) + 365 * 24 * 3600)).wait();

    const enc = await fhevm.createEncryptedInput(nftAddr, creator.address).add64(Number(units)).encrypt();
    const segments = [{ duration: 1000, ratePerSec: 1 }];
    await (
      await nft
        .connect(creator)
        .mintAuto(owner.address, enc.handles[0], enc.inputProof, segments, 0, false, ethers.ZeroHash, true, 3600, 0)
    ).wait();
    const tokenId = 1n;

    await time.increase(100);
    const reqRcpt = await (await nft.connect(keeper).requestPayout(tokenId, 0)).wait();
    const requested = reqRcpt!.logs
      .map((l: { topics: ReadonlyArray<string>; data: string }) => {
        try {
          return nft.interface.parseLog(l);
        } catch {
          return null;
        }
      })
      .find((e: { name: string } | null) => e?.name === "PayoutRequested");
    const requestId: string = requested!.args.requestId;

    // The unwrap amount (the request id handle) IS publicly decryptable.
    const decrypted = await fhevm.publicDecrypt([requestId]);
    const clear = BigInt(decrypted.clearValues[requestId as `0x${string}`] as bigint);
    expect(clear).to.be.greaterThan(0n);

    // The distribution and remaining-endowment handles are REFUSED public decryption.
    const distHandle = await nft.distributionHandle(tokenId);
    const endowHandle = await nft.endowmentHandle(tokenId);
    await expectRefused(fhevm.publicDecrypt([distHandle]), "not allowed for public decryption");
    await expectRefused(fhevm.publicDecrypt([endowHandle]), "not allowed for public decryption");
  });
});
