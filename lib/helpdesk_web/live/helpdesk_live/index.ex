defmodule HelpdeskWeb.HelpdeskLive.Index do
  use HelpdeskWeb, :live_view

  alias Helpdesk.Support.{Ticket, Team, TeamMembership}
  alias Helpdesk.Accounts.User
  import Ecto.Query, only: [from: 2]

  require Ash.Query

  on_mount {HelpdeskWeb.LiveUserAuth, :live_user_required}

  @statuses [:new, :open, :waiting_on_customer, :waiting_on_support, :resolved, :closed]
  @priorities [:low, :medium, :high, :critical]
  @page_size 20

  @impl true
  def mount(
        _params,
        _session,
        %{assigns: %{current_user: %{role: :agent, status: :active}}} = socket
      ) do
    {:ok, redirect(socket, to: ~p"/inbox")}
  end

  def mount(_params, _session, %{assigns: %{current_user: %{role: :agent}}} = socket) do
    {:ok, redirect(socket, to: ~p"/sign-in")}
  end

  def mount(_params, _session, socket) do
    current_user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:page_title, page_title(current_user))
     |> assign(:current_scope, %{user: current_user})
     |> assign(:staff?, current_user.role in [:agent, :admin])
     |> assign(:assignment_form, nil)
     |> assign(:assignment_ticket, nil)
     |> assign(:team_options, [])
     |> assign(:assignee_options, [])
     |> assign(:tickets_empty?, true)
     |> assign(:ticket_count, 0)
     |> assign(:page_number, 1)
     |> assign(:total_pages, 1)
     |> assign(:filters, %{})
     |> assign(:filter_form, to_form(%{}, as: :filters))
     |> assign(:status_options, filter_options(@statuses))
     |> assign(:priority_options, filter_options(@priorities))
     |> assign(:sort_options, [{"Recently updated", "latest"}, {"Oldest updated", "oldest"}])
     |> stream(:tickets, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load_page(socket, normalize_filters(params), parse_page(params["page"]))}
  end

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    {:noreply, push_patch(socket, to: ~p"/tickets?#{compact_filters(params)}")}
  end

  def handle_event("open-assignment", %{"id" => id}, socket) do
    actor = socket.assigns.current_user

    with {:ok, ticket} when not is_nil(ticket) <- Ash.get(Ticket, id, actor: actor),
         true <- Ash.can?({ticket, :assign}, actor) do
      teams = Team |> Ash.Query.filter(active == true) |> Ash.read!(actor: actor)
      form = AshPhoenix.Form.for_update(ticket, :assign, actor: actor, as: "assignment")

      {:noreply,
       socket
       |> assign(:assignment_ticket, ticket)
       |> assign(:assignment_form, to_form(form))
       |> assign(:team_options, Enum.map(teams, &{&1.name, &1.id}))
       |> assign(:assignee_options, member_options(ticket.team_id, teams))}
    else
      _ -> {:noreply, put_flash(socket, :error, "You cannot assign this ticket.")}
    end
  end

  def handle_event("close-assignment", _params, socket) do
    {:noreply, assign(socket, assignment_form: nil, assignment_ticket: nil)}
  end

  def handle_event(event, %{"assignment" => params}, socket)
      when event in ["validate-assignment", "save-assignment"] do
    if socket.assigns.assignment_form do
      params = Map.take(params, ["team_id", "assignee_id"])
      teams = Enum.map(socket.assigns.team_options, fn {_label, id} -> %{id: id} end)
      options = member_options(params["team_id"], teams)
      previous_team = AshPhoenix.Form.value(socket.assigns.assignment_form, :team_id)

      params =
        if event == "validate-assignment" and params["team_id"] != previous_team,
          do: Map.put(params, "assignee_id", ""),
          else: params

      socket = assign(socket, :assignee_options, options)

      if event == "save-assignment" do
        case AshPhoenix.Form.submit(socket.assigns.assignment_form, params: params) do
          {:ok, _ticket} ->
            {:noreply,
             socket
             |> assign(assignment_form: nil, assignment_ticket: nil)
             |> load_page(socket.assigns.filters, socket.assigns.page_number)
             |> put_flash(:info, "Ticket assignment saved.")}

          {:error, form} ->
            {:noreply,
             socket
             |> assign(:assignment_form, form)
             |> put_flash(
               :error,
               "Could not save assignment. Check the selected team and assignee."
             )}
        end
      else
        {:noreply,
         assign(
           socket,
           :assignment_form,
           AshPhoenix.Form.validate(socket.assigns.assignment_form, params)
         )}
      end
    else
      {:noreply, socket}
    end
  end

  # Only expose staff directory entries for a team the actor can read, after
  # checking assignment permission on the ticket in open-assignment.
  defp member_options(team_id, teams) do
    if is_binary(team_id) and Enum.any?(teams, &(&1.id == team_id)) do
      Helpdesk.Repo.all(
        from user in User,
          join: membership in TeamMembership,
          on: membership.user_id == user.id,
          where: membership.team_id == ^team_id and user.role in [:agent, :admin],
          order_by: user.email,
          distinct: true,
          select: {user.email, user.id}
      )
      |> Enum.map(fn {email, id} -> {to_string(email), id} end)
    else
      []
    end
  end

  @impl true
  def render(%{current_user: %{role: :customer}} = assigns) do
    ~H"""
    <Layouts.app
      notification_count={@notification_count}
      current_page={:tickets}
      flash={@flash}
      current_scope={@current_scope}
    >
      <section id="customer-tickets">
        <header class="mb-6 flex flex-wrap items-end justify-between gap-4">
          <div>
            <h1 class="text-3xl font-black tracking-tight">My tickets</h1>
            <p class="mt-2 text-slate-500">
              All support requests from your account. <span id="ticket-count">{@ticket_count}</span>
              found.
            </p>
          </div>
          <.link
            id="new-ticket"
            navigate={~p"/ticket/new"}
            class="btn border-0 bg-sky-600 text-white hover:bg-sky-700"
          >
            <.icon name="hero-plus" class="size-4" />Submit a ticket
          </.link>
        </header>
        <div class="overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-sm">
          <.form
            for={@filter_form}
            id="ticket-filters"
            phx-change="filter"
            phx-submit="filter"
            class="grid gap-3 border-b border-slate-100 p-4 sm:grid-cols-2 lg:grid-cols-4"
          >
            <.input
              field={@filter_form[:q]}
              type="search"
              label="Search tickets"
              placeholder="Title or ticket number"
              phx-debounce="300"
            />
            <.input
              field={@filter_form[:status]}
              type="select"
              label="Status"
              prompt="All statuses"
              options={@status_options}
            />
            <.input
              field={@filter_form[:priority]}
              type="select"
              label="Priority"
              prompt="All priorities"
              options={@priority_options}
            />
            <.input field={@filter_form[:sort]} type="select" label="Sort" options={@sort_options} />
            <.link
              id="clear-ticket-filters"
              patch={~p"/tickets"}
              class="text-sm font-semibold text-sky-700"
            >
              Clear filters
            </.link>
          </.form>
          <div
            id="tickets"
            phx-update="stream"
            data-empty={to_string(@tickets_empty?)}
            class="divide-y divide-slate-100"
          >
            <div id="tickets-empty" class="hidden only:block p-12 text-center text-slate-500">
              No tickets found. Clear your filters or submit a new request.
            </div>
            <.link
              :for={{id, ticket} <- @streams.tickets}
              id={id}
              navigate={~p"/tickets/#{ticket.id}"}
              class="flex items-center gap-4 p-5 hover:bg-slate-50"
            >
              <span class="hidden size-10 shrink-0 place-items-center rounded-xl bg-sky-50 text-sky-600 sm:grid">
                <.icon name="hero-ticket" class="size-5" />
              </span>
              <div class="min-w-0 flex-1">
                <div class="flex flex-wrap items-center gap-2">
                  <h2 class="break-words font-bold">{ticket.title}</h2>
                  <span class={["badge badge-sm", status_class(ticket.status)]}>
                    {humanize(ticket.status)}
                  </span>
                </div>
                <p class="mt-1 text-sm text-slate-500">
                  {ticket.ticket_number} · Updated {format_datetime(ticket.updated_at)}
                </p>
                <p id={"ticket-assignee-#{ticket.id}"} class="mt-1 text-xs text-slate-500">
                  {if ticket.assignee, do: "Assigned to: #{ticket.assignee.email}", else: "Unassigned"}
                </p>
              </div>
              <.icon name="hero-chevron-right" class="size-5 shrink-0 text-slate-400" />
            </.link>
          </div>
        </div>
      </section>
      <.pagination
        page_number={@page_number}
        total_pages={@total_pages}
        filters={@filters}
        ticket_count={@ticket_count}
      />
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      notification_count={@notification_count}
      current_page={:tickets}
      flash={@flash}
      current_scope={@current_scope}
    >
      <div class="space-y-8">
        <header class="flex flex-col gap-5 sm:flex-row sm:items-end sm:justify-between">
          <div class="space-y-2">
            <p class="text-sm font-semibold uppercase tracking-wide text-primary">Help center</p>
            <h1 class="text-3xl font-semibold tracking-tight text-base-content">{@page_title}</h1>
            <p class="text-base-content/70">
              <span id="ticket-count">{@ticket_count}</span>
              {if(@ticket_count == 1, do: "ticket", else: "tickets")} found
            </p>
          </div>

          <.button id="new-ticket" navigate={~p"/ticket/new"} variant="primary">
            <.icon name="hero-plus" class="size-4" /> New ticket
          </.button>
        </header>

        <.form
          for={@filter_form}
          id="ticket-filters"
          phx-change="filter"
          class="rounded-box border border-base-300 bg-base-100 p-4 shadow-sm"
        >
          <div class="grid gap-4 md:grid-cols-2 lg:grid-cols-4">
            <.input
              field={@filter_form[:q]}
              type="search"
              label="Search"
              placeholder="Title or ticket number"
              autocomplete="off"
              phx-debounce="300"
            />
            <.input
              field={@filter_form[:status]}
              type="select"
              label="Status"
              prompt="All statuses"
              options={@status_options}
            />
            <.input
              field={@filter_form[:priority]}
              type="select"
              label="Priority"
              prompt="All priorities"
              options={@priority_options}
            />
            <.input
              field={@filter_form[:sort]}
              type="select"
              label="Sort"
              options={@sort_options}
            />
          </div>

          <div class="mt-2 flex justify-end">
            <.link
              id="clear-ticket-filters"
              patch={~p"/tickets"}
              class="btn btn-ghost btn-sm"
            >
              Clear filters
            </.link>
          </div>
        </.form>

        <div
          id="tickets"
          phx-update="stream"
          data-empty={to_string(@tickets_empty?)}
          class="space-y-3"
        >
          <div
            id="tickets-empty"
            class="hidden only:flex min-h-64 flex-col items-center justify-center rounded-box border border-dashed border-base-300 bg-base-100 px-6 text-center"
          >
            <div class="mb-4 rounded-full bg-base-200 p-3">
              <.icon name="hero-inbox" class="size-7 text-base-content/60" />
            </div>
            <h2 class="font-semibold text-base-content">
              {if(@tickets_empty?, do: "No tickets found", else: "Tickets")}
            </h2>
            <p class="mt-1 max-w-sm text-sm text-base-content/60">
              Try clearing your filters or create a ticket to ask the support team for help.
            </p>
          </div>

          <article
            :for={{dom_id, ticket} <- @streams.tickets}
            id={dom_id}
            class="rounded-box border border-base-300 bg-base-100 p-5 shadow-sm transition hover:border-primary/40 hover:shadow-md"
          >
            <div class="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
              <div class="min-w-0 space-y-2">
                <div class="flex flex-wrap items-center gap-2">
                  <span class="font-mono text-xs font-semibold text-base-content/55">
                    {ticket.ticket_number}
                  </span>
                  <span class={["badge badge-sm", status_class(ticket.status)]}>
                    {humanize(ticket.status)}
                  </span>
                  <span class={["badge badge-sm badge-outline", priority_class(ticket.priority)]}>
                    {humanize(ticket.priority)}
                  </span>
                </div>

                <h2 class="truncate text-lg font-semibold text-base-content">
                  <.link
                    id={"view-ticket-#{ticket.id}"}
                    navigate={~p"/tickets/#{ticket.id}"}
                    class="hover:underline"
                  >
                    {ticket.title}
                  </.link>
                </h2>

                <div class="flex flex-wrap items-center gap-x-4 gap-y-1 text-sm text-base-content/60">
                  <span :if={ticket.category} class="inline-flex items-center gap-1.5">
                    <.icon name="hero-tag" class="size-4" /> {humanize(ticket.category)}
                  </span>
                  <span class="inline-flex items-center gap-1.5">
                    <.icon name="hero-clock" class="size-4" /> Updated
                    <time datetime={DateTime.to_iso8601(ticket.updated_at)}>
                      {format_datetime(ticket.updated_at)}
                    </time>
                  </span>
                  <span id={"ticket-assignee-#{ticket.id}"} class="inline-flex items-center gap-1.5">
                    <.icon name="hero-user" class="size-4" />
                    <%= if ticket.assignee do %>
                      Assigned to: {to_string(ticket.assignee.email)}
                    <% else %>
                      Unassigned
                    <% end %>
                  </span>
                </div>
              </div>

              <button
                :if={Ash.can?({ticket, :assign}, @current_user)}
                id={"assign-ticket-#{ticket.id}"}
                type="button"
                phx-click="open-assignment"
                phx-value-id={ticket.id}
                class="btn btn-soft btn-sm"
              >
                <.icon name="hero-user-plus" class="size-4" /> Assign
              </button>
              <.link
                :if={@staff?}
                id={"edit-ticket-#{ticket.id}"}
                navigate={~p"/ticket/#{ticket.id}/edit"}
                class="btn btn-ghost btn-sm shrink-0"
              >
                <.icon name="hero-pencil-square" class="size-4" /> Edit
              </.link>
            </div>
          </article>
        </div>
      </div>
      <.pagination
        page_number={@page_number}
        total_pages={@total_pages}
        filters={@filters}
        ticket_count={@ticket_count}
      />
      <div
        :if={@assignment_form}
        id="assignment-modal"
        class="modal modal-open"
        role="dialog"
        aria-modal="true"
        aria-labelledby="assignment-title"
        phx-window-keydown="close-assignment"
        phx-key="Escape"
        phx-remove={JS.pop_focus()}
      >
        <.focus_wrap
          id="assignment-focus"
          class="modal-box"
          phx-mounted={JS.push_focus() |> JS.focus_first()}
        >
          <h2 id="assignment-title" class="text-xl font-semibold">Assign ticket</h2>
          <p class="my-3">{@assignment_ticket.ticket_number} · {@assignment_ticket.title}</p>
          <.form
            for={@assignment_form}
            id="assignment-form"
            phx-change="validate-assignment"
            phx-submit="save-assignment"
          >
            <.input
              field={@assignment_form[:team_id]}
              type="select"
              label="Team"
              prompt="No team"
              options={@team_options}
            />
            <.input
              field={@assignment_form[:assignee_id]}
              type="select"
              label="Assignee"
              prompt="Unassigned"
              options={@assignee_options}
            />
            <div class="modal-action">
              <button id="cancel-assignment" type="button" phx-click="close-assignment" class="btn">
                Cancel
              </button>
              <button
                id="save-assignment"
                type="submit"
                phx-disable-with="Saving…"
                class="btn btn-primary"
              >
                Save assignment
              </button>
            </div>
          </.form>
        </.focus_wrap>
      </div>
    </Layouts.app>
    """
  end

  defp load_page(socket, filters, requested_page) do
    query =
      Ticket
      |> filter_search(filters["q"])
      |> filter_enum(:status, filters["status"], @statuses)
      |> filter_enum(:priority, filters["priority"], @priorities)
      |> sort_tickets(filters["sort"])

    actor = socket.assigns.current_user
    page = read_page(query, actor, requested_page)
    total_pages = max(div(page.count + @page_size - 1, @page_size), 1)
    number = min(requested_page, total_pages)
    page = if number == requested_page, do: page, else: read_page(query, actor, number)
    tickets = load_assignee_labels(page.results)

    socket =
      socket
      |> assign(:filters, filters)
      |> assign(:filter_form, to_form(filters, as: :filters))
      |> assign(:tickets_empty?, tickets == [])
      |> assign(:ticket_count, page.count)
      |> assign(:page_number, number)
      |> assign(:total_pages, total_pages)
      |> stream(:tickets, tickets, reset: true)

    if number != requested_page,
      do: push_patch(socket, to: page_path(filters, number)),
      else: socket
  end

  defp read_page(query, actor, number) do
    Ash.read!(query,
      actor: actor,
      page: [limit: @page_size, offset: (number - 1) * @page_size, count: true]
    )
  end

  defp parse_page(value) when is_binary(value) and byte_size(value) <= 9 do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> number
      _ -> 1
    end
  end

  defp parse_page(_), do: 1

  defp page_path(filters, number) do
    params = compact_filters(filters)
    params = if number > 1, do: Map.put(params, "page", number), else: params
    ~p"/tickets?#{params}"
  end

  attr :page_number, :integer, required: true
  attr :total_pages, :integer, required: true
  attr :ticket_count, :integer, required: true
  attr :filters, :map, required: true

  defp pagination(assigns) do
    assigns =
      assign(
        assigns,
        :pages,
        Enum.sort(
          Enum.uniq(
            [1, assigns.total_pages] ++
              Enum.to_list(
                max(1, assigns.page_number - 2)..min(assigns.total_pages, assigns.page_number + 2)
              )
          )
        )
      )

    ~H"""
    <nav
      id="ticket-pagination"
      aria-label="Ticket pages"
      class="mt-6 flex flex-wrap items-center justify-between gap-3"
    >
      <p id="ticket-page-summary" class="text-sm text-base-content/70">
        Page {@page_number} of {@total_pages} · {@ticket_count} tickets
      </p>
      <div class="flex flex-wrap items-center gap-1">
        <.link
          :if={@page_number > 1}
          id="tickets-previous"
          patch={page_path(@filters, @page_number - 1)}
          class="btn btn-sm btn-ghost"
        >
          Previous
        </.link>
        <button :if={@page_number == 1} id="tickets-previous" disabled class="btn btn-sm btn-ghost">
          Previous
        </button>
        <.link
          :for={number <- @pages}
          id={"tickets-page-#{number}"}
          patch={page_path(@filters, number)}
          aria-label={"Page #{number}"}
          aria-current={if number == @page_number, do: "page", else: nil}
          class={["btn btn-sm", if(number == @page_number, do: "btn-primary", else: "btn-ghost")]}
        >
          {number}
        </.link>
        <.link
          :if={@page_number < @total_pages}
          id="tickets-next"
          patch={page_path(@filters, @page_number + 1)}
          class="btn btn-sm btn-ghost"
        >
          Next
        </.link>
        <button
          :if={@page_number == @total_pages}
          id="tickets-next"
          disabled
          class="btn btn-sm btn-ghost"
        >
          Next
        </button>
      </div>
    </nav>
    """
  end

  # Only load labels after ticket policies have restricted the result set.
  # General user reads remain protected by the Accounts policies.
  defp load_assignee_labels(tickets) do
    Ash.load!(tickets, [assignee: Ash.Query.select(User, [:id, :email])], authorize?: false)
  end

  defp filter_search(query, nil), do: query
  defp filter_search(query, ""), do: query

  defp filter_search(query, search) do
    Ash.Query.filter(query, contains(title, ^search) or contains(ticket_number, ^search))
  end

  defp filter_enum(query, _field, nil, _allowed), do: query
  defp filter_enum(query, _field, "", _allowed), do: query

  defp filter_enum(query, field, value, allowed) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> query
      parsed -> Ash.Query.filter_input(query, %{field => %{eq: parsed}})
    end
  end

  defp sort_tickets(query, "oldest"), do: Ash.Query.sort(query, updated_at: :asc, id: :asc)
  defp sort_tickets(query, _latest), do: Ash.Query.sort(query, updated_at: :desc, id: :asc)

  defp normalize_filters(params) do
    %{
      "q" => params |> Map.get("q", "") |> String.trim(),
      "status" => allowed_value(params["status"], @statuses),
      "priority" => allowed_value(params["priority"], @priorities),
      "sort" => if(params["sort"] == "oldest", do: "oldest", else: "latest")
    }
  end

  defp compact_filters(params) do
    params
    |> normalize_filters()
    |> Enum.reject(fn
      {"q", ""} -> true
      {"status", nil} -> true
      {"priority", nil} -> true
      {"sort", "latest"} -> true
      _ -> false
    end)
    |> Map.new()
  end

  defp allowed_value(value, allowed) do
    if value in Enum.map(allowed, &Atom.to_string/1), do: value
  end

  defp filter_options(values), do: Enum.map(values, &{humanize(&1), &1})

  defp page_title(%{role: role}) when role in [:agent, :admin], do: "Ticket queue"
  defp page_title(_user), do: "Your tickets"

  defp humanize(value) do
    value
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp status_class(:new), do: "badge-info"
  defp status_class(:open), do: "badge-primary"

  defp status_class(status) when status in [:waiting_on_customer, :waiting_on_support],
    do: "badge-warning"

  defp status_class(:resolved), do: "badge-success"
  defp status_class(:closed), do: "badge-neutral"

  defp priority_class(:critical), do: "text-error"
  defp priority_class(:high), do: "text-warning"
  defp priority_class(_priority), do: ""

  defp format_datetime(datetime), do: Calendar.strftime(datetime, "%b %d, %Y at %H:%M")
end
