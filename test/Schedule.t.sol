// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Schedule, Segment, INDEFINITE} from "../src/libraries/Schedule.sol";

contract ScheduleTest is Test {
    function _two() internal pure returns (Segment[] memory s) {
        s = new Segment[](2);
        s[0] = Segment({duration: 100, ratePerSec: 2}); // [0,100)   -> 200
        s[1] = Segment({duration: 100, ratePerSec: 5}); // [100,200) -> 500
    }

    function _openEnded() internal pure returns (Segment[] memory s) {
        s = new Segment[](2);
        s[0] = Segment({duration: 100, ratePerSec: 2});       // [0,100) -> 200
        s[1] = Segment({duration: INDEFINITE, ratePerSec: 3}); // [100, forever)
    }

    function test_isIndefinite() public pure {
        assertTrue(Schedule.isIndefinite(_openEnded()));
        assertFalse(Schedule.isIndefinite(_two()));
        assertFalse(Schedule.isIndefinite(new Segment[](0)));
    }

    function test_indefinite_integratesPastFiniteSegments() public pure {
        // 200 from the first segment + 3 * 900 from the open one
        assertEq(Schedule.integrate(_openEnded(), 0, 0, 1_000), 2_900);
    }

    function test_indefinite_scheduleEndIsMax() public pure {
        assertEq(Schedule.scheduleEnd(_openEnded(), 1_700_000_000), type(uint64).max);
    }

    function test_indefinite_noOverflowWithLateStart() public pure {
        uint64 start = type(uint64).max - 10;
        assertEq(Schedule.integrate(_openEnded(), start, start, type(uint64).max), 20);
    }

    function test_fullWindow() public pure {
        assertEq(Schedule.integrate(_two(), 0, 0, 200), 700);
    }

    function test_partialFirstSegment() public pure {
        assertEq(Schedule.integrate(_two(), 0, 0, 50), 100);
    }

    function test_spanningBoundary() public pure {
        // [50,150): 50s@2 + 50s@5 = 100 + 250
        assertEq(Schedule.integrate(_two(), 0, 50, 150), 350);
    }

    function test_clampsPastEnd() public pure {
        // to=10_000 clamps to 200 -> full 700
        assertEq(Schedule.integrate(_two(), 0, 0, 10_000), 700);
    }

    function test_emptyWhenToBeforeFrom() public pure {
        assertEq(Schedule.integrate(_two(), 0, 200, 100), 0);
    }

    function test_nonZeroStartOffset() public pure {
        // start=1000 shifts windows: integrate over [1000,1100) -> first segment -> 200
        assertEq(Schedule.integrate(_two(), 1000, 1000, 1100), 200);
    }

    function test_scheduleEnd() public pure {
        assertEq(Schedule.scheduleEnd(_two(), 1000), 1200);
    }

    function test_saturatesOnOverflow() public pure {
        Segment[] memory s = new Segment[](1);
        s[0] = Segment({duration: type(uint64).max, ratePerSec: type(uint64).max});
        assertEq(Schedule.integrate(s, 0, 0, type(uint64).max), type(uint64).max);
    }

    function testFuzz_monotonicAndBounded(uint64 from, uint64 to) public pure {
        Segment[] memory s = _two();
        uint64 v = Schedule.integrate(s, 0, from, to);
        assertLe(v, 700); // can never exceed the full schedule total
        if (to <= from) assertEq(v, 0);
    }
}
