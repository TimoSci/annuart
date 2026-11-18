// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FhevmTest} from "forge-fhevm/FhevmTest.sol";
import {FheType} from "@fhevm/host-contracts/contracts/shared/FheType.sol";
import {InputVerifier} from "@fhevm/host-contracts/contracts/InputVerifier.sol";
import {euint64, euint128, externalEuint64} from "@fhevm/solidity/lib/FHE.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC7984} from "@openzeppelin/confidential-contracts/interfaces/IERC7984.sol";
import {MockConfidentialToken} from "../../src/mocks/MockConfidentialToken.sol";
import {EndowmentNFT} from "../../src/EndowmentNFT.sol";
import {PrivateRateEndowmentNFT} from "../../src/PrivateRateEndowmentNFT.sol";
import {Segment, INDEFINITE} from "../../src/libraries/Schedule.sol";
import {hcuLimitAdd} from "forge-fhevm/fhevm-host/addresses/FHEVMHostAddresses.sol";

interface IBlockMeter {
    function getBlockMeter() external view returns (uint48 blockNumber, uint48 usedHCU);
}

/// @dev Inside the safe-mint callback: tries the guarded entry points, then passes the
///      token on to `heir`.
contract HostileReceiver is IERC721Receiver {
    address internal immutable heir;
    bytes4 public claimError;
    bytes4 public mintError;
    bytes4 public plainMintError;

    constructor(address heir_) {
        heir = heir_;
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        PrivateRateEndowmentNFT nft = PrivateRateEndowmentNFT(msg.sender);
        Segment[] memory s = new Segment[](1);
        s[0] = Segment({duration: 10, ratePerSec: 1});
        try nft.claim(tokenId) {} catch (bytes memory e) { claimError = bytes4(e); }
        try nft.mintPrivate(
            address(this), externalEuint64.wrap(bytes32(uint256(1))), externalEuint64.wrap(bytes32(uint256(2))),
            hex"01", s, 0, false, bytes32(0)
        ) {} catch (bytes memory e) { mintError = bytes4(e); }
        try nft.mint(address(this), externalEuint64.wrap(bytes32(uint256(1))), hex"01", s, 0, false, bytes32(0)) {}
        catch (bytes memory e) { plainMintError = bytes4(e); }
        nft.transferFrom(address(this), heir, tokenId);
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @dev Red team suite for PrivateRateEndowmentNFT. P1: inputs. P2: the mint callback.
///      P3: who is granted the unit. P4: payout arithmetic under an adversarial cadence.
///      P5: one input used twice. P6: the zero unit.
contract PrivateRateRedTeam is FhevmTest {
    MockConfidentialToken internal token;
    PrivateRateEndowmentNFT internal nft;
    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal mallory = makeAddr("mallory");
    address internal donor = makeAddr("donor");

    uint64 internal constant ONE = uint64(1) << 32;
    uint64 internal constant T0 = 1_700_000_000;

    function setUp() public override {
        super.setUp();
        vm.warp(T0);
        token = new MockConfidentialToken();
        nft = new PrivateRateEndowmentNFT(IERC7984(address(token)));
    }

    function _fund(address who, uint64 amount) internal {
        token.mint(who, amount);
        vm.prank(who);
        token.setOperator(address(nft), uint48(block.timestamp + 365 days));
    }

    function _pair(address sender, uint64 amount, uint64 unit) internal returns (bytes32[] memory h, bytes memory p) {
        uint256[] memory vals = new uint256[](2);
        vals[0] = amount;
        vals[1] = unit;
        FheType[] memory types = new FheType[](2);
        types[0] = FheType.Uint64;
        types[1] = FheType.Uint64;
        (h, p) = encrypt(vals, types, sender, address(nft));
    }

    function _mintWith(address sender, address to, bytes32 hAmount, bytes32 hUnit, bytes memory p, Segment[] memory s, bool topUps)
        internal
        returns (uint256)
    {
        vm.prank(sender);
        return nft.mintPrivate(to, externalEuint64.wrap(hAmount), externalEuint64.wrap(hUnit), p, s, 0, topUps, bytes32(0));
    }

    function _mint(address sender, address to, uint64 amount, uint64 unit, Segment[] memory s, bool topUps)
        internal
        returns (uint256)
    {
        _fund(sender, amount);
        (bytes32[] memory h, bytes memory p) = _pair(sender, amount, unit);
        return _mintWith(sender, to, h[0], h[1], p, s, topUps);
    }

    function _one(uint64 duration, uint64 weight) internal pure returns (Segment[] memory s) {
        s = new Segment[](1);
        s[0] = Segment({duration: duration, ratePerSec: weight});
    }

    function _bal(address who) internal returns (uint64) {
        return decrypt(token.confidentialBalanceOf(who));
    }

    function _dist(uint256 id) internal returns (uint64) {
        return decrypt(nft.distributionHandle(id));
    }

    function _remaining(uint256 id) internal returns (uint64) {
        return decrypt(nft.endowmentHandle(id));
    }

    function _reads(bytes32 h, address who) internal view returns (bool) {
        return _acl.persistAllowed(h, who);
    }

    function _unit(uint256 id) internal view returns (bytes32) {
        return euint128.unwrap(nft.unitHandle(id));
    }

    // ---- P1: inputs ----

    /// @dev Another sender cannot use a creator's encrypted pair, before or after the creator does.
    function test_P1_replayByAnotherSender_reverts() public {
        _fund(creator, 1_000);
        _fund(mallory, 1_000);
        (bytes32[] memory h, bytes memory p) = _pair(creator, 1_000, ONE);

        vm.expectPartialRevert(InputVerifier.InvalidSigner.selector);
        _mintWith(mallory, mallory, h[0], h[1], p, _one(1_000, 1), false);

        _mintWith(creator, alice, h[0], h[1], p, _one(1_000, 1), false);

        vm.expectPartialRevert(InputVerifier.InvalidSigner.selector);
        _mintWith(mallory, mallory, h[0], h[1], p, _one(1_000, 1), false);
        vm.expectRevert(EndowmentNFT.EmptyInputProof.selector);
        _mintWith(mallory, mallory, h[0], h[1], "", _one(1_000, 1), false);

        assertEq(_bal(mallory), 1_000, "attacker balance moved");
    }

    /// @dev A valid proof of one's own does not carry someone else's handle: neither a victim's
    ///      raw unit input, nor a stored unit the caller is even allowed to read.
    function test_P1_foreignHandleUnderOwnProof_reverts() public {
        _fund(creator, 1_000);
        (bytes32[] memory hv, bytes memory pv) = _pair(creator, 1_000, ONE);
        uint256 id = _mintWith(creator, mallory, hv[0], hv[1], pv, _one(1_000, 1), false);
        bytes32 stored = _unit(id);
        assertTrue(_reads(stored, mallory), "mallory owns token 1 and reads its unit");

        _fund(mallory, 1_000);
        (bytes32[] memory hm, bytes memory pm) = _pair(mallory, 1_000, 5);

        vm.expectRevert(); // the victim's raw unit input
        _mintWith(mallory, mallory, hm[0], hv[1], pm, _one(1_000, 1), false);
        vm.expectRevert(); // a stored unit mallory may read
        _mintWith(mallory, mallory, hm[0], stored, pm, _one(1_000, 1), false);
        vm.expectRevert(); // the victim's raw endowment input
        _mintWith(mallory, mallory, hv[0], hm[1], pm, _one(1_000, 1), false);

        assertEq(_bal(mallory), 1_000, "attacker balance moved");
    }

    // ---- P2: the mint callback ----

    /// @dev A receiver cannot reach claim or either mint from the callback. It can pass the
    ///      token on; the heir is then paid in full and both have been granted the unit.
    function test_P2_callbackCannotReenter_andHandoffIsSound() public {
        HostileReceiver receiver = new HostileReceiver(bob);
        _fund(creator, 1_000);
        (bytes32[] memory h, bytes memory p) = _pair(creator, 1_000, ONE);
        vm.prank(creator);
        uint256 id = nft.mintPrivate(
            address(receiver), externalEuint64.wrap(h[0]), externalEuint64.wrap(h[1]), p, _one(INDEFINITE, 1),
            T0 - 100, false, bytes32(0)
        );

        assertEq(receiver.claimError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(receiver.mintError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(receiver.plainMintError(), PrivateRateEndowmentNFT.RateRequired.selector);

        assertEq(nft.ownerOf(id), bob);
        assertEq(_dist(id), 100, "back pay accrued at the handoff");
        assertTrue(_reads(euint64.unwrap(nft.distributionHandle(id)), bob));
        assertFalse(_reads(euint64.unwrap(nft.distributionHandle(id)), address(receiver)));
        assertTrue(_reads(_unit(id), bob));
        assertTrue(_reads(_unit(id), address(receiver)), "a past owner keeps the unit (by design)");

        vm.warp(T0 + 50);
        vm.prank(bob);
        nft.claim(id);
        assertEq(_bal(bob), 150);
        assertEq(_remaining(id), 850);
        assertEq(_bal(address(receiver)), 0);
    }

    // ---- P3: who is granted the unit ----

    /// @dev Approval alone grants nothing. An approved account that takes the token becomes an
    ///      owner and is granted the unit for good.
    function test_P3_approvalAloneDoesNotGrantTheUnit() public {
        uint256 id = _mint(creator, alice, 1_000, ONE, _one(1_000, 1), false);
        vm.startPrank(alice);
        nft.approve(mallory, id);
        nft.setApprovalForAll(bob, true);
        vm.stopPrank();
        assertFalse(_reads(_unit(id), mallory), "approved account");
        assertFalse(_reads(_unit(id), bob), "operator");
        assertFalse(_reads(_unit(id), address(token)), "the token contract");

        vm.prank(mallory);
        nft.transferFrom(alice, mallory, id);
        assertTrue(_reads(_unit(id), mallory));
        vm.prank(mallory);
        nft.transferFrom(mallory, alice, id);
        assertTrue(_reads(_unit(id), mallory), "still readable after giving the token back (by design)");
    }

    // ---- P4: payout arithmetic under an adversarial cadence ----

    /// @dev Whoever calls accrue, and however often, the owner is paid exactly
    ///      floor(unit * weight * elapsed / 2**32), and paid + remaining is the endowment.
    /// forge-config: default.fuzz.runs = 24
    function testFuzz_P4_cadenceCannotChangeWhatIsPaid(uint64 unit, uint32 weight, uint32[5] memory gaps) public {
        unit = uint64(bound(unit, 1, uint64(1) << 44));
        weight = uint32(bound(weight, 1, 100_000));
        uint64 endowment = type(uint64).max / 2;
        uint256 id = _mint(creator, alice, endowment, unit, _one(INDEFINITE, weight), false);

        uint256 elapsed;
        for (uint256 i = 0; i < gaps.length; i++) {
            uint256 gap = bound(gaps[i], 1, 30 days);
            elapsed += gap;
            vm.warp(T0 + elapsed);
            vm.prank(mallory);
            nft.accrue(id);
        }
        uint256 expected = (uint256(unit) * weight * elapsed) >> 32;
        if (expected > endowment) expected = endowment;
        assertEq(_dist(id), expected, "paid");
        assertEq(uint256(_dist(id)) + _remaining(id), endowment, "conservation");
    }

    /// @dev The same with the endowment running out and a donation arriving in between.
    function test_P4_exhaustionAndDonationConserve() public {
        // Eight logical transactions in one test tx trip the mock's per-tx HCU depth cap.
        disableHCUDepthLimit();
        uint256 id = _mint(creator, alice, 100, ONE / 3, _one(INDEFINITE, 7), true);
        uint256 paid;
        uint256 deposited = 100;
        for (uint256 i = 1; i <= 8; i++) {
            vm.warp(T0 + i * 17);
            vm.roll(block.number + 1); // the FHE cost cap per block is shared by every caller
            vm.prank(mallory);
            nft.accrue(id);
            if (i == 3) {
                _fund(donor, 40);
                (externalEuint64 h, bytes memory p) = encryptUint64(40, donor, address(nft));
                vm.prank(donor);
                nft.topUp(id, h, p);
                deposited += 40;
            }
            if (i % 4 == 0) {
                uint64 before = _bal(alice);
                vm.prank(alice);
                nft.claim(id);
                paid += _bal(alice) - before;
            }
            assertEq(paid + _dist(id) + _remaining(id), deposited, "conservation");
        }
        assertEq(_remaining(id), 0, "ran out");
        assertEq(paid + _dist(id), 140);
        assertEq(_bal(address(nft)), 140 - paid, "the contract holds exactly what it owes");
    }

    // ---- P5: one input used twice ----

    /// @dev A creator may use the same encrypted pair for two tokens. Both then store the same
    ///      unit handle, so whoever is granted one token's unit reads the other's.
    function test_P5_sameInputTwice_sharesOneUnitHandle() public {
        _fund(creator, 2_000);
        (bytes32[] memory h, bytes memory p) = _pair(creator, 1_000, ONE);
        uint256 a = _mintWith(creator, alice, h[0], h[1], p, _one(1_000, 1), false);
        uint256 b = _mintWith(creator, bob, h[0], h[1], p, _one(1_000, 1), false);
        assertEq(_unit(a), _unit(b), "one handle for both units");
        assertTrue(_reads(_unit(a), bob), "the owner of token b reads token a's unit");
        assertEq(_remaining(a), 1_000);
        assertEq(_remaining(b), 1_000);
    }

    // ---- P6: the zero unit ----

    /// @dev A zero unit on a schedule with no end locks the endowment, and every later
    ///      donation, for good. Nothing on chain tells a donor.
    function test_P6_zeroUnitIndefinite_locksEndowmentAndDonations() public {
        uint256 id = _mint(creator, alice, 1_000, 0, _one(INDEFINITE, 1_000), true);
        _fund(donor, 500);
        (externalEuint64 h, bytes memory p) = encryptUint64(500, donor, address(nft));
        vm.prank(donor);
        nft.topUp(id, h, p);

        vm.warp(T0 + 100 * 365 days);
        nft.accrue(id);
        assertEq(_dist(id), 0);
        assertEq(_remaining(id), 1_500);
        vm.prank(alice);
        nft.claim(id);
        assertEq(_bal(alice), 0);
        assertEq(_bal(address(nft)), 1_500);
    }

    // ---- P7: FHE cost per call ----

    function _used() internal view returns (uint256 used) {
        (, used) = IBlockMeter(hcuLimitAdd).getBlockMeter();
    }

    /// @dev What each call costs in FHE complexity units, against the mock's limits of
    ///      20,000,000 per transaction and per block. Each call is measured in a block of its own.
    function test_P7_costPerCall() public {
        uint256 cap = 20_000_000;
        _fund(creator, 5_000);
        (bytes32[] memory h, bytes memory p) = _pair(creator, 5_000, ONE);
        vm.roll(block.number + 1);
        uint256 id = _mintWith(creator, alice, h[0], h[1], p, _one(INDEFINITE, 1), true);
        uint256 mintCost = _used();

        vm.warp(T0 + 100);
        vm.roll(block.number + 1);
        nft.accrue(id);
        uint256 accrueCost = _used();

        vm.warp(T0 + 200);
        vm.roll(block.number + 1);
        vm.prank(alice);
        nft.claim(id);
        uint256 claimCost = _used();

        vm.warp(T0 + 300);
        vm.roll(block.number + 1);
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        uint256 transferCost = _used();

        emit log_named_uint("mintPrivate", mintCost);
        emit log_named_uint("accrue", accrueCost);
        emit log_named_uint("claim", claimCost);
        emit log_named_uint("transferFrom", transferCost);
        assertLt(claimCost, cap / 5, "fewer than five claims fit in a transaction");
        assertLt(mintCost, cap / 5);
    }
}
