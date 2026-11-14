// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FHE, euint64, externalEuint64} from "@fhevm/solidity/lib/FHE.sol";
import {IERC7984} from "@openzeppelin/confidential-contracts/interfaces/IERC7984.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {KMSVerifier} from "@fhevm/host-contracts/contracts/KMSVerifier.sol";
import {RedTeamBase} from "./RedTeamBase.sol";
import {EndowmentNFT} from "../../src/EndowmentNFT.sol";
import {AutoPayoutEndowmentNFT} from "../../src/AutoPayoutEndowmentNFT.sol";
import {Segment} from "../../src/libraries/Schedule.sol";

/// @dev Accepts the NFT and accepts ETH only when handed nearly all of the 100k stipend,
///      failing fast otherwise so the finaliser keeps most of its gas. Can act as requester.
contract GasHungryReceiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function requestPayout(AutoPayoutEndowmentNFT nft, uint256 id) external returns (bytes32) {
        return nft.requestPayout(id, 0);
    }

    receive() external payable {
        require(gasleft() > 95000, "starved");
    }
}

/// @dev Accepts the NFT; on an ETH send (empty calldata) it returns a large blob of return
///      data. A caller that copied the returndata would pay for the memory; `_sendEth` passes
///      retSize 0, so it must not.
contract ReturnBomber {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {
        // The EVM `return` opcode hands back 64 KiB regardless of the empty return signature.
        assembly ("memory-safe") {
            return(0, 0x10000)
        }
    }
}

