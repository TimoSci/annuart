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
    const mintRcpt = await (
      await nft.mint(deployer.address, enc.handles[0], enc.inputProof, segments, 0, false)
    ).wait();
    const scheduleStart = BigInt((await ethers.provider.getBlock(mintRcpt!.blockNumber))!.timestamp);
    const tokenId = 1n;

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
});
