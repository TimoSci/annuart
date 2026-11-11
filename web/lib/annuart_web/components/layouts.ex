defmodule AnnuartWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use AnnuartWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current, :atom, default: nil, doc: "the active navigation item"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="site-header">
      <nav class="nav" aria-label="Main">
        <.link navigate={~p"/"} class="brand">ANNUART</.link>
        <.link
          navigate={~p"/"}
          class={["nav-item", @current == :browse && "current"]}
          data-activity-id="nav:browse"
        >
          Browse
        </.link>
        <.link
          navigate={~p"/create"}
          class={["nav-item", @current == :create && "current"]}
          data-activity-id="nav:create"
        >
          Create
        </.link>
        <.link
          navigate={~p"/mine"}
          class={["nav-item", @current == :mine && "current"]}
          data-activity-id="nav:mine"
        >
          My ENFTs
        </.link>
        <.link
          navigate={~p"/market"}
          class={["nav-item", @current == :market && "current"]}
          data-activity-id="nav:market"
        >
          Market<span class="soon">soon</span>
        </.link>
        <.link
          href="/tokens"
          class={["nav-item", @current == :tokens && "current"]}
          data-activity-id="nav:tokens"
        >
          Tokens
        </.link>
        <span class="spacer"></span>
        <div id="wallet" phx-hook="Wallet" phx-update="ignore"></div>
        <button type="button" id="clear-activity" class="clear">Clear my activity history</button>
      </nav>
    </header>

    <main class="page">
      {render_slot(@inner_block)}
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
