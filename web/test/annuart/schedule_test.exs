defmodule Annuart.ScheduleTest do
  use ExUnit.Case, async: true

  alias Annuart.Schedule

  @max 18_446_744_073_709_551_615

  test "periods and totals for a fixed schedule" do
    segs = [%{duration: 100, rate_per_sec: 2}, %{duration: 100, rate_per_sec: 5}]

    assert [
             %{starts_at: 1000, duration: 100, rate_per_sec: 2, max_payable: 200},
             %{starts_at: 1100, duration: 100, rate_per_sec: 5, max_payable: 500}
           ] = Schedule.periods(segs, 1000)

    assert Schedule.total(segs) == 700
    assert Schedule.ends_at(segs, 1000) == 1200
    refute Schedule.indefinite?(segs)
  end

  test "indefinite tail" do
    segs = [%{duration: 100, rate_per_sec: 2}, %{duration: @max, rate_per_sec: 3}]
    assert Schedule.indefinite?(segs)

    assert [
             _,
             %{starts_at: 1100, duration: :indefinite, rate_per_sec: 3, max_payable: :until_empty}
           ] =
             Schedule.periods(segs, 1000)

    assert Schedule.total(segs) == :unbounded
    assert Schedule.ends_at(segs, 1000) == :never
  end

  test "string-keyed segments behave like atom-keyed ones" do
    segs = [
      %{"duration" => 100, "rate_per_sec" => 2},
      %{"duration" => @max, "rate_per_sec" => 3}
    ]

    assert Schedule.indefinite?(segs)
    assert Schedule.total(segs) == :unbounded
    assert Schedule.ends_at(segs, 1000) == :never

    assert [%{starts_at: 1000, max_payable: 200}, %{duration: :indefinite}] =
             Schedule.periods(segs, 1000)

    fixed = [%{"duration" => 10, "rate_per_sec" => 3}]
    assert Schedule.total(fixed) == 30
    assert Schedule.ends_at(fixed, 5) == 15
  end

  test "summary of a hidden schedule", do: assert(Schedule.summary(nil, 6) == "Private schedule")

  test "summary of a single indefinite period" do
    # 1 base unit/sec at 6 decimals = 86_400 / 10^6 per day
    assert Schedule.summary([%{duration: @max, rate_per_sec: 1}], 6) ==
             "0.0864 / day, indefinitely"
  end

  test "summary with a fixed first period and further periods" do
    day = 86_400

    segs = [
      %{duration: 540 * day, rate_per_sec: div(100_000_000, day)},
      %{duration: 30 * day, rate_per_sec: 1},
      %{duration: 30 * day, rate_per_sec: 1}
    ]

    assert Schedule.summary(segs, 6) =~ ~r{^\d+(\.\d+)? / day for 18 months, then 2 more periods$}

    exact = [%{duration: 365 * day, rate_per_sec: 1}, %{duration: 10, rate_per_sec: 1}]
    assert Schedule.summary(exact, 6) == "0.0864 / day for 1 year, then 1 more period"

    assert Schedule.summary([%{duration: 7 * day, rate_per_sec: 1}], 6) ==
             "0.0864 / day for 7 days"

    assert Schedule.summary([%{duration: 3600, rate_per_sec: 1}], 6) == "0.0864 / day for 1 hour"
  end

  test "summary trims trailing zeros and shows whole numbers without a point" do
    assert Schedule.summary([%{duration: @max, rate_per_sec: 1}], 0) ==
             "86400 / day, indefinitely"

    assert Schedule.summary([%{duration: @max, rate_per_sec: 5}], 6) ==
             "0.432 / day, indefinitely"
  end

  test "an indefinite sentinel is detected only when it is the stored value" do
    refute Schedule.indefinite?([%{duration: @max - 1, rate_per_sec: 1}])
  end
end
