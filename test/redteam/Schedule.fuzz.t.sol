// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Schedule, Segment, INDEFINITE} from "../../src/libraries/Schedule.sol";

/// @dev Task 7 (C4-4): property fuzz of the plaintext Schedule library, the maths every
///      accrual, claim, transfer and payout request stands on. Properties checked:
///        - `integrate` is additive over adjacent intervals (saturating addition),
///        - monotonic non-decreasing in `to`,
///        - zero for a window entirely outside the schedule,
///        - never above (largest rate in the schedule) x elapsed time,
///        - saturates at type(uint64).max without reverting;
///      and `scheduleEnd`, cross-checked against the mint validation (ET:107-122): any
///      schedule mint accepts has an end that is either type(uint64).max (indefinite last
///      segment) or exactly start + sum(durations).
contract ScheduleFuzzTest is Test {
    uint64 internal constant MAX = type(uint64).max;

    // ---- helpers ----

    /// @dev Saturating uint64 addition, mirroring integrate's `>= MAX -> MAX` cap.
    function _satAdd(uint64 x, uint64 y) internal pure returns (uint64) {
        uint256 s = uint256(x) + uint256(y);
        // casting to uint64 is safe: this branch runs only when s < MAX
        // forge-lint: disable-next-line(unsafe-typecast)
        return s >= MAX ? MAX : uint64(s);
    }

    /// @dev Saturating uint256 multiply capped at MAX (the ceiling integrate can return).
    function _satMulCap(uint256 x, uint256 y) internal pure returns (uint256) {
        if (x == 0 || y == 0) return 0;
        uint256 p = x * y; // x,y are bounded below (<= 1e13), so this cannot overflow uint256
        return p >= MAX ? MAX : p;
    }

    /// @dev Builds `n` segments (1..8) from fuzz words. Durations/rates are bounded so a
    ///      single segment can still overflow uint64 (1e13 * 1e13 = 1e26 > MAX), exercising
    ///      saturation, while the running segment offset stays far below uint256 overflow.
    function _build(uint256 n, uint64[8] memory durs, uint64[8] memory rates)
        internal
        pure
        returns (Segment[] memory s)
    {
        n = bound(n, 1, 8);
        s = new Segment[](n);
        for (uint256 i = 0; i < n; i++) {
            s[i] = Segment({
                duration: uint64(bound(durs[i], 0, 1e13)),
                ratePerSec: uint64(bound(rates[i], 0, 1e13))
            });
        }
    }

    function _maxRate(Segment[] memory s) internal pure returns (uint64 m) {
        for (uint256 i = 0; i < s.length; i++) {
            if (s[i].ratePerSec > m) m = s[i].ratePerSec;
        }
    }

    /// @dev Mirrors EndowmentNFT._storeSchedule (ET:107-122): the exact set of schedules
    ///      `mint` accepts. Cross-checked against the real contract by the multi-segment and
    ///      indefinite mints in Griefing.t.sol (C4-1, C4-5), which read scheduleEndOf.
    function _mintAccepts(Segment[] memory s, uint64 start) internal pure returns (bool) {
        if (s.length == 0) return false;
        uint256 fixedEnd = start;
        for (uint256 i = 0; i < s.length; i++) {
            if (s[i].duration == 0) return false;
            if (s[i].duration == INDEFINITE) {
                if (i != s.length - 1) return false;
                if (s[i].ratePerSec == 0) return false;
            } else {
                fixedEnd += s[i].duration;
            }
        }
        if (fixedEnd >= MAX) return false;
        return true;
    }

    /// @dev Builds a schedule mint is guaranteed to accept (no vm.assume needed, stays pure):
    ///      1..8 segments, every finite duration in [1, 1e13] (never zero), the running sum
    ///      kept below MAX by bounding `start`, and optionally an indefinite last segment.
    function _buildMintable(uint256 n, uint64[8] memory durs, uint64[8] memory rates, uint64 startIn, bool lastIndefinite)
        internal
        pure
        returns (Segment[] memory s, uint64 start)
    {
        n = bound(n, 1, 8);
        s = new Segment[](n);
        uint256 sum = 0;
        for (uint256 i = 0; i < n; i++) {
            uint64 d = uint64(bound(durs[i], 1, 1e13)); // never zero
            s[i] = Segment({duration: d, ratePerSec: uint64(bound(rates[i], 0, 1e13))});
            sum += d;
        }
        if (lastIndefinite) {
            s[n - 1] = Segment({duration: INDEFINITE, ratePerSec: 1}); // nonzero rate, last position
            sum -= uint256(bound(durs[n - 1], 1, 1e13)); // the finite duration it replaced
        }
        // start kept low enough that start + finite sum stays below MAX.
        // casts are safe: sum <= 8e13 and the bound keeps the result below MAX.
        // forge-lint: disable-next-line(unsafe-typecast)
        start = uint64(bound(startIn, 0, MAX - 1 - uint64(sum)));
    }

    // ---- integrate properties ----

    /// C4-4: integrate is additive over adjacent intervals, under saturating addition.
    function testFuzz_C4_4_integrate_additiveOverAdjacentIntervals(
        uint64 start,
        uint64 a,
        uint64 b,
        uint64 c,
        uint256 n,
        uint64[8] memory durs,
        uint64[8] memory rates
    ) public pure {
        Segment[] memory s = _build(n, durs, rates);
        // order the three cut points: a <= b <= c
        (a, b) = a <= b ? (a, b) : (b, a);
        (b, c) = b <= c ? (b, c) : (c, b);
        (a, b) = a <= b ? (a, b) : (b, a);

        uint64 left = Schedule.integrate(s, start, a, b);
        uint64 right = Schedule.integrate(s, start, b, c);
        uint64 whole = Schedule.integrate(s, start, a, c);
        assertEq(whole, _satAdd(left, right), "integrate not additive over [a,b]+[b,c]");
    }

    /// C4-4: integrate is monotonic non-decreasing as `to` grows.
    function testFuzz_C4_4_integrate_monotonicInTo(
        uint64 start,
        uint64 from,
        uint64 to1,
        uint64 to2,
        uint256 n,
        uint64[8] memory durs,
        uint64[8] memory rates
    ) public pure {
        Segment[] memory s = _build(n, durs, rates);
        (to1, to2) = to1 <= to2 ? (to1, to2) : (to2, to1);
        uint64 lo = Schedule.integrate(s, start, from, to1);
        uint64 hi = Schedule.integrate(s, start, from, to2);
        assertLe(lo, hi, "integrate not monotonic in to");
    }

    /// C4-4: a window entirely outside the schedule accrues nothing.
    function testFuzz_C4_4_integrate_zeroOutsideWindow(
        uint64 start,
        uint64 from,
        uint64 to,
        uint256 n,
        uint64[8] memory durs,
        uint64[8] memory rates
    ) public pure {
        Segment[] memory s = _build(n, durs, rates);
        // Before the start: any [from, to) with to <= start accrues nothing.
        uint64 beforeTo = uint64(bound(to, 0, start));
        assertEq(Schedule.integrate(s, start, from, beforeTo), 0, "nonzero before start");

        // After a finite schedule's end: [from, to) with from >= end accrues nothing.
        uint64 end = Schedule.scheduleEnd(s, start);
        if (end != MAX) {
            uint64 afterFrom = uint64(bound(from, end, MAX));
            assertEq(Schedule.integrate(s, start, afterFrom, MAX), 0, "nonzero after end");
        }
    }

    /// C4-4: integrate never exceeds (largest rate in the schedule) x elapsed time.
    function testFuzz_C4_4_integrate_boundedByMaxRateTimesElapsed(
        uint64 start,
        uint64 from,
        uint64 to,
        uint256 n,
        uint64[8] memory durs,
        uint64[8] memory rates
    ) public pure {
        Segment[] memory s = _build(n, durs, rates);
        uint64 v = Schedule.integrate(s, start, from, to);
        uint256 elapsed = to > from ? uint256(to) - uint256(from) : 0;
        uint256 bound_ = _satMulCap(uint256(_maxRate(s)), elapsed);
        assertLe(uint256(v), bound_, "integrate above maxRate * elapsed");
    }

    /// C4-4: integrate saturates at MAX rather than reverting, even when a single segment
    ///       would overflow. (The fuzz runner also proves no revert across random inputs.)
    function testFuzz_C4_4_integrate_saturatesWithoutRevert(
        uint64 start,
        uint64 from,
        uint64 to,
        uint256 n,
        uint64[8] memory durs,
        uint64[8] memory rates
    ) public pure {
        Segment[] memory s = _build(n, durs, rates);
        uint64 v = Schedule.integrate(s, start, from, to); // must not revert
        assertLe(v, MAX, "integrate above uint64 max");
    }

    /// C4-4: the extreme case (full uint64 duration and rate) saturates exactly at MAX.
    function test_C4_4_integrate_fullRange_saturatesAtMax() public pure {
        Segment[] memory s = new Segment[](1);
        s[0] = Segment({duration: MAX, ratePerSec: MAX});
        assertEq(Schedule.integrate(s, 0, 0, MAX), MAX);
    }

    // ---- scheduleEnd vs the mint checks ----

    /// C4-4: for every schedule mint accepts, scheduleEnd is MAX when the last segment is
    ///       indefinite, and exactly start + sum(durations) otherwise.
    function testFuzz_C4_4_scheduleEnd_matchesMintChecks(
        uint64 startIn,
        uint256 n,
        uint64[8] memory durs,
        uint64[8] memory rates,
        bool lastIndefinite
    ) public pure {
        (Segment[] memory s, uint64 start) = _buildMintable(n, durs, rates, startIn, lastIndefinite);
        assertTrue(_mintAccepts(s, start), "constructed schedule must be mint-accepted");

        uint64 end = Schedule.scheduleEnd(s, start);
        if (Schedule.isIndefinite(s)) {
            assertEq(end, MAX, "indefinite schedule end must be MAX");
        } else {
            uint256 sum = start;
            for (uint256 i = 0; i < s.length; i++) {
                sum += s[i].duration;
            }
            assertLt(sum, uint256(MAX), "mint-accepted finite schedule must stay below MAX");
            assertEq(uint256(end), sum, "finite schedule end must equal start + sum(durations)");
        }
    }

    /// C4-4: a mint-accepted schedule's end is MAX if and only if its last segment is
    ///       indefinite (so MAX can never be a coincidental finite sum).
    function testFuzz_C4_4_scheduleEnd_maxOnlyWhenIndefinite(
        uint64 startIn,
        uint256 n,
        uint64[8] memory durs,
        uint64[8] memory rates,
        bool lastIndefinite
    ) public pure {
        (Segment[] memory s, uint64 start) = _buildMintable(n, durs, rates, startIn, lastIndefinite);
        assertTrue(_mintAccepts(s, start), "constructed schedule must be mint-accepted");
        bool endIsMax = Schedule.scheduleEnd(s, start) == MAX;
        assertEq(endIsMax, Schedule.isIndefinite(s), "scheduleEnd == MAX must match indefinite");
    }
}