/// @dev Task 3 of the red team: attacks on the automatic-payout path (request ids,
///      finalisation with forged/replayed proofs, ETH/WETH accounting, gas starvation).
contract PayoutTest is RedTeamBase {
    uint256 internal constant WEI = WEI_PER_UNIT; // 1e9 wei per cWETH unit

    event PayoutPaid(
        uint256 indexed tokenId, bytes32 indexed requestId, uint256 amountWei, uint256 feeWei, bool paidInWeth
    );

    /// @dev Reads the apnft pool's cWETH balance in units.
    function _poolCweth() internal returns (uint64) {
        return _bal(IERC7984(address(cweth)), address(apnft));
    }

    // =====================================================================
    // C2-7 Payout request ids
    //
    // The unwrap request id is the ciphertext handle of the burned amount (the wrapper
    // asserts uniqueness, W:220). The mock derives op-result handles by content
    // (keccak over op + operands + acl + chainid + prev-blockhash + timestamp, no
    // per-op counter: FHEVMExecutor._binaryOp), so two requests whose burns have the
    // same operands in the same block would collide and trip the wrapper's assert.
    // =====================================================================

    /// Two enabled tokens with nothing claimable (schedule just started, 0 accrued) request
    /// in the same block. Each burn mutates the shared pool balance handle, so the ids differ.
    function test_C2_7_twoZeroClaimTokens_sameBlock_distinctRequestIds() public {
        uint256 a = _mintAutoSimple(alice, 1000, true, 3600, 0);
        uint256 b = _mintAutoSimple(bob, 1000, true, 3600, 0);

        // block.timestamp == scheduleStart: the schedule has started but nothing accrued.
        bytes32 ra = _requestPayout(a, keeper);
        bytes32 rb = _requestPayout(b, keeper);

        assertTrue(ra != bytes32(0), "a id nonzero");
        assertTrue(rb != bytes32(0), "b id nonzero");
        assertTrue(ra != rb, "distinct ids");

        // Both finalise, paying nothing, and neither reverted on the uniqueness assert.
        assertEq(_finalizePayout(a, keeper), 0, "a pays 0");
        assertEq(_finalizePayout(b, keeper), 0, "b pays 0");
    }

    /// Two tokens sitting in a zero-rate segment (nothing ever accrues inside it) request in
    /// the same block. Same analysis: ids are distinct, no assert fires.
    function test_C2_7_zeroRateSegment_twoTokens_distinctRequestIds() public {
        _fundCweth(creator, 2000);
        _authorise(creator, apnft);
        uint256 a = _mintAuto(creator, alice, 1000, _seg(1000, 0), uint64(block.timestamp), false, bytes32(0), true, 3600, 0);
        uint256 b = _mintAuto(creator, bob, 1000, _seg(1000, 0), uint64(block.timestamp), false, bytes32(0), true, 3600, 0);

        vm.warp(block.timestamp + 100); // still inside the zero-rate segment: claimable stays 0
        bytes32 ra = _requestPayout(a, keeper);
        bytes32 rb = _requestPayout(b, keeper);
        assertTrue(ra != rb && ra != bytes32(0) && rb != bytes32(0), "distinct nonzero ids");
        assertEq(_finalizePayout(a, keeper), 0, "a pays 0");
        assertEq(_finalizePayout(b, keeper), 0, "b pays 0");
    }

    /// The same token requests again right after a zero payout, and again across several
    /// intervals. Every id is distinct and no request reverts on the wrapper's assert.
    function test_C2_7_sameToken_acrossIntervals_distinctIds() public {
        // A long zero-rate segment: nothing ever accrues, so every payout is zero.
        _fundCweth(creator, 1000);
        _authorise(creator, apnft);
        uint256 id =
            _mintAuto(creator, alice, 1000, _seg(100000, 0), uint64(block.timestamp), false, bytes32(0), true, 3600, 0);
        vm.warp(block.timestamp + 100); // schedule started, still zero-rate

        bytes32[] memory ids = new bytes32[](4);
        for (uint256 i = 0; i < 4; i++) {
            ids[i] = _requestPayout(id, keeper);
            assertEq(_finalizePayout(id, keeper), 0, "zero payout");
            // Request again right after: must wait one interval (PayoutTooSoon otherwise).
            vm.warp(block.timestamp + 3600);
        }
        for (uint256 i = 0; i < 4; i++) {
            assertTrue(ids[i] != bytes32(0), "nonzero id");
            for (uint256 j = i + 1; j < 4; j++) {
                assertTrue(ids[i] != ids[j], "ids distinct across intervals");
            }
        }
    }

    // =====================================================================
    // C2-8 Finalising a payout
    //
    // Existing suite already proves: wrong cleartext and a valid proof for another handle
    // (test_finalize_wrongCleartext_reverts), finalise twice (test_finalize_twice_reverts),
    // and finalise after a third party finalised the unwrap on the wrapper
    // (test_finalize_afterThirdPartyFinalizedOnWrapper), all in test/AutoPayoutEndowmentNFT.t.sol.
    // The tests below add forged signatures, cross-payout proof reuse and a self-unwrap.
    // =====================================================================

    /// A proof whose signature bytes are tampered with recovers some non-KMS address.
    function test_C2_8_forgedSignature_reverts() public {
        uint256 id = _mintAutoSimple(alice, 1000, true, 3600, 0);
        vm.warp(block.timestamp + 100);
        bytes32 rid = _requestPayout(id, keeper);
        (uint64 clear, bytes memory proof) = _decryptionProof(rid);

        // Flip the recovery id v (the last byte of the single 65-byte signature, 27<->28):
        // the (r,s) pair now recovers a different, valid address that is not a KMS signer.
        // (proof = [numSigners(1)] ++ [r(32) s(32) v(1)] ++ [extraData(1)].)
        bytes memory forged = bytes.concat(proof);
        forged[65] = forged[65] == bytes1(uint8(27)) ? bytes1(uint8(28)) : bytes1(uint8(27));

        vm.expectPartialRevert(KMSVerifier.KMSInvalidSigner.selector);
        apnft.finalizePayout(id, clear, forged);

        // The pending payout is untouched and still finalises with the real proof.
        (bytes32 still,,,) = apnft.pendingPayoutOf(id);
        assertEq(still, rid, "pending preserved");
        apnft.finalizePayout(id, clear, proof);
        assertEq(alice.balance, 100 * WEI, "true amount still paid once");
    }

    /// An empty proof is rejected before any signer is recovered.
    function test_C2_8_emptyProof_reverts() public {
        uint256 id = _mintAutoSimple(alice, 1000, true, 3600, 0);
        vm.warp(block.timestamp + 100);
        bytes32 rid = _requestPayout(id, keeper);
        (uint64 clear,) = _decryptionProof(rid);

        vm.expectRevert(KMSVerifier.EmptyDecryptionProof.selector);
        apnft.finalizePayout(id, clear, "");
        (bytes32 still,,,) = apnft.pendingPayoutOf(id);
        assertEq(still, rid, "pending preserved");
    }

    /// A genuine, valid proof for a *different* live payout cannot finalise this one: the
    /// signatures are over the other token's request-id handle, not this one's.
    function test_C2_8_validProofForOtherLivePayout_reverts() public {
        uint256 a = _mintAutoSimple(alice, 1000, true, 3600, 0);
        uint256 b = _mintAutoSimple(bob, 1000, true, 3600, 0);
        vm.warp(block.timestamp + 100);

        bytes32 ra = _requestPayout(a, keeper);
        bytes32 rb = _requestPayout(b, keeper);
        (uint64 clearA, bytes memory proofA) = _decryptionProof(ra);
        (uint64 clearB, bytes memory proofB) = _decryptionProof(rb);
        assertEq(clearA, clearB, "same cleartext, different handle");

        // Finalise token b with token a's valid proof: signer mismatch (bound to ra's handle).
        vm.expectPartialRevert(KMSVerifier.KMSInvalidSigner.selector);
        apnft.finalizePayout(b, clearA, proofA);

        // Each finalises with its own proof, paying exactly once.
        apnft.finalizePayout(a, clearA, proofA);
        apnft.finalizePayout(b, clearB, proofB);
        assertEq(alice.balance, 100 * WEI);
        assertEq(bob.balance, 100 * WEI);
    }

    /// A proof captured from payout N cannot be replayed on payout N+1: the later payout has
    /// a fresh request-id handle, so the old signatures do not verify against it.
    function test_C2_8_replayedProofOnLaterPayout_reverts() public {
        uint256 id = _mintAutoSimple(alice, 1000, true, 3600, 0);
        vm.warp(block.timestamp + 100);
        bytes32 rid1 = _requestPayout(id, keeper);
        (uint64 clear1, bytes memory proof1) = _decryptionProof(rid1);
        apnft.finalizePayout(id, clear1, proof1);
        assertEq(alice.balance, 100 * WEI);

        // Second payout, one interval later.
        vm.warp(block.timestamp + 3600);
        bytes32 rid2 = _requestPayout(id, keeper);
        assertTrue(rid2 != rid1, "fresh request id");
        (uint64 clear2, bytes memory proof2) = _decryptionProof(rid2);

        // Replay the first proof (and its cleartext) on the second payout: rejected.
        vm.expectPartialRevert(KMSVerifier.KMSInvalidSigner.selector);
        apnft.finalizePayout(id, clear1, proof1);

        // The genuine second proof works, paying only the second payout's amount.
        uint256 before = alice.balance;
        apnft.finalizePayout(id, clear2, proof2);
        assertEq(alice.balance - before, uint256(clear2) * WEI, "only true second amount paid");
    }

    /// An attacker unwrapping their own cWETH *to* the apnft before finalising cannot inflate
    /// or redirect the pending payout: finalize touches only its own request id, and the
    /// attacker's WETH is merely donated (and stuck).
    function test_C2_8_attackerUnwrapsOwnTokensToNft_payoutUnaffected() public {
        uint256 id = _mintAutoSimple(alice, 1000, true, 3600, 0);
        vm.warp(block.timestamp + 100);
        bytes32 rid = _requestPayout(id, keeper); // true amount 100 units

        // Mallory unwraps 50 of her own cWETH, directing the WETH at the apnft, and finalises
        // that unwrap herself so the WETH actually lands there.
        _fundCweth(mallory, 50);
        (externalEuint64 h, bytes memory p) = _enc(50, mallory, address(cweth));
        vm.prank(mallory);
        bytes32 mrid = cweth.unwrap(mallory, address(apnft), h, p);
        assertTrue(mrid != rid, "attacker's unwrap id differs from the pending one");
        (uint64 mclear, bytes memory mproof) = _decryptionProof(mrid);
        cweth.finalizeUnwrap(mrid, mclear, mproof);
        assertEq(weth.balanceOf(address(apnft)), 50 * WEI, "attacker donation parked as WETH");

        // The legit payout finalises for exactly the true amount, paid to the real recipient.
        uint64 paid = _finalizePayout(id, keeper);
        assertEq(paid, 100, "only the true accrued amount");
        assertEq(alice.balance, 100 * WEI, "recipient got exactly the true amount");
        // The 50-unit donation is still stuck; nobody extracted it and the payout was unchanged.
        assertEq(weth.balanceOf(address(apnft)), 50 * WEI, "donation still stuck");
        assertEq(address(apnft).balance, 0, "no leftover ETH");
    }

    // =====================================================================
    // C2-9 ETH and WETH accounting
    //
    // Existing suite proves the 10% cap and a tiny fee paid in full
    // (test_fee_paidToRequester_cappedAtTenPercent) and that plain ETH is refused
    // (test_receive_rejectsPlainEth). The tests below add fee == uint128 max, tiny payouts,
    // requester == recipient, and direct WETH/cWETH donations.
    // =====================================================================

    /// An astronomically large fee is still capped at 10% of the payout.
    function test_C2_9_feeMax_cappedAtTenPercent() public {
        uint256 id = _mintAutoSimple(alice, 1000, true, 3600, type(uint128).max);
        vm.warp(block.timestamp + 100); // 100 units accrued

        _requestPayout(id, keeper);
        (bytes32 rid,,,) = apnft.pendingPayoutOf(id);
        (uint64 clear, bytes memory proof) = _decryptionProof(rid);
        vm.expectEmit(true, true, false, true, address(apnft));
        emit PayoutPaid(id, rid, 100 * WEI, 10 * WEI, false);
        apnft.finalizePayout(id, clear, proof);

        assertEq(keeper.balance, 10 * WEI, "requester gets exactly 10%");
        assertEq(alice.balance, 90 * WEI, "recipient gets exactly 90%");
    }

    /// For a tiny payout (1 unit) the cap keeps at least 90% with the recipient even at max fee.
    function test_C2_9_smallPayout_feeMax_recipientKeeps90() public {
        uint256 id = _mintAutoSimple(alice, 1000, true, 3600, type(uint128).max);
        vm.warp(block.timestamp + 1); // 1 unit accrued -> 1e9 wei

        uint64 paid = _payoutRoundTrip(id, keeper, keeper);
        assertEq(paid, 1, "1 unit");
        assertEq(keeper.balance, WEI / 10, "fee capped at 10% of 1e9 wei");
        assertEq(alice.balance, WEI - WEI / 10, "recipient keeps 90%");
        assertEq(keeper.balance + alice.balance, WEI, "whole payout distributed");
    }

    /// A zero payout pays no fee even when the fee is set to the maximum.
    function test_C2_9_zeroPayout_feeMax_paysNothing() public {
        uint256 id = _mintAutoSimple(alice, 1000, true, 3600, type(uint128).max);
        vm.prank(alice);
        apnft.claim(id); // nothing accrued yet, but prove zero explicitly via a later request

        bytes32 rid = _requestPayout(id, keeper);
        (uint64 clear, bytes memory proof) = _decryptionProof(rid);
        assertEq(clear, 0, "zero amount");
        vm.expectEmit(true, true, false, true, address(apnft));
        emit PayoutPaid(id, rid, 0, 0, false);
        apnft.finalizePayout(id, clear, proof);
        assertEq(keeper.balance, 0, "no fee on a zero payout");
        assertEq(alice.balance, 0);
    }

    /// When the requester is also the recipient (the owner triggers their own payout), fee and
    /// share both land on that one address, which receives the whole payout in ETH.
    function test_C2_9_requesterIsRecipient_ownerGetsWhole() public {
        uint256 id = _mintAutoSimple(alice, 1000, true, 3600, 5);
        vm.warp(block.timestamp + 100);

        // Alice requests her own payout: recipient == requester == alice.
        _requestPayout(id, alice);
        uint64 paid = _finalizePayout(id, alice);
        assertEq(paid, 100);
        assertEq(alice.balance, 100 * WEI, "owner receives fee + share = the whole payout");
        assertEq(address(apnft).balance, 0);
        assertEq(weth.balanceOf(address(apnft)), 0);
    }

    /// WETH sent straight to the apnft stays there: a payout withdraws only its own amount,
    /// and nobody can extract the donation.
    function test_C2_9_directWethDonation_stuck_payoutExact() public {
        uint256 id = _mintAutoSimple(alice, 1000, true, 3600, 0);
        vm.warp(block.timestamp + 100);

        // A donor parks 500 units' worth of WETH on the apnft.
        uint256 donation = 500 * WEI;
        vm.deal(donor, donation);
        vm.startPrank(donor);
        weth.deposit{value: donation}();
        weth.transfer(address(apnft), donation);
        vm.stopPrank();
        assertEq(weth.balanceOf(address(apnft)), donation);

        uint64 paid = _payoutRoundTrip(id, keeper, keeper);
        assertEq(paid, 100, "exact accrued amount");
        assertEq(alice.balance, 100 * WEI, "recipient got exactly the true amount, not inflated");
        // The donation is untouched and stuck; the contract holds no stray ETH.
        assertEq(weth.balanceOf(address(apnft)), donation, "WETH donation still stuck");
        assertEq(address(apnft).balance, 0, "no stray ETH");
    }

    /// cWETH sent straight to the apnft inflates the pool but cannot be drawn down by a payout,
    /// which burns only the token's own distribution.
    function test_C2_9_directCwethDonation_stuck_payoutExact() public {
        uint256 id = _mintAutoSimple(alice, 1000, true, 3600, 0); // pool now holds 1000 units
        vm.warp(block.timestamp + 100);

        // Donor wraps and transfers 500 cWETH units straight into the apnft's pool.
        _fundCweth(donor, 500);
        euint64 donorBal = cweth.confidentialBalanceOf(donor); // read before pranking
        vm.prank(donor);
        cweth.confidentialTransfer(address(apnft), donorBal);
        assertEq(_poolCweth(), 1500, "pool inflated by the donation");

        uint64 paid = _payoutRoundTrip(id, keeper, keeper);
        assertEq(paid, 100, "exact accrued amount, not inflated by the 500-unit donation");
        assertEq(alice.balance, 100 * WEI);
        // Pool = 1000 funded - 100 burned + 500 donated = 1400; the donation is still trapped.
        assertEq(_poolCweth(), 1400, "donation remains in the pool, unattributed and stuck");
    }

    /// The apnft, the wrapper and WETH can never be a payout recipient: minting an auto token
    /// to a non-ERC721-receiver reverts, and transferring one to such an address disables
    /// auto payouts, so requestPayout can never snapshot them as recipient.
    function test_C2_9_cannotMakeContractsTheRecipient() public {
        _fundCweth(creator, 3000);
        _authorise(creator, apnft);

        // (a) minting an enabled auto token directly to the apnft/wrapper/WETH reverts.
        address[3] memory targets = [address(apnft), address(cweth), address(weth)];
        for (uint256 i = 0; i < targets.length; i++) {
            (externalEuint64 h, bytes memory p) = _enc(1000, creator, address(apnft));
            vm.prank(creator);
            vm.expectPartialRevert(IERC721Errors.ERC721InvalidReceiver.selector);
            apnft.mintAuto(targets[i], h, p, _seg(1000, 1), uint64(block.timestamp), false, bytes32(0), true, 3600, 0);
        }

        // (b) transferring an enabled token to the apnft disables auto payouts, so a payout
        //     can never be requested with the apnft as recipient.
        uint256 id = _mintAutoSimple(alice, 1000, true, 3600, 0);
        vm.prank(alice);
        apnft.transferFrom(alice, address(apnft), id); // plain transfer: no receiver check
        assertEq(apnft.ownerOf(id), address(apnft));
        vm.expectRevert(AutoPayoutEndowmentNFT.AutoPayoutDisabled.selector);
        apnft.requestPayout(id, 0);
    }

    // =====================================================================
    // C2-10 Starving the payment
    //
    // Existing suite proves a recipient that rejects ETH / burns gas is paid in WETH
    // (test_recipientRejectsEth_paidInWeth, test_recipientBurnsGas_paidInWeth), a rejecting
    // requester's fee goes to the recipient (test_requesterRejectsEth_feeGoesToRecipient),
    // re-entry is blocked (test_reentrantRecipient_cannotReenter, and C2-5 in Theft.t.sol),
    // a too-low gas limit cannot divert payments (test_finalize_withTooLittleGas_cannotDivertPayments)
    // and the InsufficientGas guard reverts just below the boundary
    // (test_finalize_justBelowGasRequirement_revertsInsufficientGas), all over MockWETH.
    // The tests below re-run the gas grid over real WETH9, add a return-data bomb, and
    // assert the InsufficientGas guard directly.
    // =====================================================================

    /// Over real WETH9 (withdraw forwards only the 2300-gas stipend): for every gas limit the
    /// finalise either reverts or pays both the fee and the share in ETH -- never a WETH
    /// fallback and never the fee diverted to the recipient.
    function test_C2_10_gasGrid_cannotDivertFeeOrForceWeth() public {
        GasHungryReceiver owner_ = new GasHungryReceiver();
        GasHungryReceiver requester = new GasHungryReceiver();
        _fundCweth(creator, 1000);
        _authorise(creator, apnft);
        uint256 id = _mintAuto(creator, address(owner_), 1000, _seg(1000, 1), uint64(block.timestamp), false, bytes32(0), true, 3600, 5);
        vm.warp(block.timestamp + 100);

        bytes32 rid = requester.requestPayout(apnft, id);
        (uint64 clear, bytes memory proof) = _decryptionProof(rid);
        bytes memory data = abi.encodeCall(apnft.finalizePayout, (id, clear, proof));

        uint256 successes;
        for (uint256 g = 150_000; g < 500_000; g += 1_000) {
            uint256 snap = vm.snapshotState();
            (bool ok,) = address(apnft).call{gas: g}(data);
            if (ok) {
                successes++;
                assertEq(address(requester).balance, 5, "fee paid in ETH to the requester");
                assertEq(address(owner_).balance, 100 * WEI - 5, "share paid in ETH to the recipient");
                assertEq(weth.balanceOf(address(owner_)), 0, "no WETH fallback");
            }
            vm.revertToState(snap);
        }
        assertGt(successes, 0, "some gas limit succeeds");
    }

    /// A recipient whose fallback returns a large blob cannot bloat the finaliser's memory:
    /// `_sendEth` copies no return data, so the ETH payment succeeds with bounded gas.
    function test_C2_10_recipientReturnsLargeData_paidInEthBounded() public {
        ReturnBomber owner_ = new ReturnBomber();
        _fundCweth(creator, 1000);
        _authorise(creator, apnft);
        uint256 id = _mintAuto(creator, address(owner_), 1000, _seg(1000, 1), uint64(block.timestamp), false, bytes32(0), true, 3600, 0);
        vm.warp(block.timestamp + 100);

        bytes32 rid = _requestPayout(id, keeper);
        (uint64 clear, bytes memory proof) = _decryptionProof(rid);

        uint256 gasBefore = gasleft();
        vm.expectEmit(true, true, false, true, address(apnft));
        emit PayoutPaid(id, rid, 100 * WEI, 0, false); // paidInWeth == false: ETH send "succeeded"
        apnft.finalizePayout(id, clear, proof);
        assertLt(gasBefore - gasleft(), 1_000_000, "finalise gas bounded despite 64 KiB returndata");

        assertEq(address(owner_).balance, 100 * WEI, "recipient paid in ETH");
        assertEq(weth.balanceOf(address(owner_)), 0, "not paid in WETH");
        assertEq(address(apnft).balance, 0);
    }

    /// The InsufficientGas guard (AP:270) reverts the whole finalise when the finaliser does
    /// not leave enough for a full stipend, leaving the pending payout intact and paying no one.
    function test_C2_10_sendEth_insufficientGas_revertsPreservesPending() public {
        uint256 id = _mintAutoSimple(alice, 1000, true, 3600, 0);
        vm.warp(block.timestamp + 100);
        bytes32 rid = _requestPayout(id, keeper);
        (uint64 clear, bytes memory proof) = _decryptionProof(rid);
        bytes memory data = abi.encodeCall(apnft.finalizePayout, (id, clear, proof));

        // Find the lowest gas limit that succeeds; one notch below must hit the guard.
        uint256 enough;
        for (uint256 g = 150_000; g < 600_000; g += 1_000) {
            uint256 snap = vm.snapshotState();
            (bool ok,) = address(apnft).call{gas: g}(data);
            vm.revertToState(snap);
            if (ok) {
                enough = g;
                break;
            }
        }
        assertGt(enough, 0, "some gas limit is enough");

        // One notch below the threshold stops at the guard, not an opaque out-of-gas.
        vm.expectRevert(AutoPayoutEndowmentNFT.InsufficientGas.selector);
        (bool reverted,) = address(apnft).call{gas: enough - 1_000}(data);
        reverted; // the revert itself is asserted by expectRevert

        // Nothing moved; the pending payout is intact and still finalises for the true amount.
        (bytes32 still,,,) = apnft.pendingPayoutOf(id);
        assertEq(still, rid, "pending preserved");
        assertEq(alice.balance, 0, "no one paid");
        apnft.finalizePayout(id, clear, proof);
        assertEq(alice.balance, 100 * WEI);
    }
}
