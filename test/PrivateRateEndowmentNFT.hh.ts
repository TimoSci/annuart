import { expect } from "chai";
import { ethers, fhevm } from "hardhat";
import { FhevmType } from "@fhevm/hardhat-plugin";
import { time } from "@nomicfoundation/hardhat-network-helpers";

// The private-rate ENFT on the in-process FHEVM mock: the unit (the encrypted payout rate) is
// readable by the owner and the creator only, and follows the token to a new owner.
describe("PrivateRateEndowmentNFT (Hardhat + fhevm mock)", function () {
  async function setup() {
    const [creator, alice, bob, eve] = await ethers.getSigners();
    const token = await (await ethers.getContractFactory("MockConfidentialToken")).deploy();
    await token.waitForDeployment();
    const tokenAddr = await token.getAddress();
    const nft = await (await ethers.getContractFactory("PrivateRateEndowmentNFT")).deploy(tokenAddr);
    await nft.waitForDeployment();
    const nftAddr = await nft.getAddress();

    await (await token.mint(creator.address, 500)).wait();
    await (await token.setOperator(nftAddr, (await time.latest()) + 365 * 24 * 3600)).wait();

    const unit = 2n ** 32n; // payout per second = unit * weight / 2^32, so weight 1 pays 1 per second
    const enc = await fhevm.createEncryptedInput(nftAddr, creator.address).add64(500).add64(unit).encrypt();
    await (
      await nft.mintPrivate(
        alice.address,
        enc.handles[0],
        enc.handles[1],
        enc.inputProof,
        [{ duration: 1000, ratePerSec: 1 }],
        0,
        false,
        ethers.ZeroHash,
      )
    ).wait();
    return { creator, alice, bob, eve, nft, nftAddr, unit };
  }

  const decryptUnit = (nft: any, nftAddr: string, signer: any) =>
    nft.unitHandle(1n).then((h: string) => fhevm.userDecryptEuint(FhevmType.euint128, h, nftAddr, signer));

  it("the creator and the owner decrypt the unit; a third party cannot", async function () {
    const { creator, alice, eve, nft, nftAddr, unit } = await setup();
    expect(await decryptUnit(nft, nftAddr, creator)).to.equal(unit);
    expect(await decryptUnit(nft, nftAddr, alice)).to.equal(unit);
    let failed = false;
    try {
      await decryptUnit(nft, nftAddr, eve);
    } catch {
      failed = true;
    }
    expect(failed, "a third signer cannot decrypt the unit").to.equal(true);
  });

  it("accrues at the hidden rate", async function () {
    const { alice, nft, nftAddr } = await setup();
    await time.increase(100);
    await (await nft.accrue(1n)).wait();
    const h = await nft.distributionHandle(1n);
    const dist = await fhevm.userDecryptEuint(FhevmType.euint64, h, nftAddr, alice);
    expect(dist >= 100n && dist <= 105n, `distribution ${dist}`).to.equal(true);
  });

  it("hands the unit to a new owner on transfer", async function () {
    const { alice, bob, nft, nftAddr, unit } = await setup();
    await (await nft.connect(alice).transferFrom(alice.address, bob.address, 1n)).wait();
    expect(await decryptUnit(nft, nftAddr, bob)).to.equal(unit);
  });
});
