defmodule HelpdeskWeb.HelpdeskLive.Agent do
  use HelpdeskWeb, :live_view
  alias Helpdesk.Accounts.{Authorization, User}
  alias Helpdesk.Support.{Ticket, Message, Team, TeamMembership}
  alias HelpdeskWeb.TicketUploads
  alias Helpdesk.Repo
  require Ash.Query
  import Ecto.Query, only: [from: 2]
  on_mount {HelpdeskWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_, _, socket) do
    actor = socket.assigns.current_user

    if actor.role in [:agent, :admin] and Authorization.allowed?(actor, :read_tickets) do
      {:ok,
       socket
       |> assign(:current_scope, %{user: actor})
       |> assign(:page_title, "Team inbox")
       |> assign(:ticket, nil)
       |> assign(:upload_form, to_form(%{}, as: :upload))
       |> TicketUploads.allow(&presign_upload/2)
       |> assign(:mode, "public")
       |> assign(:message_form, nil)
       |> assign(
         :status_options,
         options([:new, :open, :waiting_on_customer, :waiting_on_support, :resolved, :closed])
       )
       |> assign(:priority_options, options([:low, :medium, :high, :critical]))
       |> stream(:tickets, [])
       |> stream(:messages, [])
       |> stream(:attachments, [])}
    else
      {:ok, redirect(socket, to: ~p"/tickets")}
    end
  end

  @impl true
  def handle_params(params, _, socket) do
    actor = Repo.get(User, socket.assigns.current_user.id)

    if actor && actor.role in [:admin, :agent] && Authorization.allowed?(actor, :read_tickets) do
      load_inbox(params, assign(socket, :current_user, actor))
    else
      {:noreply, redirect(socket, to: ~p"/sign-in")}
    end
  end

  defp load_inbox(params, socket) do
    actor = socket.assigns.current_user
    scope = if params["scope"] in ["mine", "team", "unassigned"], do: params["scope"], else: "all"
    q = String.trim(params["q"] || "")
    base = Ticket |> Ash.Query.for_read(:read, %{}, actor: actor)

    query =
      case scope do
        "mine" ->
          Ash.Query.filter(base, assignee_id == ^actor.id)

        "team" ->
          Ash.Query.filter(base, exists(team.members, user_id == ^actor.id))

        "unassigned" ->
          Ash.Query.filter(base, is_nil(assignee_id) and status not in [:resolved, :closed])

        _ ->
          base
      end

    query =
      if q == "",
        do: query,
        else: Ash.Query.filter(query, contains(title, ^q) or contains(ticket_number, ^q))

    tickets = query |> Ash.Query.sort(updated_at: :desc, id: :asc) |> Ash.read!(actor: actor)

    counts = %{
      unassigned:
        Ash.count!(
          Ash.Query.filter(base, is_nil(assignee_id) and status not in [:resolved, :closed]),
          actor: actor
        ),
      open:
        Ash.count!(Ash.Query.filter(base, status in [:new, :open, :waiting_on_support]),
          actor: actor
        ),
      waiting: Ash.count!(Ash.Query.filter(base, status == :waiting_on_customer), actor: actor),
      mine:
        Ash.count!(
          Ash.Query.filter(base, assignee_id == ^actor.id and status not in [:resolved, :closed]),
          actor: actor
        )
    }

    socket =
      socket
      |> assign(:counts, counts)
      |> assign(:filters, %{"q" => q, "scope" => scope})
      |> assign(:filter_form, to_form(%{"q" => q, "scope" => scope}, as: :filters))
      |> assign(:ticket_count, length(tickets))
      |> stream(:tickets, tickets, reset: true)

    id =
      params["id"] ||
        case tickets do
          [ticket | _] -> ticket.id
          [] -> nil
        end

    {:noreply, select_ticket(socket, id)}
  end

  @impl true
  def handle_event("validate-uploads", _, socket), do: {:noreply, socket}

  def handle_event("cancel-upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :attachments, ref)}

  def handle_event("save-uploads", _, socket) do
    {entries, pending} = uploaded_entries(socket, :attachments)

    with {:ok, ticket, actor} <- upload_access(socket),
         true <-
           pending == [] and entries != [] and
             upload_errors(socket.assigns.uploads.attachments) == [] do
      case Repo.transaction(fn -> TicketUploads.persist!(ticket, entries, actor) end) do
        {:ok, _} ->
          TicketUploads.consume(socket)
          {:noreply, socket |> select_ticket(ticket.id) |> put_flash(:info, "Attachments added.")}

        {:error, _} ->
          {:noreply,
           put_flash(socket, :error, "Attachments could not be saved. Please try again.")}
      end
    else
      _ ->
        {:noreply,
         put_flash(socket, :error, "Select completed uploads for a ticket assigned to you.")}
    end
  end

  def handle_event("filter", %{"filters" => params}, socket) do
    {:noreply, push_patch(socket, to: ~p"/inbox?#{Map.take(params, ["q", "scope"])}")}
  end

  def handle_event("mode", %{"mode" => mode}, socket) when mode in ["public", "internal"] do
    {:noreply, socket |> assign(:mode, mode) |> message_form()}
  end

  def handle_event("validate-message", %{"message" => params}, socket) do
    {:noreply,
     assign(socket, :message_form, AshPhoenix.Form.validate(socket.assigns.message_form, params))}
  end

  def handle_event("send", %{"message" => params}, socket) do
    with {:ok, socket} <- fresh_ticket(socket) do
      socket = message_form(socket)

      case AshPhoenix.Form.submit(socket.assigns.message_form, params: Map.take(params, ["body"])) do
        {:ok, _} ->
          {:noreply,
           socket |> select_ticket(socket.assigns.ticket.id) |> put_flash(:info, "Message sent.")}

        {:error, form} ->
          {:noreply, assign(socket, :message_form, form)}
      end
    else
      _ -> {:noreply, denied(socket)}
    end
  end

  def handle_event("status", %{"status" => params}, socket),
    do: update_ticket(socket, :change_status, Map.take(params, ["status"]), :status_form)

  def handle_event("priority", %{"priority" => params}, socket),
    do: update_ticket(socket, :change_priority, Map.take(params, ["priority"]), :priority_form)

  def handle_event("assign", %{"assignment" => params}, socket),
    do:
      update_ticket(
        socket,
        :assign,
        Map.take(params, ["team_id", "assignee_id"]),
        :assignment_form
      )

  def handle_event("assignment-team", %{"assignment" => params}, socket) do
    with {:ok, socket} <- fresh_ticket(socket),
         true <- Ash.can?({socket.assigns.ticket, :assign}, socket.assigns.current_user) do
      params = Map.take(params, ["team_id", "assignee_id"])

      params =
        if params["team_id"] != socket.assigns.selected_team,
          do: Map.put(params, "assignee_id", ""),
          else: params

      {:noreply,
       socket
       |> assign(:selected_team, params["team_id"])
       |> assign(:assignee_options, assignees(params["team_id"]))
       |> assign(
         :assignment_form,
         AshPhoenix.Form.validate(socket.assigns.assignment_form, params)
       )}
    else
      _ -> {:noreply, denied(socket)}
    end
  end

  defp fresh_ticket(socket) do
    actor = Repo.get(User, socket.assigns.current_user.id)

    if Authorization.allowed?(actor, :read_tickets) and actor.role in [:admin, :agent] and
         socket.assigns.ticket do
      case Ash.get(Ticket, socket.assigns.ticket.id, actor: actor) do
        {:ok, %Ticket{} = ticket} ->
          {:ok, socket |> assign(:current_user, actor) |> assign(:ticket, load_labels(ticket))}

        _ ->
          {:error, :forbidden}
      end
    else
      {:error, :forbidden}
    end
  end

  defp denied(socket),
    do:
      socket
      |> put_flash(:error, "This action is not available.")
      |> push_navigate(to: ~p"/tickets")

  defp update_ticket(socket, action, params, key) do
    with {:ok, socket} <- fresh_ticket(socket),
         true <- Ash.can?({socket.assigns.ticket, action}, socket.assigns.current_user) do
      form =
        AshPhoenix.Form.for_update(socket.assigns.ticket, action,
          actor: socket.assigns.current_user,
          as: "change"
        )
        |> to_form()

      case AshPhoenix.Form.submit(form, params: params) do
        {:ok, ticket} ->
          {:noreply,
           socket
           |> put_flash(:info, "Ticket updated.")
           |> push_patch(to: ~p"/inbox?#{Map.put(socket.assigns.filters, "id", ticket.id)}")}

        {:error, form} ->
          {:noreply, assign(socket, key, to_form(form, as: form_name(key)))}
      end
    else
      _ -> {:noreply, denied(socket)}
    end
  end

  defp form_name(:status_form), do: "status"
  defp form_name(:priority_form), do: "priority"
  defp form_name(:assignment_form), do: "assignment"

  defp cancel_ticket_uploads(socket) do
    Enum.reduce(socket.assigns.uploads.attachments.entries, socket, fn entry, acc ->
      cancel_upload(acc, :attachments, entry.ref)
    end)
  end

  defp select_ticket(socket, nil), do: socket |> cancel_ticket_uploads() |> assign(:ticket, nil)

  defp select_ticket(socket, id) do
    socket =
      if socket.assigns.ticket && socket.assigns.ticket.id == id,
        do: socket,
        else: cancel_ticket_uploads(socket)

    actor = socket.assigns.current_user

    case Ash.get(Ticket, id, actor: actor) do
      {:ok, %Ticket{} = ticket} ->
        # Only identity labels on an already authorized ticket are loaded here.
        ticket = load_labels(ticket)

        messages =
          Message
          |> Ash.Query.filter(ticket_id == ^ticket.id)
          |> Ash.Query.sort(inserted_at: :asc, id: :asc)
          |> Ash.read!(actor: actor)

        attachments =
          Helpdesk.Support.Attachment
          |> Ash.Query.filter(ticket_id == ^ticket.id or message.ticket_id == ^ticket.id)
          |> Ash.Query.sort(created_at: :asc, id: :asc)
          |> Ash.read!(actor: actor)

        can_assign = Ash.can?({ticket, :assign}, actor)

        socket
        |> assign(:ticket, ticket)
        |> stream(:messages, messages, reset: true)
        |> stream(:attachments, attachments, reset: true)
        |> assign(:can_update, Ash.can?({ticket, :change_status}, actor))
        |> assign(:can_assign, can_assign)
        |> assign(
          :team_options,
          if(can_assign,
            do:
              Repo.all(from t in Team, where: t.active, order_by: t.name, select: {t.name, t.id}),
            else: []
          )
        )
        |> assign(:selected_team, ticket.team_id)
        |> assign(:assignee_options, if(can_assign, do: assignees(ticket.team_id), else: []))
        |> assign(
          :status_form,
          to_form(AshPhoenix.Form.for_update(ticket, :change_status, actor: actor, as: "status"))
        )
        |> assign(
          :priority_form,
          to_form(
            AshPhoenix.Form.for_update(ticket, :change_priority, actor: actor, as: "priority")
          )
        )
        |> assign(
          :assignment_form,
          to_form(AshPhoenix.Form.for_update(ticket, :assign, actor: actor, as: "assignment"))
        )
        |> message_form()

      _ ->
        socket |> assign(:ticket, nil) |> put_flash(:error, "Ticket not found or unavailable.")
    end
  end

  defp message_form(%{assigns: %{ticket: nil}} = socket), do: socket

  defp message_form(socket) do
    action = if socket.assigns.mode == "internal", do: :add_internal_note, else: :add_reply
    id = socket.assigns.ticket.id

    form =
      AshPhoenix.Form.for_create(Message, action,
        actor: socket.assigns.current_user,
        as: "message",
        prepare_params: fn params, _ ->
          Map.take(params, ["body"])
          |> Map.merge(%{"ticket_id" => id, "source" => "web", "body_format" => "plain_text"})
        end
      )

    assign(socket, :message_form, to_form(form))
  end

  # Limit bypassed reads to labels belonging to an authorized ticket.
  defp load_labels(ticket) do
    Ash.load!(
      ticket,
      [
        reporter: Ash.Query.select(User, [:id, :email, :first_name, :last_name]),
        assignee: Ash.Query.select(User, [:id, :email]),
        team: Ash.Query.select(Team, [:id, :name])
      ],
      authorize?: false
    )
  end

  defp assignees(nil), do: []
  defp assignees(""), do: []

  defp assignees(team_id) do
    case Ash.Type.cast_input(:uuid, team_id) do
      {:ok, id} ->
        Repo.all(
          from u in User,
            join: m in TeamMembership,
            on: m.user_id == u.id,
            where: m.team_id == ^id and u.role in [:admin, :agent] and u.status == :active,
            order_by: u.email,
            select: {u.email, u.id}
        )
        |> Enum.map(fn {email, id} -> {to_string(email), id} end)

      _ ->
        []
    end
  end

  defp options(values), do: Enum.map(values, &{humanize(&1), &1})
  defp humanize(nil), do: "None"

  defp humanize(value),
    do: value |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()

  defp date(value), do: Calendar.strftime(value, "%b %d, %H:%M UTC")

  defp presign_upload(entry, socket) do
    case upload_access(socket) do
      {:ok, _ticket, _actor} -> TicketUploads.presign(entry, socket)
      _ -> {:error, %{reason: "You must be assigned to this ticket to upload files."}, socket}
    end
  end

  defp upload_access(socket) do
    actor = Repo.get(User, socket.assigns.current_user.id)

    with true <- Authorization.allowed?(actor, :read_tickets),
         %Ticket{id: id} <- socket.assigns.ticket,
         {:ok, %Ticket{} = ticket} <- Ash.get(Ticket, id, actor: actor),
         true <- actor.role == :admin or (actor.role == :agent and ticket.assignee_id == actor.id) do
      {:ok, ticket, actor}
    else
      _ -> {:error, :forbidden}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      notification_count={@notification_count}
      flash={@flash}
      current_scope={@current_scope}
      current_page={:inbox}
    >
      <section id="agent-dashboard">
        <header class="mb-6 flex flex-wrap items-end justify-between gap-4">
          <div>
            <p class="text-sm font-semibold text-sky-600">Support workspace</p>
            <h1 class="mt-1 text-3xl font-black">Team inbox</h1>
            <p class="mt-2 text-slate-500">{@ticket_count} tickets in this view.</p>
          </div>
          <.link navigate={~p"/ticket/new"} class="btn border-0 bg-sky-600 text-white">
            <.icon name="hero-plus" class="size-4" />New ticket
          </.link>
        </header>
        <div class="mb-5 grid grid-cols-2 gap-3 xl:grid-cols-4">
          <.stat
            label="Unassigned"
            value={@counts.unassigned}
            detail="Active tickets without an assignee"
          />
          <.stat label="Open" value={@counts.open} detail="New, open or waiting on support" />
          <.stat label="Waiting" value={@counts.waiting} detail="On customers" />
          <.stat label="My workload" value={@counts.mine} detail="Active tickets assigned to you" />
        </div>
        <div class="grid min-h-[620px] overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-sm xl:grid-cols-[280px_minmax(0,1fr)_240px]">
          <section aria-label="Inbox" class="border-r border-slate-200">
            <.form
              for={@filter_form}
              id="inbox-filters"
              phx-change="filter"
              phx-submit="filter"
              class="border-b border-slate-100 p-3"
            >
              <.input
                field={@filter_form[:q]}
                type="search"
                label="Search inbox"
                phx-debounce="300"
                placeholder="Subject or ticket number"
              />
              <.input
                field={@filter_form[:scope]}
                type="select"
                label="Queue"
                options={[
                  {"All tickets", "all"},
                  {"My tickets", "mine"},
                  {"My teams", "team"},
                  {"Unassigned", "unassigned"}
                ]}
              />
            </.form>
            <div
              id="inbox-tickets"
              phx-update="stream"
              class="max-h-96 divide-y divide-slate-100 overflow-y-auto xl:max-h-[650px]"
            >
              <p id="inbox-empty" class="hidden only:block p-6 text-sm text-slate-500">
                No tickets match this queue.
              </p>
              <.link
                :for={{id, ticket} <- @streams.tickets}
                id={id}
                patch={~p"/inbox?#{Map.put(@filters, "id", ticket.id)}"}
                aria-current={@ticket && @ticket.id == ticket.id && "true"}
                class={[
                  "block p-4 hover:bg-slate-50",
                  @ticket && @ticket.id == ticket.id && "border-l-4 border-sky-600 bg-sky-50"
                ]}
              >
                <h2 class="break-words font-bold">{ticket.title}</h2>
                <p class="mt-1 truncate text-xs text-slate-500">{ticket.ticket_number}</p>
                <div class="mt-3 flex flex-wrap gap-2">
                  <span class="badge badge-sm badge-outline">{humanize(ticket.priority)}</span><span class="badge badge-sm badge-ghost">{humanize(ticket.status)}</span>
                </div>
              </.link>
            </div>
          </section>
          <div
            :if={!@ticket}
            id="inbox-no-selection"
            class="p-10 text-center text-slate-500 xl:col-span-2"
          >
            Select a ticket to read the conversation.
          </div>
          <section :if={@ticket} id="agent-conversation" class="min-w-0">
            <header class="border-b border-slate-100 p-5">
              <.link
                id="view-full-ticket"
                navigate={~p"/tickets/#{@ticket.id}"}
                class="text-xs text-sky-700"
              >
                {@ticket.ticket_number} · View full ticket
              </.link>
              <h2 class="mt-2 break-words text-xl font-black">
                <.link navigate={~p"/tickets/#{@ticket.id}"} class="hover:underline">
                  {@ticket.title}
                </.link>
              </h2>
            </header>
            <div class="max-h-[550px] overflow-y-auto bg-slate-50 p-5">
              <article class="mb-5 rounded-2xl bg-white p-4 shadow-sm">
                <h3 class="mb-2 font-bold">Original request</h3>
                <p class="whitespace-pre-wrap break-words text-sm leading-6">{@ticket.description}</p>
              </article>
              <section
                aria-labelledby="inbox-attachments-heading"
                class="mb-5 rounded-2xl border border-slate-200 bg-white p-4"
              >
                <h3 id="inbox-attachments-heading" class="mb-3 font-bold">Attachments</h3>
                <div id="inbox-attachments" phx-update="stream" class="space-y-3">
                  <p id="inbox-attachments-empty" class="hidden only:block text-sm text-slate-500">
                    No attachments available.
                  </p>
                  <div :for={{id, attachment} <- @streams.attachments} id={id}>
                    <.link
                      href={~p"/attachments/#{attachment.id}/download"}
                      class="inline-flex items-center gap-2 break-all text-sm text-sky-700 hover:underline"
                    >
                      <.icon name="hero-paper-clip" class="size-4 shrink-0" />{attachment.file_name}
                    </.link>
                    <p class="text-xs text-slate-500">
                      {attachment.content_type} · {attachment.byte_size} bytes · {if attachment.message_id,
                        do: "Message attachment",
                        else: "Ticket attachment"}
                    </p>
                  </div>
                </div>
              </section>
              <.form
                :if={@current_user.role == :admin or @ticket.assignee_id == @current_user.id}
                for={@upload_form}
                id="agent-attachments-form"
                phx-change="validate-uploads"
                phx-submit="save-uploads"
                class="mb-5 rounded-xl border border-slate-200 bg-white p-4"
              >
                <HelpdeskWeb.AttachmentUpload.picker upload={@uploads.attachments} />
                <button
                  id="save-ticket-attachments"
                  disabled={@uploads.attachments.entries == []}
                  phx-disable-with="Saving…"
                  class="btn btn-sm btn-primary mt-3"
                >
                  Save attachments
                </button>
              </.form>
              <div id="agent-messages" phx-update="stream" class="space-y-5">
                <article
                  :for={{id, message} <- @streams.messages}
                  id={id}
                  class={[
                    "rounded-xl border p-4",
                    if(message.message_type == :internal_note,
                      do: "border-amber-200 bg-amber-50",
                      else: "border-slate-200 bg-white"
                    )
                  ]}
                >
                  <div class="mb-2 flex flex-wrap justify-between gap-2 text-xs">
                    <strong>
                      {if message.message_type == :internal_note, do: "Internal note · ", else: ""}{cond do
                        message.user_id == @current_user.id -> "You"
                        message.user_id == @ticket.reporter_id -> "Customer"
                        true -> "Support"
                      end}
                    </strong>
                    <time>{date(message.inserted_at)}</time>
                  </div>
                  <p class="whitespace-pre-wrap break-words text-sm leading-6">{message.body}</p>
                </article>
              </div>
            </div>
            <div class="border-t border-slate-200 p-4">
              <div class="mb-3 flex gap-2" aria-label="Message visibility">
                <button
                  id="public-mode"
                  phx-click="mode"
                  phx-value-mode="public"
                  aria-pressed={@mode == "public"}
                  class={["btn btn-sm", @mode == "public" && "bg-sky-100"]}
                >
                  Public reply
                </button>
                <button
                  id="internal-mode"
                  disabled={!@can_update}
                  phx-click="mode"
                  phx-value-mode="internal"
                  aria-pressed={@mode == "internal"}
                  class={["btn btn-sm", @mode == "internal" && "bg-amber-100"]}
                >
                  Internal note
                </button>
              </div>
              <.form
                for={@message_form}
                id="agent-message-form"
                phx-change="validate-message"
                phx-submit="send"
              >
                <.input
                  field={@message_form[:body]}
                  type="textarea"
                  label={
                    if @mode == "internal",
                      do: "Internal note — visible to authorized staff",
                      else: "Public reply — visible to the customer"
                  }
                  rows="4"
                  required
                  maxlength="10000"
                />
                <button
                  id="send-agent-message"
                  phx-disable-with="Sending…"
                  class="btn border-0 bg-sky-600 text-white"
                >
                  {if @mode == "internal", do: "Add note", else: "Send reply"}
                </button>
              </.form>
            </div>
          </section>
          <aside :if={@ticket} id="agent-ticket-details" class="border-l border-slate-200 p-5">
            <h2 class="mb-5 text-xs font-bold uppercase tracking-widest text-slate-400">
              Ticket details
            </h2>
            <.form :if={@can_update} for={@status_form} id="agent-status" phx-submit="status">
              <.input
                field={@status_form[:status]}
                type="select"
                label="Status"
                options={@status_options}
              /><button class="btn btn-sm mb-4" phx-disable-with="Saving…">Update status</button>
            </.form>
            <.form :if={@can_update} for={@priority_form} id="agent-priority" phx-submit="priority">
              <.input
                field={@priority_form[:priority]}
                type="select"
                label="Priority"
                options={@priority_options}
              /><button class="btn btn-sm mb-4" phx-disable-with="Saving…">Update priority</button>
            </.form>
            <p :if={!@can_update} class="mb-5 text-sm text-slate-500">
              {humanize(@ticket.status)} · {humanize(@ticket.priority)} priority. Updates require assignment or team access.
            </p>
            <.form
              :if={@can_assign}
              for={@assignment_form}
              id="agent-assignment"
              phx-change="assignment-team"
              phx-submit="assign"
            >
              <.input
                field={@assignment_form[:team_id]}
                type="select"
                label="Team"
                prompt="No team"
                options={@team_options}
              /><.input
                field={@assignment_form[:assignee_id]}
                type="select"
                label="Assignee"
                prompt="Unassigned"
                options={@assignee_options}
              /><button class="btn btn-sm" phx-disable-with="Saving…">Save assignment</button>
            </.form>
            <p :if={!@can_assign} class="text-sm text-slate-500">
              {if @ticket.team, do: @ticket.team.name, else: "No team"}<br />{if @ticket.assignee,
                do: @ticket.assignee.email,
                else: "Unassigned"}
            </p>
            <div :if={@ticket.reporter} class="mt-6 border-t border-slate-100 pt-5">
              <p class="mb-3 text-xs font-bold uppercase text-slate-400">Customer</p>
              <p class="text-sm font-bold">
                {@ticket.reporter.first_name} {@ticket.reporter.last_name}
              </p>
              <p class="break-all text-xs text-slate-500">{@ticket.reporter.email}</p>
            </div>
          </aside>
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :detail, :string, required: true

  defp stat(assigns) do
    ~H"""
    <div class="rounded-2xl border border-slate-200 bg-white p-4">
      <p class="text-sm text-slate-500">{@label}</p>
      <p class="mt-1 text-2xl font-bold">{@value}</p>
      <p class="mt-2 text-xs text-slate-400">{@detail}</p>
    </div>
    """
  end
end
