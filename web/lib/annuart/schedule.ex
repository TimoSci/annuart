defmodule Annuart.Schedule do
  @moduledoc """
  Pure display maths for payout schedules. Segments are maps with `duration` and
  `rate_per_sec`, keyed by atoms (as `Annuart.Chain.Reader.schedule/2` returns) or by
  strings (as `Annuart.Enfts.Enft.schedule` is stored). A duration of `2^64 - 1` means
  indefinite.
  """

  @indefinite 18_446_744_073_709_551_615
  @day 86_400
  @units [{"year", 365 * @day}, {"month", 30 * @day}, {"day", @day}, {"hour", 3600}]

  def indefinite?(segments), do: Enum.any?(segments, &(duration(&1) == @indefinite))

  def periods(segments, schedule_start) do
    {periods, _} =
      Enum.map_reduce(segments, schedule_start, fn seg, starts_at ->
        {dur, rate} = {duration(seg), rate(seg)}

        if dur == @indefinite do
          {%{
             starts_at: starts_at,
             duration: :indefinite,
             rate_per_sec: rate,
             max_payable: :until_empty
           }, starts_at}
        else
          {%{starts_at: starts_at, duration: dur, rate_per_sec: rate, max_payable: dur * rate},
           starts_at + dur}
        end
      end)

    periods
  end

  def total(segments) do
    if indefinite?(segments),
      do: :unbounded,
      else: Enum.sum(for s <- segments, do: duration(s) * rate(s))
  end

  def ends_at(segments, schedule_start) do
    if indefinite?(segments),
      do: :never,
      else: schedule_start + Enum.sum(Enum.map(segments, &duration/1))
  end

  @doc """
  One-line description, e.g. `"100 / day for 18 months, then 2 more periods"` or
  `"25 / day, indefinitely"`. Amounts are per day in whole token units.
  """
  def summary(nil, _decimals), do: "Private schedule"
  def summary([], _decimals), do: "Empty schedule"

  def summary([first | rest], decimals) do
    per_day = per_day(rate(first), decimals) <> " / day"

    head =
      if duration(first) == @indefinite,
        do: per_day <> ", indefinitely",
        else: per_day <> " for " <> length_text(duration(first))

    case rest do
      [] -> head
      [_] -> head <> ", then 1 more period"
      _ -> head <> ", then #{length(rest)} more periods"
    end
  end

  defp length_text(seconds) do
    case Enum.find(@units, fn {_, size} -> rem(seconds, size) == 0 end) do
      {name, size} -> plural(div(seconds, size), name)
      nil -> plural(seconds, "second")
    end
  end

  defp plural(1, name), do: "1 " <> name
  defp plural(n, name), do: "#{n} #{name}s"

  # rate_per_sec * 86400 / 10^decimals as a trimmed decimal string, in integer arithmetic.
  defp per_day(rate, decimals) do
    scale = Integer.pow(10, decimals)
    amount = rate * @day
    whole = div(amount, scale)
    frac = rem(amount, scale)

    if frac == 0 do
      Integer.to_string(whole)
    else
      digits =
        frac
        |> Integer.to_string()
        |> String.pad_leading(decimals, "0")
        |> String.trim_trailing("0")

      "#{whole}.#{digits}"
    end
  end

  defp duration(%{duration: d}), do: d
  defp duration(%{"duration" => d}), do: d
  defp rate(%{rate_per_sec: r}), do: r
  defp rate(%{"rate_per_sec" => r}), do: r
end
