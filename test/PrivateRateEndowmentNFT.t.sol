// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FhevmTest} from "forge-fhevm/FhevmTest.sol";
import {FheType} from "@fhevm/host-contracts/contracts/shared/FheType.sol";
import {externalEuint64} from "@fhevm/solidity/lib/FHE.sol";
import {MockConfidentialToken} from "../src/mocks/MockConfidentialToken.sol";
import {EndowmentNFT} from "../src/EndowmentNFT.sol";
import {PrivateRateEndowmentNFT} from "../src/PrivateRateEndowmentNFT.sol";
import {Segment, INDEFINITE} from "../src/libraries/Schedule.sol";
import {IERC7984} from "@openzeppelin/confidential-contracts/interfaces/IERC7984.sol";

contract PrivateRateEndowmentNFTTest is FhevmTest {
    MockConfidentialToken internal token;
    PrivateRateEndowmentNFT internal nft;
    address internal creator = address(0xC0FFEE);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    /// @dev A unit of one token per unit of weight per second.
    uint64 internal constant ONE = uint64(1) << 32;

    function setUp() public override {
        super.setUp();
        token = new MockConfidentialToken();
        nft = new PrivateRateEndowmentNFT(IERC7984(address(token)));
    }

    function _mintPrivate(address to, uint64 amount, uint64 unit, Segment[] memory segs, uint64 start)
        internal
        returns (uint256 id)
    {
        token.mint(creator, amount);
        vm.prank(creator);
        token.setOperator(address(nft), uint48(block.timestamp + 365 days));
        uint256[] memory vals = new uint256[](2);
        vals[0] = amount;
        vals[1] = unit;
        FheType[] memory types = new FheType[](2);
        types[0] = FheType.Uint64;
        types[1] = FheType.Uint64;
        (bytes32[] memory h, bytes memory proof) = encrypt(vals, types, creator, address(nft));
        vm.prank(creator);
        id = nft.mintPrivate(
            to, externalEuint64.wrap(h[0]), externalEuint64.wrap(h[1]), proof, segs, start, false, bytes32(0)
        );
    }

    function _one(uint64 duration, uint64 weight) internal pure returns (Segment[] memory s) {
        s = new Segment[](1);
        s[0] = Segment({duration: duration, ratePerSec: weight});
    }

    function _two(uint64 d0, uint64 w0, uint64 d1, uint64 w1) internal pure returns (Segment[] memory s) {
        s = new Segment[](2);
        s[0] = Segment({duration: d0, ratePerSec: w0});
        s[1] = Segment({duration: d1, ratePerSec: w1});
    }

    function _now() internal view returns (uint64) {
        return uint64(block.timestamp);
    }

    function _distribution(uint256 id) internal returns (uint64) {
        return decrypt(nft.distributionHandle(id));
    }

    // --- Minting ---

    function test_mintPrivate_storesScheduleAndEmits() public {
        Segment[] memory segs = _two(100, 1, 200, 3);
        uint64 start = _now();
        token.mint(creator, 500);
        vm.prank(creator);
        token.setOperator(address(nft), uint48(block.timestamp + 365 days));
        uint256[] memory vals = new uint256[](2);
        vals[0] = 500;
        vals[1] = ONE;
        FheType[] memory types = new FheType[](2);
        types[0] = FheType.Uint64;
        types[1] = FheType.Uint64;
        (bytes32[] memory h, bytes memory proof) = encrypt(vals, types, creator, address(nft));

        vm.expectEmit(true, true, true, true, address(nft));
        emit EndowmentNFT.EndowmentMinted(1, creator, alice, start, false, bytes32(0));
        vm.prank(creator);
        uint256 id = nft.mintPrivate(
            alice, externalEuint64.wrap(h[0]), externalEuint64.wrap(h[1]), proof, segs, start, false, bytes32(0)
        );

        assertEq(id, 1);
        assertEq(nft.ownerOf(id), alice);
        Segment[] memory stored = nft.scheduleOf(id);
        assertEq(stored.length, 2);
        assertEq(stored[0].duration, 100);
        assertEq(stored[0].ratePerSec, 1);
        assertEq(stored[1].duration, 200);
        assertEq(stored[1].ratePerSec, 3);
        assertEq(decrypt(nft.unitHandle(id)), ONE);
    }

    function test_inheritedMint_reverts() public {
        vm.expectRevert(PrivateRateEndowmentNFT.RateRequired.selector);
        vm.prank(creator);
        nft.mint(alice, externalEuint64.wrap(bytes32(0)), "", _one(100, 1), 0, false, bytes32(0));
        vm.expectRevert(EndowmentNFT.NonexistentToken.selector);
        nft.nameOf(1);
    }

    function test_emptyProof_reverts() public {
        vm.expectRevert(EndowmentNFT.EmptyInputProof.selector);
        vm.prank(creator);
        nft.mintPrivate(
            alice,
            externalEuint64.wrap(bytes32(0)),
            externalEuint64.wrap(bytes32(0)),
            "",
            _one(100, 1),
            0,
            false,
            bytes32(0)
        );
    }

    function test_weightAboveMax_reverts() public {
        token.mint(creator, 10);
        vm.prank(creator);
        token.setOperator(address(nft), uint48(block.timestamp + 365 days));
        uint256[] memory vals = new uint256[](2);
        vals[0] = 10;
        vals[1] = ONE;
        FheType[] memory types = new FheType[](2);
        types[0] = FheType.Uint64;
        types[1] = FheType.Uint64;
        (bytes32[] memory h, bytes memory proof) = encrypt(vals, types, creator, address(nft));
        vm.expectRevert(PrivateRateEndowmentNFT.WeightTooLarge.selector);
        vm.prank(creator);
        nft.mintPrivate(
            alice,
            externalEuint64.wrap(h[0]),
            externalEuint64.wrap(h[1]),
            proof,
            _one(100, uint64(1) << 32),
            0,
            false,
            bytes32(0)
        );

        uint256 id = _mintPrivate(alice, 10, ONE, _one(100, (uint64(1) << 32) - 1), _now());
        assertEq(nft.scheduleOf(id)[0].ratePerSec, nft.MAX_WEIGHT());
    }

    function test_zeroWeightIndefinite_reverts() public {
        token.mint(creator, 10);
        vm.prank(creator);
        token.setOperator(address(nft), uint48(block.timestamp + 365 days));
        uint256[] memory vals = new uint256[](2);
        vals[0] = 10;
        vals[1] = ONE;
        FheType[] memory types = new FheType[](2);
        types[0] = FheType.Uint64;
        types[1] = FheType.Uint64;
        (bytes32[] memory h, bytes memory proof) = encrypt(vals, types, creator, address(nft));
        vm.expectRevert(EndowmentNFT.ZeroRateIndefiniteSegment.selector);
        vm.prank(creator);
        nft.mintPrivate(
            alice,
            externalEuint64.wrap(h[0]),
            externalEuint64.wrap(h[1]),
            proof,
            _one(INDEFINITE, 0),
            0,
            false,
            bytes32(0)
        );
    }

    // --- Accrual ---

    function test_paysUnitTimesWeightedTime() public {
        uint256 id = _mintPrivate(alice, 5_000, ONE, _one(1_000, 1), _now());
        vm.warp(block.timestamp + 400);
        nft.accrue(id);
        assertEq(_distribution(id), 400);
    }

    function test_weightsScaleThePayout() public {
        uint256 id = _mintPrivate(alice, 5_000, ONE, _two(100, 1, 100, 3), _now());
        vm.warp(block.timestamp + 150); // 100 * 1 + 50 * 3
        nft.accrue(id);
        assertEq(_distribution(id), 250);
    }

    function test_fractionalUnit() public {
        // floor(49710269629 * 1000 * 100 / 2**32): about 10**9 tokens a day at weight 1000
        uint256 id = _mintPrivate(alice, 10 ** 9, 49_710_269_629, _one(1_000, 1_000), _now());
        vm.warp(block.timestamp + 100);
        nft.accrue(id);
        assertEq(_distribution(id), 1_157_407);
    }

    function test_cappedByEndowment() public {
        uint256 id = _mintPrivate(alice, 300, ONE, _one(1_000, 1), _now());
        vm.warp(block.timestamp + 400);
        nft.accrue(id);
        assertEq(_distribution(id), 300);
    }

    function test_fixedEndReleasesLeftover() public {
        uint256 id = _mintPrivate(alice, 500, ONE, _one(100, 1), _now());
        vm.warp(block.timestamp + 100);
        nft.accrue(id);
        assertEq(_distribution(id), 500);
        assertTrue(nft.settledOf(id));
    }

    function test_zeroWeightPeriodPaysNothing() public {
        uint256 id = _mintPrivate(alice, 5_000, ONE, _two(100, 0, 100, 1), _now());
        vm.warp(block.timestamp + 100);
        nft.accrue(id);
        assertEq(_distribution(id), 0);
        vm.warp(block.timestamp + 50);
        nft.accrue(id);
        assertEq(_distribution(id), 50);
    }

    function test_zeroUnit_paysNothingUntilEnd() public {
        uint256 id = _mintPrivate(alice, 500, 0, _one(100, 1), _now());
        vm.warp(block.timestamp + 50);
        nft.accrue(id);
        assertEq(_distribution(id), 0);
        vm.warp(block.timestamp + 50);
        nft.accrue(id);
        assertEq(_distribution(id), 500);
    }

    function test_frequentAccrualLosesNothing() public {
        // Eleven logical transactions in one test tx trip the mock's per-tx HCU depth cap.
        disableHCUDepthLimit();
        uint256 id = _mintPrivate(alice, 1_000, ONE / 2, _one(INDEFINITE, 1), _now());
        for (uint256 i = 0; i < 10; i++) {
            vm.warp(block.timestamp + 1);
            vm.prank(bob);
            nft.accrue(id);
        }
        assertEq(_distribution(id), 5);
    }

    function test_halfUnitSingleSecondCarries() public {
        uint256 id = _mintPrivate(alice, 1_000, ONE / 2, _one(INDEFINITE, 1), _now());
        vm.warp(block.timestamp + 1);
        nft.accrue(id);
        assertEq(_distribution(id), 0);
        vm.warp(block.timestamp + 1);
        nft.accrue(id);
        assertEq(_distribution(id), 1);
    }

    function test_claimPaysOwner() public {
        uint256 id = _mintPrivate(alice, 5_000, ONE, _one(1_000, 1), _now());
        vm.warp(block.timestamp + 400);
        nft.accrue(id);
        vm.prank(alice);
        nft.claim(id);
        assertEq(decrypt(token.confidentialBalanceOf(alice)), 400);
    }
}
