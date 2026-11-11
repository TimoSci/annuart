import { expect } from "chai";
import { ethers, fhevm } from "hardhat";
import { FhevmType } from "@fhevm/hardhat-plugin";
import { time } from "@nomicfoundation/hardhat-network-helpers";

const min = (a: bigint, b: bigint) => (a < b ? a : b);

// Smoke test exercising the full interactive stack on the in-process FHEVM mock:
// deploy -> fund -> encrypted mint -> accrue -> user-decrypt distribution -> claim.
describe("EndowmentNFT (Hardhat + fhevm mock)", function () {
  it("mint -> accrue -> claim with user-decryption", async function () {
    const [deployer] = await ethers.getSigners();

    const Token = await ethers.getContractFactory("MockConfidentialToken");
    const token = await Token.deploy();
    await token.waitForDeployment();
    const tokenAddr = await token.getAddress();

    const NFT = await ethers.getContractFactory("EndowmentNFT");
    const nft = await NFT.deploy(tokenAddr);
    await nft.waitForDeployment();
    const nftAddr = await nft.getAddress();

    // Fund the deployer with mock confidential tokens and approve the NFT as operator.
    await (await token.mint(deployer.address, 500)).wait();
    const until = (await time.latest()) + 365 * 24 * 3600;
    await (await token.setOperator(nftAddr, until)).wait();

    // Encrypt a 500-unit endowment bound to (nft, deployer) and mint.
    // scheduleStart defaults to the mint block's timestamp; capture it so the
    // expected accrual is computed from real block times (Hardhat advances the
    // timestamp by 1s on every mined tx, unlike Foundry's exact vm.warp).
    const endowment = 500n;
    const rate = 1n; // unit/sec
    const enc = await fhevm
      .createEncryptedInput(nftAddr, deployer.address)
      .add64(Number(endowment))
      .encrypt();
    const segments = [{ duration: 1000, ratePerSec: Number(rate) }]; // 1 unit/sec for 1000s
    const name = ethers.encodeBytes32String("Rainy day fund");
    const mintRcpt = await (
      await nft.mint(deployer.address, enc.handles[0], enc.inputProof, segments, 0, false, name)
    ).wait();
    const scheduleStart = BigInt((await ethers.provider.getBlock(mintRcpt!.blockNumber))!.timestamp);
    const tokenId = 1n;

    const minted = mintRcpt!.logs
      .map((l: { topics: ReadonlyArray<string>; data: string }) => {
        try {
          return nft.interface.parseLog(l);
        } catch {
          return null;
        }
      })
      .find((e: { name: string } | null) => e?.name === "EndowmentMinted");
    expect(minted, "EndowmentMinted event").to.not.equal(undefined);
    expect(minted!.args.tokenId).to.equal(tokenId);
    expect(minted!.args.creator).to.equal(deployer.address);
    expect(minted!.args.to).to.equal(deployer.address);
    expect(minted!.args.topUpsAllowed).to.equal(false);
    expect(minted!.args.name).to.equal(name);
    expect(ethers.decodeBytes32String(await nft.nameOf(tokenId))).to.equal("Rainy day fund");

    // Advance ~100s, accrue, and confirm the owner can decrypt the scheduled amount
    // (capped by the endowment), computed from the accrual block's timestamp.
    await time.increase(100);
    const accrueRcpt = await (await nft.accrue(tokenId)).wait();
    const accrueTs = BigInt((await ethers.provider.getBlock(accrueRcpt!.blockNumber))!.timestamp);
    const expectedDist = min(rate * (accrueTs - scheduleStart), endowment);
    const distHandle = await nft.distributionHandle(tokenId);
    const dist = await fhevm.userDecryptEuint(FhevmType.euint64, distHandle, nftAddr, deployer);
    expect(dist).to.equal(expectedDist);

    // Claim accrues once more then pays out the whole distribution; the deployer's
    // confidential balance should equal the amount accrued up to the claim block.
    const claimRcpt = await (await nft.claim(tokenId)).wait();
    const claimTs = BigInt((await ethers.provider.getBlock(claimRcpt!.blockNumber))!.timestamp);
    const expectedBal = min(rate * (claimTs - scheduleStart), endowment);
    const balHandle = await token.confidentialBalanceOf(deployer.address);
    const bal = await fhevm.userDecryptEuint(FhevmType.euint64, balHandle, tokenAddr, deployer);
    expect(bal).to.equal(expectedBal);
  });

  it("releases the leftover at schedule end", async function () {
    const [deployer] = await ethers.getSigners();

    const token = await (await ethers.getContractFactory("MockConfidentialToken")).deploy();
    await token.waitForDeployment();
    const tokenAddr = await token.getAddress();
    const nft = await (await ethers.getContractFactory("EndowmentNFT")).deploy(tokenAddr);
    await nft.waitForDeployment();
    const nftAddr = await nft.getAddress();

    await (await token.mint(deployer.address, 2000)).wait();
    await (await token.setOperator(nftAddr, (await time.latest()) + 365 * 24 * 3600)).wait();

    const enc = await fhevm.createEncryptedInput(nftAddr, deployer.address).add64(2000).encrypt();
    const segments = [{ duration: 1000, ratePerSec: 1 }]; // schedules 1000 of the 2000
    await (await nft.mint(deployer.address, enc.handles[0], enc.inputProof, segments, 0, false, ethers.ZeroHash)).wait();

    await time.increase(1001);
    await (await nft.claim(1n)).wait();

    const balHandle = await token.confidentialBalanceOf(deployer.address);
    const bal = await fhevm.userDecryptEuint(FhevmType.euint64, balHandle, tokenAddr, deployer);
    expect(bal).to.equal(2000n);
    expect(await nft.settledOf(1n)).to.equal(true);
  });

  it("names: accepts plain ASCII up to 31 characters, rejects everything else", async function () {
    const [deployer] = await ethers.getSigners();
    const token = await (await ethers.getContractFactory("MockConfidentialToken")).deploy();
    await token.waitForDeployment();
    const tokenAddr = await token.getAddress();
    const nft = await (await ethers.getContractFactory("EndowmentNFT")).deploy(tokenAddr);
    await nft.waitForDeployment();
    const nftAddr = await nft.getAddress();
    await (await token.mint(deployer.address, 1000)).wait();
    await (await token.setOperator(nftAddr, (await time.latest()) + 365 * 24 * 3600)).wait();

    const segments = [{ duration: 1000, ratePerSec: 1 }];
    const mintNamed = async (name: string) => {
      const enc = await fhevm.createEncryptedInput(nftAddr, deployer.address).add64(10).encrypt();
      return nft.mint(deployer.address, enc.handles[0], enc.inputProof, segments, 0, false, name);
    };
    // Raw bytes, zero-padded on the right, for names ethers would refuse to encode.
    const raw = (hex: string) => "0x" + hex.padEnd(64, "0");
    const text = (s: string) => raw(Buffer.from(s, "utf8").toString("hex"));

    const good = ["Ada's fund_no.2 - A", "abcdefghijklmnopqrstuvwxyz01234", "x"];
    for (const [i, name] of good.entries()) {
      await (await mintNamed(text(name))).wait();
      expect(ethers.decodeBytes32String(await nft.nameOf(i + 1))).to.equal(name);
    }
    // Unnamed, and a name another token already has, are both fine.
    await (await mintNamed(ethers.ZeroHash)).wait();
    expect(await nft.nameOf(good.length + 1)).to.equal(ethers.ZeroHash);
    await (await mintNamed(text("x"))).wait();

    const bad = [
      text("abcdefghijklmnopqrstuvwxyz012345"), // 32 characters
      text(" lead"), text("trail "), text(" "),
      text("<b>"), text("a/b"), text("a\nb"), text("café"), text("a\u202eb"),
      raw("610062"), // "a", zero byte, "b"
      raw("0061"), // zero byte, "a"
    ];
    for (const name of bad) {
      await expect(mintNamed(name), name).to.be.revertedWithCustomError(nft, "InvalidName");
    }
    await expect(nft.nameOf(99)).to.be.revertedWithCustomError(nft, "NonexistentToken");
  });
});
