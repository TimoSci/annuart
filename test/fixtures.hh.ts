import { expect } from "chai";
import hre, { ethers, fhevm } from "hardhat";
import { FhevmType } from "@fhevm/hardhat-plugin";
import { createFixtures, FIXTURES, INDEFINITE, type FixtureContract } from "../tasks/fixtures";

// The fixture set, minted on the in-process chain against freshly deployed contracts.
describe("fixtures (Hardhat + fhevm mock)", function () {
  this.timeout(600_000);

  async function deployAll(): Promise<FixtureContract[]> {
    const deploy = async (name: string, ...args: unknown[]) => {
      const c = await (await ethers.getContractFactory(name)).deploy(...args);
      await c.waitForDeployment();
      return await c.getAddress();
    };
    const mock = await deploy("MockConfidentialToken");
    const cweth = await deploy("ConfidentialWETH", await deploy("MockWETH"));
    const privateToken = await deploy("MockConfidentialToken");
    return [
      { label: "mock", nft: await deploy("EndowmentNFT", mock), token: mock, tokenKind: "mock" },
      { label: "wrapped", nft: await deploy("EndowmentNFT", cweth), token: cweth, tokenKind: "wrapped" },
      { label: "auto", nft: await deploy("AutoPayoutEndowmentNFT", cweth), token: cweth, tokenKind: "wrapped", nftKind: "auto" },
      { label: "private-mock", nft: await deploy("PrivateRateEndowmentNFT", privateToken), token: privateToken, tokenKind: "mock", nftKind: "private" },
    ];
  }

  it("mints every fixture once, with the options it names, and nothing on a second run", async function () {
    const contracts = await deployAll();
    const signers = await ethers.getSigners();
    const results = await createFixtures(hre, contracts);

    expect(results).to.have.length(FIXTURES.length);
    expect(results.every((r) => r.status === "created")).to.equal(true);
    const of = (label: string, name: string) => results.find((r) => r.label === label && r.name === name)!;
    const at = (label: string, contract = "EndowmentNFT") =>
      ethers.getContractAt(contract, contracts.find((c) => c.label === label)!.nft);

    // The set spans all four variants, at least four creators, both top-up settings,
    // named and unnamed tokens, and fixed, indefinite, paused, past and future schedules.
    expect(new Set(FIXTURES.map((f) => f.variant)).size).to.equal(4);
    expect(new Set(FIXTURES.map((f) => f.creator)).size).to.be.greaterThanOrEqual(4);
    expect(new Set(FIXTURES.map((f) => f.topUps)).size).to.equal(2);
    expect(FIXTURES.some((f) => f.name === "")).to.equal(true);
    expect(FIXTURES.some((f) => f.creator !== f.owner)).to.equal(true);
    expect(FIXTURES.some((f) => f.segments.some((s) => s.ratePerSec === 0n))).to.equal(true);
    expect(FIXTURES.some((f) => f.startOffset > 0) && FIXTURES.some((f) => f.startOffset < 0)).to.equal(true);
    expect(FIXTURES.some((f) => f.segments.at(-1)!.duration === INDEFINITE)).to.equal(true);
    expect(FIXTURES.some((f) => f.segments.at(-1)!.duration !== INDEFINITE)).to.equal(true);

    const mock = await at("mock");
    // A gift: minted by one account to another, with top-ups on and three segments.
    const gift = of("mock", "Front-loaded gift");
    expect(await mock.ownerOf(gift.tokenId!)).to.equal(signers[1].address);
    expect(await mock.topUpsAllowedOf(gift.tokenId!)).to.equal(true);
    expect(await mock.scheduleOf(gift.tokenId!)).to.have.length(3);
    // Names are stored; the unnamed one has none.
    expect(ethers.decodeBytes32String(await mock.nameOf(gift.tokenId!))).to.equal("Front-loaded gift");
    expect(await mock.nameOf(of("mock", "").tokenId!)).to.equal(ethers.ZeroHash);
    // Past its end and accrued: settled. Still running: not.
    expect(await mock.settledOf(of("mock", "Ended").tokenId!)).to.equal(true);
    expect(await mock.settledOf(of("mock", "Half way").tokenId!)).to.equal(false);
    // A schedule that starts later, and one with no end.
    const now = (await ethers.provider.getBlock("latest"))!.timestamp;
    expect(await mock.scheduleStartOf(of("mock", "Starts next week").tokenId!)).to.be.greaterThan(now);
    expect(await mock.scheduleEndOf(of("mock", "Perpetual trickle").tokenId!)).to.equal(INDEFINITE);
    // Transferred after the mint.
    const moved = of("mock", "Changed hands");
    expect(await mock.ownerOf(moved.tokenId!)).to.equal(signers[1].address);
    expect(moved.owner).to.equal(signers[1].address);
    // Claimed: the owner's distribution is back to zero, and the endowment ran dry on another.
    const half = of("mock", "Half way");
    expect(
      await fhevm.userDecryptEuint(FhevmType.euint64, await mock.distributionHandle(half.tokenId!), await mock.getAddress(), signers[3]),
    ).to.equal(0n);
    const dry = of("mock", "Run dry");
    expect(
      await fhevm.userDecryptEuint(FhevmType.euint64, await mock.distributionHandle(dry.tokenId!), await mock.getAddress(), signers[0]),
    ).to.equal(10_000_000n);

    // Automatic payout settings as given.
    const auto = await at("auto", "AutoPayoutEndowmentNFT");
    const daily = await auto.autoPayoutOf(of("auto", "Daily payout").tokenId!);
    expect([daily[0], daily[1], daily[2]]).to.deep.equal([true, 86_400n, 10n ** 14n]);
    expect((await auto.autoPayoutOf(of("auto", "Auto off").tokenId!))[0]).to.equal(false);
    expect(await auto.payoutDue(of("auto", "Weekly no fee").tokenId!)).to.equal(true);

    // The private rate is the one given, readable by its creator.
    const priv = await at("private-mock", "PrivateRateEndowmentNFT");
    const stipend = of("private-mock", "Private stipend");
    expect(
      await fhevm.userDecryptEuint(FhevmType.euint128, await priv.unitHandle(stipend.tokenId!), await priv.getAddress(), signers[0]),
    ).to.equal((1_000_000n << 32n) / 86_400_000n);

    // A second run finds them all and mints nothing.
    const again = await createFixtures(hre, contracts);
    expect(again.every((r) => r.status === "exists")).to.equal(true);
    expect(again.map((r) => r.tokenId)).to.deep.equal(results.map((r) => r.tokenId));
  });

  it("skips a variant that is not deployed", async function () {
    const [mock] = await deployAll();
    const results = await createFixtures(hre, [mock]);
    expect(results.filter((r) => r.status === "created").every((r) => r.variant === "mock")).to.equal(true);
    expect(results.filter((r) => r.status === "no contract").map((r) => r.variant)).to.include.members(["wrapped", "auto", "private"]);
    expect(results.filter((r) => r.status === "no contract").every((r) => r.tokenId === null)).to.equal(true);
  });
});
