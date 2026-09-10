defmodule HelpdeskWeb.HelpdeskLive.Tickets.View do
  use HelpdeskWeb, :live_view
  alias Helpdesk.Support.{Ticket, Message}
  alias Helpdesk.Accounts.Authorization
  require Ash.Query
  on_mount {HelpdeskWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    if (actor.role == :customer or socket.assigns.live_action == :show) and
         Authorization.allowed?(actor, :read_tickets) do
      {:ok,
       socket
       |> assign(:current_scope, %{user: actor})
       |> assign(:ticket, nil)
       |> assign(:reply_form, nil)
       |> assign(:search_form, to_form(%{"q" => ""}, as: :search))
       |> stream(:recent, [])
       |> stream(:messages, [])
       |> stream(:attachments, [])}
    else
      {:ok, redirect(socket, to: ~p"/tickets")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns.live_action do
      :show ->
        case accessible_ticket(params["id"], socket.assigns.current_user) do
          {:ok, ticket} ->
            {:noreply,
             socket
             |> assign(:page_title, ticket.title)
             |> assign(:current_page, :tickets)
             |> assign(:ticket, ticket)
             |> reply_form(ticket)
             |> load_messages(ticket)}

          _ ->
            {:noreply, unavailable(socket)}
        end
    end
  end

  @impl true
  def handle_event("search", %{"search" => %{"q" => query}}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/tickets?#{%{q: query}}")}
  end

  def handle_event("validate-reply", %{"reply" => params}, socket) do
    {:noreply,
     assign(socket, :reply_form, AshPhoenix.Form.validate(socket.assigns.reply_form, params))}
  end

  def handle_event("send-reply", %{"reply" => params}, socket) do
    actor = Helpdesk.Repo.get(Helpdesk.Accounts.User, socket.assigns.current_user.id)

    with true <- Authorization.allowed?(actor, :add_public_replies),
         {:ok, ticket} <- accessible_ticket(socket.assigns.ticket.id, actor) do
      socket = assign(socket, :current_user, actor) |> reply_form(ticket)

      case AshPhoenix.Form.submit(socket.assigns.reply_form, params: params) do
        {:ok, _message} ->
          {:noreply,
           socket
           |> reply_form(ticket)
           |> load_messages(ticket)
           |> put_flash(:info, "Your reply has been sent.")}

        {:error, form} ->
          {:noreply, assign(socket, :reply_form, form)}
      end
    else
      _ -> {:noreply, unavailable(socket)}
    end
  end

  defp accessible_ticket(id, actor) do
    Ticket
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, nil} ->
        {:error, :not_found}

      {:ok, ticket} ->
        {:ok,
         Ash.load!(
           ticket,
           [
             reporter: Ash.Query.select(Helpdesk.Accounts.User, [:id, :email]),
             assignee: Ash.Query.select(Helpdesk.Accounts.User, [:id, :email]),
             team: Ash.Query.select(Helpdesk.Support.Team, [:id, :name])
           ],
           authorize?: false
         )}

      result ->
        result
    end
  end

  defp unavailable(socket),
    do:
      socket
      |> put_flash(:error, "That ticket is not available.")
      |> push_navigate(to: ~p"/tickets")

  defp load_messages(socket, ticket) do
    messages =
      Message
      |> Ash.Query.filter(ticket_id == ^ticket.id)
      |> Ash.Query.sort(inserted_at: :asc, id: :asc)
      |> Ash.read!(actor: socket.assigns.current_user)

    attachments =
      Helpdesk.Support.Attachment
      |> Ash.Query.filter(ticket_id == ^ticket.id or message.ticket_id == ^ticket.id)
      |> Ash.Query.sort(created_at: :asc, id: :asc)
      |> Ash.read!(actor: socket.assigns.current_user)

    socket
    |> stream(:messages, messages, reset: true)
    |> stream(:attachments, attachments, reset: true)
  end

  defp reply_form(socket, ticket) do
    form =
      AshPhoenix.Form.for_create(Message, :add_reply,
        actor: socket.assigns.current_user,
        as: "reply",
        prepare_params: fn params, _ ->
          params
          |> Map.take(["body"])
          |> Map.put("ticket_id", ticket.id)
          |> Map.put("body_format", "plain_text")
          |> Map.put("source", "web")
        end
      )

    assign(socket, :reply_form, to_form(form))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      notification_count={@notification_count}
      flash={@flash}
      current_scope={@current_scope}
      current_page={@current_page}
    >
      <section :if={@live_action == :overview} id="customer-home">
        <header class="mb-8 flex flex-wrap items-end justify-between gap-4">
          <div>
            <p class="text-sm font-semibold text-sky-600">
              {Calendar.strftime(Date.utc_today(), "%A, %B %d")}
            </p>
            <h1 class="mt-1 text-3xl font-black tracking-tight">
              How can we help, {@current_user.first_name}?
            </h1>
            <p class="mt-2 text-slate-500">
              Track your requests or find guidance in the help center.
            </p>
          </div>
          <.link
            navigate={~p"/ticket/new"}
            class="btn border-0 bg-sky-600 text-white hover:bg-sky-700"
          >
            <.icon name="hero-plus" class="size-4" />Submit a ticket
          </.link>
        </header>
        <.form
          for={@search_form}
          id="customer-search"
          phx-submit="search"
          class="flex items-end gap-3 rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"
        >
          <div class="flex-1">
            <.input
              field={@search_form[:q]}
              type="search"
              label="Search your tickets"
              placeholder="Search by subject or ticket number"
            />
          </div>
          <button class="btn mb-2 border-0 bg-sky-600 text-white" type="submit">Search</button>
        </.form>
        <div id="recent-tickets" phx-update="stream" class="mt-8 grid gap-4 md:grid-cols-3">
          <div
            id="recent-empty"
            class="hidden only:block rounded-2xl border border-dashed border-slate-300 p-8 text-slate-500 md:col-span-3"
          >
            You haven't submitted any tickets yet. Create a request when you need a hand.
          </div>
          <.link
            :for={{id, ticket} <- @streams.recent}
            id={id}
            navigate={~p"/tickets/#{ticket.id}"}
            class="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm transition hover:border-sky-300"
          >
            <div class="flex items-start justify-between gap-2">
              <span class="grid size-10 place-items-center rounded-xl bg-sky-50 text-sky-600">
                <.icon name="hero-ticket" class="size-5" />
              </span>
              <.status value={ticket.status} />
            </div>
            <p class="mt-4 text-xs text-slate-500">{ticket.ticket_number}</p>
            <h2 class="mt-1 break-words font-bold">{ticket.title}</h2>
            <p class="mt-2 text-xs text-slate-500">Updated {date(ticket.updated_at)}</p>
          </.link>
        </div>
        <div class="mt-8 grid gap-6 lg:grid-cols-[1.4fr_1fr]">
          <section class="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
            <div class="mb-4 flex items-center justify-between">
              <h2 class="text-lg font-black">Popular help topics</h2>
              <.link navigate={~p"/help"} class="text-sm font-semibold text-sky-600">View all</.link>
            </div>
            <.topic
              href={~p"/help#account"}
              icon="hero-key"
              title="Account access and security"
              description="Getting help with sign-in and permissions"
            />
            <.topic
              href={~p"/help#billing"}
              icon="hero-credit-card"
              title="Billing and subscriptions"
              description="What to include in a billing request"
            />
            <.topic
              href={~p"/help#integrations"}
              icon="hero-puzzle-piece"
              title="Apps and integrations"
              description="Reporting connection and integration issues"
            />
          </section>
          <section class="rounded-2xl bg-slate-900 p-6 text-white">
            <.icon name="hero-lifebuoy" class="size-8 text-sky-300" />
            <h2 class="mt-5 text-2xl font-black">Still need a hand?</h2>
            <p class="mt-2 text-sm leading-6 text-slate-300">
              Tell our support team what happened. Include steps to reproduce and any error message you saw.
            </p>
            <.link navigate={~p"/ticket/new"} class="btn mt-6 border-0 bg-white text-slate-900">
              Create a request
            </.link>
          </section>
        </div>
      </section>
      <section :if={@live_action == :help} id="customer-help" class="mx-auto max-w-4xl">
        <header class="mb-8 text-center">
          <p class="text-sm font-semibold text-sky-600">Help center</p>
          <h1 class="mt-3 text-4xl font-black">A little guidance to get started</h1>
          <p class="mt-3 text-slate-500">Find out what to include so our team can help you.</p>
        </header>
        <div class="space-y-5">
          <.guide id="account" title="Account access and security">
            If you cannot sign in, use the password reset link on the sign-in page. For access or permission issues, tell us which page you need and the error you see. Never include passwords or verification codes in your ticket.
          </.guide>
          <.guide id="billing" title="Billing and subscriptions">
            Choose Billing when creating your request. Include the invoice reference, the charge date, and what you expected to see. Do not include your full payment card details.
          </.guide>
          <.guide id="integrations" title="Apps and integrations">
            Tell us which service you are connecting, the steps you took, and the exact error message. Remove API keys and other secrets before sharing logs.
          </.guide>
          <.guide id="tracking" title="Track your request">
            Open My tickets to see the current status and read public replies from support. Open a ticket to send more information. Waiting on customer means the support team needs your response.
          </.guide>
        </div>
        <.link navigate={~p"/ticket/new"} class="btn mt-6 border-0 bg-sky-600 text-white">
          Submit a ticket
        </.link>
      </section>
      <section :if={@live_action == :show and @ticket} id="customer-detail" class="mx-auto max-w-4xl">
        <.link
          navigate={~p"/tickets"}
          class="mb-5 inline-flex items-center gap-2 text-sm text-slate-500"
        >
          <.icon name="hero-arrow-left" class="size-4" />My tickets
        </.link>
        <div class="mb-2 flex flex-wrap items-center gap-2">
          <.status value={@ticket.status} />
          <span class="text-sm text-slate-500">
            {@ticket.ticket_number}
          </span>
        </div>
        <h1 class="break-words text-3xl font-black tracking-tight">{@ticket.title}</h1>
        <p class="mt-2 text-sm text-slate-500">
          Opened {date(@ticket.inserted_at)} · {humanize(@ticket.category)} · {humanize(
            @ticket.priority
          )} priority
        </p>
        <dl
          id="ticket-details"
          class="mt-5 grid gap-3 rounded-2xl border border-slate-200 bg-white p-5 text-sm sm:grid-cols-2"
        >
          <div>
            <dt class="text-slate-500">Reporter</dt>
            <dd>{if @ticket.reporter, do: @ticket.reporter.email, else: "Unavailable"}</dd>
          </div>
          <div>
            <dt class="text-slate-500">Assignee</dt>
            <dd>{if @ticket.assignee, do: @ticket.assignee.email, else: "Unassigned"}</dd>
          </div>
          <div>
            <dt class="text-slate-500">Team</dt>
            <dd>{if @ticket.team, do: @ticket.team.name, else: "No team"}</dd>
          </div>
          <div>
            <dt class="text-slate-500">Source</dt>
            <dd>{humanize(@ticket.source)}</dd>
          </div>
          <div>
            <dt class="text-slate-500">Updated</dt>
            <dd>{date(@ticket.updated_at)}</dd>
          </div>
          <div>
            <dt class="text-slate-500">Due</dt>
            <dd>{if @ticket.due_at, do: date(@ticket.due_at), else: "Not set"}</dd>
          </div>
          <div>
            <dt class="text-slate-500">Resolved</dt>
            <dd>{if @ticket.resolved_at, do: date(@ticket.resolved_at), else: "Not resolved"}</dd>
          </div>
          <div>
            <dt class="text-slate-500">Closed</dt>
            <dd>{if @ticket.closed_at, do: date(@ticket.closed_at), else: "Not closed"}</dd>
          </div>
        </dl>
        <section class="mt-5 rounded-2xl border border-slate-200 bg-white p-5">
          <h2 class="mb-3 font-bold">Attachments</h2>
          <div id="ticket-attachments" phx-update="stream" class="space-y-3">
            <p id="attachments-empty" class="hidden only:block text-sm text-slate-500">
              No attachments.
            </p>
            <div :for={{id, attachment} <- @streams.attachments} id={id}>
              <.link
                href={~p"/attachments/#{attachment.id}/download"}
                class="inline-flex items-center gap-2 break-all text-sm text-sky-700"
              >
                <.icon name="hero-paper-clip" class="size-4 shrink-0" />{attachment.file_name}
              </.link>
              <p class="text-xs text-slate-500">
                {attachment.content_type} · {attachment.byte_size} bytes {if attachment.message_id,
                  do: "· Message attachment",
                  else: "· Ticket attachment"}
              </p>
            </div>
          </div>
        </section>
        <article id="original-request" class="mt-7 rounded-2xl border border-slate-200 bg-white p-5">
          <h2 class="mb-3 font-bold">Original request</h2>
          <p class="whitespace-pre-wrap break-words leading-7">{@ticket.description}</p>
        </article>
        <div id="conversation" phx-update="stream" class="mt-5 space-y-5">
          <article
            :for={{id, message} <- @streams.messages}
            id={id}
            class={[
              "rounded-2xl border p-5",
              if(message.user_id == @current_user.id,
                do: "border-slate-200 bg-white",
                else: "border-sky-100 bg-sky-50"
              )
            ]}
          >
            <div class="mb-3 flex flex-wrap justify-between gap-2">
              <h2 class="font-bold">
                {if message.message_type == :internal_note, do: "Internal note · ", else: ""}
                {cond do
                  message.user_id == @current_user.id -> "You"
                  message.user_id == @ticket.reporter_id -> "Customer"
                  true -> "Support"
                end}
              </h2>
              <time datetime={DateTime.to_iso8601(message.inserted_at)} class="text-xs text-slate-500">
                {date(message.inserted_at)}
              </time>
            </div>
            <p class="whitespace-pre-wrap break-words leading-7">{message.body}</p>
          </article>
        </div>
        <.form
          for={@reply_form}
          id="customer-reply"
          phx-change="validate-reply"
          phx-submit="send-reply"
          class="mt-6 rounded-2xl border border-slate-200 bg-white p-5 shadow-sm"
        >
          <.input
            field={@reply_form[:body]}
            type="textarea"
            label="Write a reply"
            rows="4"
            required
            maxlength="10000"
            placeholder="Share an update or answer the support team's questions…"
          />
          <div class="mt-3 flex justify-end border-t border-slate-100 pt-3">
            <button
              id="send-reply"
              type="submit"
              phx-disable-with="Sending…"
              class="btn border-0 bg-sky-600 text-white hover:bg-sky-700"
            >
              Send reply<.icon name="hero-paper-airplane" class="size-4" />
            </button>
          </div>
        </.form>
      </section>
    </Layouts.app>
    """
  end

  attr :value, :atom, required: true

  defp status(assigns) do
    ~H"""
    <span class={[
      "rounded-full px-2.5 py-1 text-xs font-semibold",
      if(@value in [:resolved, :closed],
        do: "bg-emerald-50 text-emerald-700",
        else: "bg-sky-50 text-sky-700"
      )
    ]}>
      {humanize(@value)}
    </span>
    """
  end

  attr :href, :string, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true

  defp topic(assigns) do
    ~H"""
    <.link navigate={@href} class="flex items-center gap-3 border-t border-slate-100 py-4">
      <.icon name={@icon} class="size-5 shrink-0 text-sky-600" />
      <div>
        <p class="font-semibold">{@title}</p>
        <p class="text-sm text-slate-500">{@description}</p>
      </div>
      <.icon name="hero-chevron-right" class="ml-auto size-4 shrink-0" />
    </.link>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  defp guide(assigns) do
    ~H"""
    <section id={@id} class="scroll-mt-24 rounded-2xl border border-slate-200 bg-white p-6">
      <h2 class="mb-3 text-lg font-bold">{@title}</h2>
      <p class="leading-7 text-slate-600">{render_slot(@inner_block)}</p>
    </section>
    """
  end

  defp date(value), do: Calendar.strftime(value, "%b %d, %Y · %H:%M UTC")
  defp humanize(nil), do: "General"

  defp humanize(value),
    do: value |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
end
