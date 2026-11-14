// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FHE, euint64, externalEuint64} from "@fhevm/solidity/lib/FHE.sol";
import {ACL} from "@fhevm/host-contracts/contracts/ACL.sol";
import {ERC7984} from "@openzeppelin/confidential-contracts/token/ERC7984/ERC7984.sol";
import {RedTeamBase} from "./RedTeamBase.sol";
import {EndowmentNFT} from "../../src/EndowmentNFT.sol";
import {AutoPayoutEndowmentNFT} from "../../src/AutoPayoutEndowmentNFT.sol";
import {Segment} from "../../src/libraries/Schedule.sol";

/// @dev Task 5 (Confidentiality) of the red team: who may read each encrypted value.
///
///      These tests are the runnable half of the task (C3-1, C3-2, and the access-control
///      half of C3-5). They assert the confidentiality property HOLDS: the distribution is
///      readable only by the current owner and the contract, the remaining endowment by
///      nobody but the contract, and the only publicly decryptable handle is a payout's
///      unwrap amount. "Readable" means a persistent ACL grant, which is exactly what
///      off-chain user-decryption requires (transient grants live only inside one tx and do
///      not enable decryption), so `_persistAllowed` is the right oracle here.
///
///      The handle-reuse/derivation vector (C3-4) and the "force a hidden amount public
///      THROUGH handle derivation" half of C3-5 are deliberately NOT exercised here. They are
///      analysed in task-5-report.md and marked "needs manual expert confirmation"; no test
///      below reconstructs an internal handle from its operands.
contract ConfidentialityTest is RedTeamBase {
    uint32 internal constant ONE_HOUR = 1 hours;

    address internal operator = makeAddr("operator");
    address internal outsider = makeAddr("outsider");

    // ------------------------------------------------------------------
    // shared assertion: the confidentiality invariant for one token
    // ------------------------------------------------------------------

    /// @dev Asserts the access table for token `id` on `nft`: the CURRENT distribution handle
    ///      is persistently readable by exactly `owner_` and the contract, the endowment
    ///      handle by the contract alone, neither is publicly decryptable, and every address
    ///      in `others` is refused both handles.
    function _assertConfidential(EndowmentNFT nft, uint256 id, address owner_, address[] memory others) internal view {
        euint64 dist = nft.distributionHandle(id);
        euint64 endow = nft.endowmentHandle(id);

        // distribution: current owner + contract, and no one else.
        assertTrue(_persistAllowed(dist, owner_), "owner must read distribution");
        assertTrue(_persistAllowed(dist, address(nft)), "contract must read distribution");

        // endowment: contract only. Never any owner.
        assertTrue(_persistAllowed(endow, address(nft)), "contract must read endowment");
        assertFalse(_persistAllowed(endow, owner_), "owner must NOT read endowment");

        // Neither internal handle is publicly decryptable.
        assertFalse(_publicDecryptable(dist), "distribution must not be public");
        assertFalse(_publicDecryptable(endow), "endowment must not be public");

        for (uint256 i = 0; i < others.length; i++) {
            assertFalse(_persistAllowed(dist, others[i]), "other must NOT read distribution");
            assertFalse(_persistAllowed(endow, others[i]), "other must NOT read endowment");
        }
    }

    /// @dev The standard roster of parties that must never read a token alice owns.
    function _others(address a, address b, address c, address d) internal pure returns (address[] memory r) {
        r = new address[](4);
        r[0] = a;
        r[1] = b;
        r[2] = c;
        r[3] = d;
    }

    // ==================================================================
    // C3-1  Access table holds (EndowmentNFT / mock token)
    // ==================================================================

    function test_C3_1_afterMint_distributionOwnerOnly_endowmentNobody() public {
        uint256 id = _mintSimple(alice, 500, true); // owner = alice, creator = creator

        // An approved ERC-721 operator gets transfer rights but no FHE ACL.
        vm.prank(alice);
        enft.setApprovalForAll(operator, true);

        _assertConfidential(enft, id, alice, _others(creator, operator, donor, outsider));
    }

    function test_C3_1_afterTopUp_donorCannotReadEndowment() public {
        uint256 id = _mintSimple(alice, 500, true);

        // A third-party donation: the endowmentRemaining handle is replaced by a fresh
        // add(old, received); the donor is never granted on it.
        _fundMock(donor, 300);
        _authorise(donor, enft);
        _topUp(enft, donor, id, 300);

        _assertConfidential(enft, id, alice, _others(creator, donor, bob, outsider));
    }

    function test_C3_1_afterAccrue_callerGainsNothing() public {
        uint256 id = _mintSimple(alice, 500, false);
        vm.warp(block.timestamp + 100);

        // Anyone may accrue; the caller gets no read access to anything.
        vm.prank(outsider);
        enft.accrue(id);

        _assertConfidential(enft, id, alice, _others(creator, operator, donor, outsider));
    }

    function test_C3_1_afterClaim_distributionResetOwnerOnly() public {
        uint256 id = _mintSimple(alice, 500, false);
        vm.warp(block.timestamp + 100);

        vm.prank(alice);
        enft.claim(id);

        _assertConfidential(enft, id, alice, _others(creator, operator, donor, outsider));
    }

    function test_C3_1_afterTransfer_previousOwnerLosesCurrentDistribution() public {
        uint256 id = _mintSimple(alice, 500, false);
        vm.warp(block.timestamp + 100);
        vm.prank(alice);
        enft.accrue(id);

        // The handle alice can read WHILE she owns the token.
        euint64 oldDist = enft.distributionHandle(id);
        assertTrue(_persistAllowed(oldDist, alice), "owner reads current distribution");

        // Transfer alice -> bob. _update accrues then refreshes the distribution handle.
        vm.prank(alice);
        enft.safeTransferFrom(alice, bob, id);

        euint64 newDist = enft.distributionHandle(id);
        // The refreshed handle is a different ciphertext, granted to bob only.
        assertTrue(euint64.unwrap(oldDist) != euint64.unwrap(newDist), "distribution refreshed on transfer");
        // ACL is never revoked: alice keeps the OLD handle (a pre-transfer value she already
        // knew) but CANNOT read the new owner's current distribution.
        assertTrue(_persistAllowed(oldDist, alice), "previous owner keeps stale handle (known value)");
        assertFalse(_persistAllowed(newDist, alice), "previous owner must NOT read current distribution");

        // Full invariant with bob as the new owner and alice among the outsiders.
        _assertConfidential(enft, id, bob, _others(alice, creator, operator, outsider));
    }

    function test_C3_1_afterSettle_endowmentDrainedStillSecret() public {
        // 500 units streamed over 1000 s, then the schedule ends and the leftover is swept.
        uint256 id = _mintSimple(alice, 500, false);
        vm.warp(block.timestamp + 1000);
        vm.prank(outsider);
        enft.accrue(id);

        assertTrue(enft.settledOf(id), "schedule settled");
        // The whole 500 is now in the distribution; the endowment handle holds a computed 0,
        // still readable by nobody but the contract.
        assertEq(_dist(enft, id), 500, "distribution holds the whole endowment");
        assertEq(_endow(enft, id), 0, "endowment drained to zero");

        _assertConfidential(enft, id, alice, _others(creator, operator, donor, outsider));
    }

    // ==================================================================
    // C3-1  Access table holds (AutoPayoutEndowmentNFT / cWETH)
    // ==================================================================

    function test_C3_1_afterRequestPayout_onlyUnwrapAmountPublic() public {
        uint256 id = _mintAutoSimple(alice, 1000, true, ONE_HOUR, 0); // owner alice
        vm.warp(block.timestamp + 100);

        // The requester is the keeper; it never owned the token.
        bytes32 rid = _requestPayout(id, keeper);

        // The unwrap amount (the request id handle) is the ONE publicly decryptable handle.
        assertTrue(_publicDecryptable(rid), "unwrap amount is public");

        // Distribution (reset to 0) and endowment stay confidential; the requester gained
        // no persistent access to either.
        _assertConfidential(apnft, id, alice, _others(creator, keeper, operator, outsider));
    }

    function test_C3_1_afterFinalizePayout_finaliserGainsNothing() public {
        uint256 id = _mintAutoSimple(alice, 1000, true, ONE_HOUR, 0);
        vm.warp(block.timestamp + 100);

        bytes32 rid = _requestPayout(id, keeper); // requester = keeper
        _finalizePayout(id, mallory); // finaliser = mallory

        // ACL is never revoked: the unwrap amount stays public after finalisation.
        assertTrue(_publicDecryptable(rid), "unwrap amount stays public");
        // Neither the requester nor the finaliser gained access to the hidden handles.
        _assertConfidential(apnft, id, alice, _others(creator, keeper, mallory, outsider));
    }

    // ==================================================================
    // C3-2  Oracles on the remaining endowment
    // ==================================================================

    /// @dev The one public oracle a running auto-payout exposes is the unwrap amount. It
    ///      equals the amount CLAIMED (the accrued distribution at request time), never the
    ///      remaining endowment. Matches automatic-payout spec section 3: "every automatic
    ///      payout amount is public ... the remaining endowment stays hidden."
    function test_C3_2_publicPayoutRevealsClaimedNotRemaining() public {
        uint256 id = _mintAutoSimple(alice, 1000, true, ONE_HOUR, 0);
        vm.warp(block.timestamp + 100); // 100 units accrue, 900 remain

        bytes32 rid = _requestPayout(id, keeper);

        // Test oracle (ignores ACL) to inspect both values.
        uint64 publicAmount = uint64(decrypt(rid));
        uint64 remaining = _endow(apnft, id);

        assertEq(publicAmount, 100, "public amount is the claimed/accrued amount");
        assertEq(remaining, 900, "remaining endowment is a different, larger value");
        assertTrue(publicAmount != remaining, "public amount does not reveal the remaining endowment");
        // And the remaining-endowment handle itself is not publicly decryptable.
        assertFalse(_publicDecryptable(apnft.endowmentHandle(id)), "remaining endowment not public");
    }

    /// @dev Across the whole lifecycle, with a third-party donation mixed in, NO role ever
    ///      gains a persistent (user-decryptable) grant on the remaining-endowment handle.
    ///      This is the C3-2 enumeration reduced to its invariant: the remaining is an oracle
    ///      for no one but the contract, at every stage.
    function test_C3_2_noRoleDecryptsRemainingAcrossLifecycle() public {
        address[6] memory roster = [creator, donor, alice, bob, operator, outsider];

        uint256 id = _mintSimple(alice, 500, true); // creator funds 500 to alice
        _assertNobodyReadsEndowment(enft, id, roster);

        // third-party top-up: remaining becomes 800, hidden even from the creator.
        _fundMock(donor, 300);
        _authorise(donor, enft);
        _topUp(enft, donor, id, 300);
        _assertNobodyReadsEndowment(enft, id, roster);

        vm.warp(block.timestamp + 100);
        vm.prank(outsider);
        enft.accrue(id);
        _assertNobodyReadsEndowment(enft, id, roster);

        vm.prank(alice);
        enft.safeTransferFrom(alice, bob, id);
        _assertNobodyReadsEndowment(enft, id, roster);

        vm.warp(block.timestamp + 1000);
        vm.prank(outsider);
        enft.accrue(id);
        assertTrue(enft.settledOf(id), "settled");
        _assertNobodyReadsEndowment(enft, id, roster);
    }

    function _assertNobodyReadsEndowment(EndowmentNFT nft, uint256 id, address[6] memory roster) internal view {
        euint64 endow = nft.endowmentHandle(id);
        assertTrue(_persistAllowed(endow, address(nft)), "contract reads endowment");
        for (uint256 i = 0; i < roster.length; i++) {
            assertFalse(_persistAllowed(endow, roster[i]), "no role reads the remaining endowment");
        }
        assertFalse(_publicDecryptable(endow), "endowment never public");
    }

    // ==================================================================
    // C3-5  Forced disclosure (access-control half)
    // ==================================================================

    function test_C3_5_requestPayoutWithPayoutsOff_reverts() public {
        // Minted with auto payouts OFF.
        uint256 id = _mintAutoSimple(alice, 1000, false, ONE_HOUR, 0);
        vm.warp(block.timestamp + 100);

        vm.prank(keeper);
        vm.expectRevert(AutoPayoutEndowmentNFT.AutoPayoutDisabled.selector);
        apnft.requestPayout(id, 0);

        // Nothing was staged, so no unwrap handle was created or made public.
        (bytes32 rid,,,) = apnft.pendingPayoutOf(id);
        assertEq(rid, bytes32(0), "no pending payout, nothing disclosed");

        // Same when the owner first enabled then disabled it.
        uint256 id2 = _mintAutoSimple(alice, 1000, true, ONE_HOUR, 0);
        vm.prank(alice);
        apnft.setAutoPayout(id2, false, ONE_HOUR, 0);
        vm.warp(block.timestamp + 100);
        vm.prank(keeper);
        vm.expectRevert(AutoPayoutEndowmentNFT.AutoPayoutDisabled.selector);
        apnft.requestPayout(id2, 0);
    }

    function test_C3_5_setAutoPayoutByNonOwner_reverts() public {
        uint256 id = _mintAutoSimple(alice, 1000, true, ONE_HOUR, 0);

        // An approved ERC-721 operator cannot change the settings.
        vm.prank(alice);
        apnft.setApprovalForAll(operator, true);
        vm.prank(operator);
        vm.expectRevert(EndowmentNFT.NotOwner.selector);
        apnft.setAutoPayout(id, true, ONE_HOUR, 1 ether);

        // An outsider cannot.
        vm.prank(outsider);
        vm.expectRevert(EndowmentNFT.NotOwner.selector);
        apnft.setAutoPayout(id, true, ONE_HOUR, 1 ether);

        // A previous owner cannot, once the token has moved on.
        vm.prank(alice);
        apnft.safeTransferFrom(alice, bob, id);
        vm.prank(alice);
        vm.expectRevert(EndowmentNFT.NotOwner.selector);
        apnft.setAutoPayout(id, true, ONE_HOUR, 1 ether);
    }

    function test_C3_5_mintAutoSettingsDoNotSurviveTransfer() public {
        // Minted with auto payouts ON, a fee set.
        uint256 id = _mintAutoSimple(alice, 1000, true, ONE_HOUR, 1 ether);
        (bool enabled0,,,) = apnft.autoPayoutOf(id);
        assertTrue(enabled0, "auto payouts on at mint");

        // Transfer to bob: a new owner never inherits payouts they did not choose.
        vm.prank(alice);
        apnft.safeTransferFrom(alice, bob, id);

        (bool enabled1,,,) = apnft.autoPayoutOf(id);
        assertFalse(enabled1, "auto payouts off after transfer");
        assertFalse(apnft.payoutDue(id), "no payout due for the new owner");

        // So no amount of bob's token can be forced public: a request reverts.
        vm.warp(block.timestamp + 100);
        vm.prank(keeper);
        vm.expectRevert(AutoPayoutEndowmentNFT.AutoPayoutDisabled.selector);
        apnft.requestPayout(id, 0);
    }

    function test_C3_5_revertedMintAuto_leavesNoStagedSettings() public {
        _fundCweth(creator, 1000);
        _authorise(creator, apnft);

        // A mintAuto that stages enabled=true on the id about to be minted, then reverts in
        // _mintEndowment (empty schedule). The staging write must be rolled back with the tx.
        (externalEuint64 h, bytes memory p) = _enc(1000, creator, address(apnft));
        Segment[] memory empty = new Segment[](0);
        vm.prank(creator);
        vm.expectRevert(EndowmentNFT.EmptySchedule.selector);
        apnft.mintAuto(alice, h, p, empty, uint64(block.timestamp), false, bytes32(0), true, ONE_HOUR, 7 ether);

        // The next successful mint takes id 1 and must get the DEFAULTS, not the staged values.
        uint256 id = _mintAutoSimple(alice, 1000, false, ONE_HOUR, 0);
        assertEq(id, 1, "id 1 was never consumed by the reverted mintAuto");

        (bool enabled, uint32 interval, uint128 fee,) = apnft.autoPayoutOf(id);
        assertFalse(enabled, "staged enabled=true did not survive the revert");
        assertEq(fee, 0, "staged fee did not survive the revert");
        assertEq(interval, ONE_HOUR, "this mint's own interval, not a leftover");

        // Belt and braces: a plain mint (no staging) after a reverted stage gets the default
        // interval, proving nothing lingered in storage for that id.
        uint256 id2 = _mintSimpleAuto(bob);
        (bool en2, uint32 int2,,) = apnft.autoPayoutOf(id2);
        assertFalse(en2, "plain mint: off");
        assertEq(int2, apnft.DEFAULT_INTERVAL(), "plain mint: default interval");
    }

    /// @dev A plain mint on the auto contract (inherited mint), no staged settings.
    function _mintSimpleAuto(address to) internal returns (uint256 id) {
        _fundCweth(creator, 10);
        _authorise(creator, apnft);
        id = _mint(apnft, creator, to, 10, _seg(1000, 1), uint64(block.timestamp), false, bytes32(0));
    }

    /// @dev The cWETH disclose path (requestDiscloseEncryptedAmount / makePubliclyDecryptable)
    ///      cannot be used to force an NFT-internal handle public. This is the direct,
    ///      non-derivation leg of C3-5: calling it on an EXISTING handle obtained from a view.
    function test_C3_5_discloseOfInternalHandleByUnauthorized_reverts() public {
        uint256 id = _mintAutoSimple(alice, 1000, true, ONE_HOUR, 0);
        vm.warp(block.timestamp + 100);
        vm.prank(alice);
        apnft.accrue(id);

        euint64 dist = apnft.distributionHandle(id);

        // An outsider is not allowed on the distribution handle at all.
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC7984.ERC7984UnauthorizedUseOfEncryptedAmount.selector, euint64.unwrap(dist), outsider
            )
        );
        cweth.requestDiscloseEncryptedAmount(dist);

        // Even the OWNER, who IS allowed on the distribution handle, cannot push it public via
        // cWETH: makePubliclyDecryptable needs cWETH (not the NFT) to hold ACL on the handle,
        // and cWETH never does for an NFT-internal handle, so the host ACL rejects it with
        // cWETH as the unauthorised sender.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ACL.SenderNotAllowed.selector, address(cweth)));
        cweth.requestDiscloseEncryptedAmount(dist);

        // The distribution handle is still not publicly decryptable.
        assertFalse(_publicDecryptable(dist), "distribution remained confidential");

        // The endowment handle: nobody but the NFT holds ACL, so the same path reverts for the
        // owner too (unauthorised use), and it is never public.
        euint64 endow = apnft.endowmentHandle(id);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC7984.ERC7984UnauthorizedUseOfEncryptedAmount.selector, euint64.unwrap(endow), alice
            )
        );
        cweth.requestDiscloseEncryptedAmount(endow);
        assertFalse(_publicDecryptable(endow), "endowment remained confidential");
    }
}
