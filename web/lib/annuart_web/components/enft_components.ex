defmodule AnnuartWeb.EnftComponents do
  @moduledoc """
  Display components for ENFTs: identity (name, number and creator picture),
  schedule chart and table, addresses and dates.
  """
  use Phoenix.Component

  alias Annuart.{Randomart, Schedule}

  @indefinite_share 30
  @min_bar_height 4

  @doc """
  How an ENFT is named everywhere: its creator's picture, its name when it has
  one, and its number. Names are not unique and anyone can pick any name, so a
  name is never shown without the two things that cannot be copied: the token
  number and the creator. `unnamed` is the text shown in place of a missing name.
  """
  attr :enft, :map, required: true
  attr :unnamed, :string, default: nil
  attr :size, :atom, default: :small, values: [:small, :large]

  def identity(assigns) do
    ~H"""
    <span class="enft-identity" data-role="enft-identity">
      <%!-- The tooltip is a title attribute, not an SVG <title>, so the address
           never becomes part of the surrounding text (a heading, a link). --%>
      <span class="randomart-box" title={"Creator #{@enft.creator}"}>
        <.randomart address={@enft.creator} size={@size} />
      </span>
      <span :if={@enft.name} class="enft-name" data-role="enft-name">{@enft.name}</span>
      <span :if={!@enft.name && @unnamed} class="enft-name">{@unnamed}</span>
      <span class="enft-number" data-role="enft-number">#{@enft.token_id}</span>
    </span>
    """
  end

  @doc """
  The creator's address as a small picture (see `Annuart.Randomart`): squares
  darken with visits, a ring marks where the walk started and a dot where it
  ended. Hovering shows the address. Renders nothing for a malformed address.
  """
  attr :address, :string, required: true
  attr :size, :atom, default: :small, values: [:small, :large]

  def randomart(assigns) do
    assigns = assign(assigns, :cells, Randomart.cells(assigns.address))

    ~H"""
    <svg
      :if={@cells}
      class={["randomart", @size == :large && "large"]}
      viewBox={"0 0 #{Randomart.width()} #{Randomart.height()}"}
      role="img"
      aria-label={"Creator #{@address}"}
      data-role="randomart"
      data-creator={@address}
    >
      <rect
        :for={c <- @cells}
        :if={c.visits > 0}
        x={c.x}
        y={c.y}
        width="1"
        height="1"
        fill="currentColor"
        opacity={visit_opacity(c.visits)}
      />
      <%= for c <- @cells, c.mark do %>
        <circle
          :if={c.mark == :start}
          cx={c.x + 0.5}
          cy={c.y + 0.5}
          r="0.32"
          fill="none"
          stroke="currentColor"
          stroke-width="0.2"
        />
        <circle :if={c.mark == :end} cx={c.x + 0.5} cy={c.y + 0.5} r="0.42" fill="currentColor" />
      <% end %>
    </svg>
    """
  end

  defp visit_opacity(visits), do: 0.1 + 0.15 * min(visits, 5)

  @doc "Bar chart of a schedule: width by duration, height by rate, indefinite period striped."
  attr :periods, :list, required: true

  def schedule_chart(assigns) do
    assigns = assign(assigns, :bars, bars(assigns.periods))

    ~H"""
    <div class="bars" role="img" aria-label="Payout schedule chart">
      <div
        :for={bar <- @bars}
        data-role="bar"
        data-indefinite={bar.indefinite && ""}
        class={["bar", bar.indefinite && "open"]}
        style={"width:#{bar.width}%;height:#{bar.height}%"}
      >
      </div>
    </div>
    """
  end

  defp bars(periods) do
    indefinite? = Enum.any?(periods, &(&1.duration == :indefinite))
    fixed_share = if indefinite?, do: 100 - @indefinite_share, else: 100
    fixed_total = periods |> Enum.map(&fixed_duration/1) |> Enum.sum()
    max_rate = periods |> Enum.map(& &1.rate_per_sec) |> Enum.max(fn -> 0 end)

    Enum.map(periods, fn p ->
      width =
        cond do
          p.duration == :indefinite -> @indefinite_share
          fixed_total == 0 -> 0
          true -> pct(fixed_share * p.duration / fixed_total)
        end

      height = if max_rate == 0, do: @min_bar_height, else: pct(100 * p.rate_per_sec / max_rate)
      %{width: width, height: max(height, @min_bar_height), indefinite: p.duration == :indefinite}
    end)
  end

  defp fixed_duration(%{duration: :indefinite}), do: 0
  defp fixed_duration(%{duration: d}), do: d

  defp pct(value), do: value |> Float.round(1) |> trim_float()
  defp trim_float(f) when f == trunc(f), do: trunc(f)
  defp trim_float(f), do: f

  @doc "Table of schedule periods. Amounts show — when the token's decimals are unknown."
  attr :periods, :list, required: true
  attr :decimals, :integer, default: nil
  attr :symbol, :string, default: nil

  def schedule_table(assigns) do
    ~H"""
    <table class="schedule">
      <thead>
        <tr>
          <th>Period</th>
          <th>Length</th>
          <th class="n">Rate</th>
          <th class="n">Up to</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={p <- @periods}>
          <td>From <.datetime value={p.starts_at} format={:date} /></td>
          <td>{length_cell(p.duration)}</td>
          <td class="n">{rate_cell(p, @decimals)}</td>
          <td class="n">{max_cell(p, @decimals, @symbol)}</td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp length_cell(:indefinite), do: "Indefinitely"
  defp length_cell(seconds), do: Schedule.length_text(seconds)

  defp rate_cell(_p, nil), do: "—"
  defp rate_cell(p, decimals), do: Schedule.per_day(p.rate_per_sec, decimals) <> " / day"

  defp max_cell(%{max_payable: :until_empty}, _decimals, _symbol), do: "until empty"
  defp max_cell(_p, nil, _symbol), do: "—"

  defp max_cell(p, decimals, symbol),
    do: [Schedule.format_amount(p.max_payable, decimals), symbol && " " <> symbol]

  @doc "A shortened address such as `0x70f3…a2c1`, with ` (you)` when it is the viewer's."
  attr :value, :string, required: true
  attr :you, :boolean, default: false

  def address(assigns) do
    ~H"""
    <span class="addr" title={@value}>{short(@value)}{if @you, do: " (you)"}</span>
    """
  end

  @doc false
  def short("0x" <> hex = full) when byte_size(hex) > 8,
    do: binary_part(full, 0, 6) <> "…" <> binary_part(full, byte_size(full) - 4, 4)

  def short(other), do: other

  @doc "A UTC date and time from a `DateTime` or unix seconds. Shows — for nil."
  attr :value, :any, required: true
  attr :format, :atom, default: :datetime
  attr :rest, :global

  def datetime(%{value: nil} = assigns) do
    ~H"""
    <span {@rest}>—</span>
    """
  end

  def datetime(assigns) do
    case to_datetime(assigns.value) do
      {:ok, dt} ->
        assigns = assign(assigns, :dt, dt)

        ~H"""
        <time {@rest} datetime={DateTime.to_iso8601(@dt)}>{format(@dt, @format)}</time>
        """

      :error ->
        ~H"""
        <span {@rest}>Far in the future</span>
        """
    end
  end

  # Unix seconds come from uint64 contract values and may be beyond the calendar's range.
  defp to_datetime(%DateTime{} = dt), do: {:ok, dt}

  defp to_datetime(seconds) when is_integer(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, dt} -> {:ok, dt}
      {:error, _} -> :error
    end
  end

  defp format(dt, :date), do: Calendar.strftime(dt, "%Y-%m-%d")
  defp format(dt, :datetime), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
end
