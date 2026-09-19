defmodule HelpdeskWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use HelpdeskWeb, :html

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

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :current_page, :atom, default: nil
  attr :notification_count, :integer, default: nil

  slot :inner_block, required: true

  def app(%{current_scope: %{user: %{role: role, status: :active}}} = assigns)
      when role in [:admin, :customer, :agent] do
    assigns = assign(assigns, customer?: role == :customer, agent?: role == :agent)

    ~H"""
    <div
      data-theme="light"
      class={["min-h-screen bg-slate-50 text-slate-800", @customer? && "customer-portal"]}
    >
      <a href="#main-content" class="sr-only focus:not-sr-only focus:block focus:p-3">
        Skip to content
      </a>
      <header class="sticky top-0 z-30 border-b border-slate-200 bg-white/95 backdrop-blur">
        <div class="mx-auto flex h-16 max-w-[1600px] items-center gap-3 px-4 lg:px-6">
          <.link
            navigate={
              if @customer?, do: ~p"/portal", else: if(@agent?, do: ~p"/inbox", else: ~p"/admin")
            }
            class="flex items-center gap-2 text-lg font-black tracking-tight text-slate-900"
          >
            <span class="grid size-9 place-items-center rounded-xl bg-sky-600 text-white">
              <.icon name="hero-lifebuoy" class="size-5" />
            </span>
            <span>Beacon<span class="text-sky-600">Desk</span></span>
          </.link>
          <span class="ml-auto rounded-lg bg-violet-50 px-3 py-1 text-xs font-bold text-violet-700">
            {if @customer?, do: "Customer", else: if(@agent?, do: "Agent", else: "Admin")}
          </span>
          <.link
            href={~p"/sign-out"}
            class="rounded-lg px-3 py-2 text-sm font-semibold hover:bg-slate-100"
          >
            Sign out
          </.link>
          <.link
            id="notification-bell"
            navigate={~p"/notifications"}
            aria-label={
              if is_integer(@notification_count),
                do: "Notifications, #{@notification_count} unread",
                else: "Notifications"
            }
            class="relative rounded-lg p-2 text-slate-600 hover:bg-slate-100"
          >
            <.icon name="hero-bell" class="size-6" />
            <span
              :if={is_integer(@notification_count) and @notification_count > 0}
              id="notification-badge"
              aria-live="polite"
              class="absolute -right-2 -top-1 rounded-full bg-sky-600 px-1.5 text-xs font-bold text-white"
            >
              {if @notification_count > 99, do: "99+", else: @notification_count}
            </span>
          </.link>
        </div>
      </header>
      <div class="mx-auto flex max-w-[1600px] flex-col lg:flex-row">
        <aside class="shrink-0 border-b border-slate-200 bg-white p-4 lg:sticky lg:top-16 lg:h-[calc(100vh-4rem)] lg:w-64 lg:border-r lg:border-b-0">
          <div class="mb-5 hidden rounded-2xl bg-slate-900 p-4 text-white lg:block">
            <p class="text-xs font-bold uppercase tracking-widest text-sky-300">
              {if @customer?,
                do: "Customer portal",
                else: if(@agent?, do: "Support workspace", else: "Admin workspace")}
            </p>
            <p class="mt-2 truncate font-bold">
              {@current_scope.user.first_name} {@current_scope.user.last_name}
            </p>
            <p class="mt-1 truncate text-xs text-slate-300">{@current_scope.user.email}</p>
          </div>
          <nav aria-label="Workspace" class="flex flex-wrap gap-1 lg:flex-col">
            <.workspace_link
              :if={!@customer?}
              href={~p"/inbox"}
              icon="hero-inbox-stack"
              active={@current_page == :inbox}
            >
              Team inbox
            </.workspace_link>
            <.workspace_link
              :if={@customer?}
              href={~p"/portal"}
              icon="hero-squares-2x2"
              active={@current_page == :overview}
            >
              Overview
            </.workspace_link>
            <.workspace_link href={~p"/tickets"} icon="hero-inbox" active={@current_page == :tickets}>
              {if @customer?, do: "My tickets", else: "Ticket queue"}
            </.workspace_link>
            <.workspace_link
              href={~p"/ticket/new"}
              icon="hero-plus-circle"
              active={@current_page == :new_ticket}
            >
              New ticket
            </.workspace_link>
            <.workspace_link
              :if={@customer?}
              href={~p"/help"}
              icon="hero-book-open"
              active={@current_page == :help}
            >
              Help center
            </.workspace_link>
            <p
              :if={!@customer? and !@agent?}
              class="mt-5 hidden px-3 pb-2 text-[11px] font-bold uppercase tracking-widest text-slate-400 lg:block"
            >
              Administration
            </p>
            <.workspace_link
              :if={!@customer? and !@agent?}
              href={~p"/admin"}
              icon="hero-chart-bar"
              active={@current_page == :operations}
            >
              Operations
            </.workspace_link>
            <.workspace_link
              :if={!@customer? and !@agent?}
              href={~p"/admin/bulk-assignment"}
              icon="hero-arrow-path"
              active={@current_page == :bulk_assignment}
            >
              Bulk assign tickets
            </.workspace_link>
            <.workspace_link
              :if={!@customer? and !@agent?}
              href={~p"/teams"}
              icon="hero-user-group"
              active={@current_page == :teams}
            >
              Teams
            </.workspace_link>
            <.workspace_link
              :if={!@customer? and !@agent?}
              href={~p"/users"}
              icon="hero-users"
              active={@current_page == :users}
            >
              Users
            </.workspace_link>
          </nav>
        </aside>
        <main id="main-content" class="min-w-0 flex-1 p-4 md:p-6 lg:p-8">
          {render_slot(@inner_block)}
        </main>
      </div>
      <.flash_group flash={@flash} />
    </div>
    """
  end

  def app(assigns) do
    ~H"""
    <header class="navbar px-4 sm:px-6 lg:px-8">
      <div class="flex-1">
        <a href="/" class="flex-1 flex w-fit items-center gap-2">
          <img src={~p"/images/logo.svg"} width="36" />
          <span class="text-sm font-semibold">v{Application.spec(:phoenix, :vsn)}</span>
        </a>
      </div>
      <div class="flex-none">
        <ul class="flex flex-column px-1 space-x-4 items-center">
          <li>
            <a href="https://phoenixframework.org/" class="btn btn-ghost">Website</a>
          </li>
          <li>
            <a href="https://github.com/phoenixframework/phoenix" class="btn btn-ghost">GitHub</a>
          </li>
          <li>
            <.theme_toggle />
          </li>
          <li>
            <a href="https://hexdocs.pm/phoenix/overview.html" class="btn btn-primary">
              Get Started <span aria-hidden="true">&rarr;</span>
            </a>
          </li>
        </ul>
      </div>
    </header>

    <main class="px-4 py-20 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-2xl space-y-4">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  attr :href, :string, required: true
  attr :icon, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  defp workspace_link(assigns) do
    ~H"""
    <.link
      navigate={@href}
      aria-current={@active && "page"}
      class={[
        "flex items-center gap-3 rounded-xl px-3 py-2.5 text-sm transition-colors focus-visible:outline-2 focus-visible:outline-sky-600",
        if(@active,
          do: "bg-sky-100 font-bold text-sky-700",
          else: "text-slate-600 hover:bg-slate-100"
        )
      ]}
    >
      <.icon name={@icon} class="size-4" />{render_slot(@inner_block)}
    </.link>
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
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
