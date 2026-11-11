defmodule AnnuartWeb.WalletHook do
  @moduledoc """
  Tracks the address the browser says its wallet is connected as, in `:address`
  (lowercased, or `nil`).

  The address is a display hint only: it picks which ENFTs to list and which
  panels to show. It is not authentication. The browser can claim any address,
  so nothing private may ever be served on the strength of it.
  """
  import Phoenix.Component, only: [assign: 3]
  alias Phoenix.LiveView

  @address ~r/\A0x[0-9a-fA-F]{40}\z/

  def on_mount(:default, _params, _session, socket) do
    {:cont,
     socket
     |> assign(:address, nil)
     |> LiveView.attach_hook(:wallet, :handle_event, &handle_event/3)}
  end

  defp handle_event("wallet:changed", %{"address" => address}, socket) do
    case normalize(address) do
      {:ok, address} -> {:halt, assign(socket, :address, address)}
      :error -> {:halt, socket}
    end
  end

  # Without an "address" key the payload is malformed too; ignore it.
  defp handle_event("wallet:changed", _params, socket), do: {:halt, socket}
  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp normalize(nil), do: {:ok, nil}

  defp normalize(address) when is_binary(address) do
    if Regex.match?(@address, address), do: {:ok, String.downcase(address)}, else: :error
  end

  defp normalize(_), do: :error
end
