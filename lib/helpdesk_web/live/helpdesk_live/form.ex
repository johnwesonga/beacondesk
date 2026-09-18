defmodule HelpdeskWeb.HelpdeskLive.Form do
  alias HelpdeskWeb.TicketUploads
  alias Helpdesk.Support.Team
  alias Helpdesk.Accounts.User
  alias Helpdesk.Accounts.Authorization
  use HelpdeskWeb, :live_view

  alias Helpdesk.Support.Ticket
  require Ash.Query

  on_mount {HelpdeskWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(params, _session, socket) do
    current_user = socket.assigns.current_user
    ticket = load_ticket(params, current_user)
    selected_team_id = if(ticket, do: ticket.team_id, else: nil)
    can_assign? = Authorization.allowed?(current_user, :assign_tickets)

    team_options =
      if can_assign? do
        Team
        |> Ash.Query.filter(active == true)
        |> Ash.Query.sort(name: :asc)
        |> Ash.Query.select([:name, :id])
        |> Ash.read!(actor: current_user)
        |> Enum.map(&{&1.name, &1.id})
      else
        []
      end

    {:ok,
     socket
     |> assign(:page_title, if(ticket, do: "Edit ticket", else: "New ticket"))
     |> assign(:current_scope, %{user: current_user})
     |> assign(:created_ticket, nil)
     |> assign(:priority_options, enum_options([:low, :medium, :high, :critical]))
     |> assign(:category_options, enum_options([:billing, :bug, :feature, :howto]))
     |> assign(:ticket, ticket)
     |> assign(:can_assign?, can_assign?)
     |> assign(
       :can_pick_customer?,
       is_nil(ticket) and Authorization.allowed?(current_user, :open_tickets_for_customers)
     )
     |> assign(:selected_customer, nil)
     |> assign(:customer_search_form, to_form(%{"query" => ""}, as: :customer_search))
     |> assign(:customer_search_started?, false)
     |> stream(:customers, [])
     |> assign(:team_options, team_options)
     |> assign(:selected_team_id, selected_team_id)
     |> assign(
       :assignee_options,
       if(can_assign?, do: assignees(selected_team_id, current_user), else: [])
     )
     |> assign(:uploaded_files, [])
     |> TicketUploads.allow()
     |> assign_form()}
  end

  @impl true
  def handle_event("validate", %{"ticket" => params}, socket) do
    team_id = Map.get(params, "team_id", socket.assigns.selected_team_id)
    team_id = if team_id == "", do: nil, else: team_id

    {socket, params} =
      if socket.assigns.can_assign? and team_id != socket.assigns.selected_team_id do
        socket =
          socket
          |> assign(:selected_team_id, team_id)
          |> assign(:assignee_options, assignees(team_id, socket.assigns.current_user))

        {socket, Map.put(params, "assignee_id", "")}
      else
        {socket, params}
      end

    form = AshPhoenix.Form.validate(socket.assigns.form, customer_params(socket, params))
    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("search-customers", %{"customer_search" => %{"query" => query}}, socket) do
    if socket.assigns.can_pick_customer? and is_nil(socket.assigns.selected_customer) do
      query = query |> String.trim() |> String.slice(0, 100)
      started? = String.length(query) >= 2
      customers = if started?, do: search_customers(query, socket.assigns.current_user), else: []

      {:noreply,
       socket
       |> assign(:customer_search_form, to_form(%{"query" => query}, as: :customer_search))
       |> assign(:customer_search_started?, started?)
       |> stream(:customers, customers, reset: true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("select-customer", %{"id" => id}, socket) do
    with true <- socket.assigns.can_pick_customer?,
         {:ok, id} <- Ash.Type.cast_input(:uuid, id),
         {:ok, %User{} = customer} <-
           User
           |> Ash.Query.filter(id == ^id)
           |> Ash.read_one(action: :list_customers, actor: socket.assigns.current_user) do
      {:noreply, select_customer(socket, customer)}
    else
      _ ->
        {:noreply,
         put_flash(socket, :error, "Select an active customer from the search results.")}
    end
  end

  def handle_event("clear-customer", _params, socket) do
    if socket.assigns.can_pick_customer? do
      {:noreply, select_customer(socket, nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :attachments, ref)}
  end

  def handle_event("save", %{"ticket" => params}, socket) do
    {completed, in_progress} = uploaded_entries(socket, :attachments)

    if in_progress != [] or upload_errors(socket.assigns.uploads.attachments) != [] do
      {:noreply,
       put_flash(socket, :error, "Please finish or remove failed uploads before saving.")}
    else
      if socket.assigns.can_pick_customer? and is_nil(socket.assigns.selected_customer) and
           socket.assigns.customer_search_form[:query].value != "" do
        {:noreply,
         put_flash(
           socket,
           :error,
           "Select a customer or clear the customer search before saving."
         )}
      else
        save_ticket(socket, customer_params(socket, params), completed)
      end
    end
  end

  defp save_ticket(socket, params, entries) do
    result =
      Helpdesk.Repo.transaction(fn ->
        case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
          {:ok, ticket} ->
            TicketUploads.persist!(ticket, entries, socket.assigns.current_user)

            ticket

          {:error, form} ->
            Helpdesk.Repo.rollback({:form, form})
        end
      end)

    case result do
      {:ok, ticket} ->
        TicketUploads.consume(socket)

        socket =
          if socket.assigns.ticket do
            socket
            |> put_flash(:info, "Ticket updated")
            |> assign(:created_ticket, ticket)
          else
            socket
            |> put_flash(:info, "Ticket #{ticket.ticket_number} created.")
            |> push_navigate(to: ~p"/tickets")
          end

        {:noreply, socket}

      {:error, {:form, form}} ->
        {:noreply, assign(socket, :form, form)}

      {:error, :attachment_failed} ->
        {:noreply, put_flash(socket, :error, "Attachments could not be saved. Please try again.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      notification_count={@notification_count}
      current_page={:new_ticket}
      flash={@flash}
      current_scope={@current_scope}
    >
      <div class="mx-auto max-w-3xl space-y-8">
        <.link navigate={~p"/tickets"} class="inline-flex items-center gap-2 text-sm text-slate-500">
          <.icon name="hero-arrow-left" class="size-4" />My tickets
        </.link>
        <header class="space-y-2">
          <p class="text-sm font-semibold uppercase tracking-wide text-primary">Help center</p>
          <h1 class="text-3xl font-semibold tracking-tight text-base-content">
            {if @current_user.role == :customer and !@ticket,
              do: "Submit a support request",
              else: @page_title}
          </h1>
          <p class="max-w-xl text-base-content/70">
            Tell us what happened and include the details our support team will need to help.
          </p>
        </header>

        <div
          :if={@created_ticket}
          id="ticket-created"
          role="status"
          class="alert alert-success"
        >
          <.icon name="hero-check-circle" class="size-5 shrink-0" />
          <div>
            <p class="font-semibold">Your ticket has been submitted.</p>
            <p class="text-sm">Reference: {@created_ticket.ticket_number}</p>
          </div>
        </div>

        <.form
          for={@form}
          id="ticket-form"
          phx-change="validate"
          phx-submit="save"
          class="rounded-2xl border border-base-300 bg-base-100 p-6 shadow-sm"
        >
          <section
            :if={@can_pick_customer?}
            id="ticket-customer-picker"
            class="mb-5 rounded-xl border border-slate-200 bg-slate-50 p-4"
          >
            <h2 class="text-sm font-bold">Customer</h2>
            <%= if @selected_customer do %>
              <div id="selected-customer" class="mt-3 flex items-center justify-between gap-3">
                <p class="text-sm">
                  <span class="font-semibold">
                    {@selected_customer.first_name} {@selected_customer.last_name}
                  </span>
                  <span class="block text-slate-500">{@selected_customer.email}</span>
                </p>
                <button
                  id="clear-customer"
                  type="button"
                  phx-click="clear-customer"
                  class="btn btn-sm btn-ghost"
                >
                  Change customer
                </button>
              </div>
              <input type="hidden" name={@form[:customer_id].name} value={@selected_customer.id} />
              <p :for={error <- @form[:customer_id].errors} class="mt-2 text-sm text-error">
                {translate_error(error)}
              </p>
            <% else %>
              <.input
                field={@customer_search_form[:query]}
                id="customer-search"
                type="search"
                placeholder="Type at least 2 characters"
                autocomplete="off"
                maxlength="100"
                phx-change="search-customers"
                phx-debounce="300"
                aria-controls="customer-results"
              />
              <p class="text-xs text-slate-500">Leave blank to create a ticket for yourself.</p>
              <div id="customer-results" phx-update="stream" class="mt-2 space-y-1">
                <p
                  id="customer-results-empty"
                  class="hidden only:block text-sm text-slate-500"
                  role="status"
                >
                  {if @customer_search_started?,
                    do: "No active customers found.",
                    else: "Search to find an active customer."}
                </p>
                <button
                  :for={{id, customer} <- @streams.customers}
                  id={id}
                  type="button"
                  phx-click="select-customer"
                  phx-value-id={customer.id}
                  class="block w-full rounded-lg border border-slate-200 bg-white p-3 text-left text-sm hover:bg-sky-50 focus-visible:outline-2 focus-visible:outline-sky-600"
                >
                  <span class="font-semibold">{customer.first_name} {customer.last_name}</span>
                  <span class="block text-slate-500">{customer.email}</span>
                </button>
              </div>
              <button
                :if={@customer_search_form[:query].value != ""}
                id="clear-customer-search"
                type="button"
                phx-click="clear-customer"
                class="btn btn-sm btn-ghost mt-2"
              >
                Clear search
              </button>
            <% end %>
          </section>
          <div class="space-y-5">
            <.input
              field={@form[:title]}
              type="text"
              label="What do you need help with?"
              placeholder="Briefly describe the issue"
              autocomplete="off"
              required
            />

            <.input
              field={@form[:description]}
              type="textarea"
              label="Describe what happened"
              placeholder="What happened, and what did you expect to happen?"
              rows="8"
              required
            />

            <div class="grid gap-5 sm:grid-cols-2">
              <.input
                field={@form[:category]}
                type="select"
                label="Category"
                prompt="Select a category"
                options={@category_options}
              />

              <.input
                field={@form[:priority]}
                type="select"
                label="Priority"
                options={@priority_options}
                required
              />
            </div>

            <div :if={@can_assign?} id="ticket-assignment" class="grid gap-5 sm:grid-cols-2">
              <.input
                field={@form[:team_id]}
                type="select"
                label="Team"
                prompt="No team"
                options={@team_options}
              />
              <.input
                field={@form[:assignee_id]}
                type="select"
                label="Assignee"
                prompt="Unassigned"
                options={@assignee_options}
                disabled={is_nil(@selected_team_id)}
              />
            </div>
            <div
              :if={@can_assign?}
              id="ticket-attachment-uploader"
              class="rounded-xl border border-slate-200 bg-white p-4"
            >
              <HelpdeskWeb.AttachmentUpload.picker upload={@uploads.attachments} />
              <p class="mt-3 text-xs text-slate-500">
                Attachments are saved when you submit the ticket.
              </p>
            </div>

            <div class="flex justify-end gap-3 border-t border-base-300 pt-5">
              <.link navigate={~p"/tickets"} class="btn btn-ghost">Cancel</.link>
              <.button id="submit-ticket" type="submit" variant="primary">
                <.icon name="hero-paper-airplane" class="size-4" /> {if(@ticket,
                  do: "Save changes",
                  else: "Submit Ticket"
                )}
              </.button>
            </div>
          </div>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  defp load_ticket(%{"id" => id}, actor), do: Ash.get!(Ticket, id, actor: actor)
  defp load_ticket(_params, _actor), do: nil

  defp assign_form(%{assigns: %{ticket: nil}} = socket) do
    create_form(socket, %{"priority" => "medium"})
  end

  defp assign_form(socket) do
    form =
      AshPhoenix.Form.for_update(socket.assigns.ticket, :update_ticket,
        actor: socket.assigns.current_user,
        as: "ticket"
      )

    assign(socket, :form, to_form(form))
  end

  defp create_form(socket, params) do
    action = if socket.assigns.selected_customer, do: :open_for_customer, else: :create_ticket

    form =
      Ticket
      |> AshPhoenix.Form.for_create(action,
        actor: socket.assigns.current_user,
        as: "ticket",
        params: customer_params(socket, params),
        exclude_fields_if_empty: [:category]
      )

    assign(socket, :form, to_form(form))
  end

  defp select_customer(socket, customer) do
    params = AshPhoenix.Form.params(socket.assigns.form)

    socket
    |> assign(:selected_customer, customer)
    |> assign(:customer_search_form, to_form(%{"query" => ""}, as: :customer_search))
    |> assign(:customer_search_started?, false)
    |> stream(:customers, [], reset: true)
    |> create_form(params)
  end

  defp customer_params(socket, params) do
    if socket.assigns.can_pick_customer? and socket.assigns.selected_customer do
      Map.put(params, "customer_id", socket.assigns.selected_customer.id)
    else
      Map.delete(params, "customer_id")
    end
  end

  defp search_customers(query, actor) do
    query = String.downcase(query)

    User
    |> Ash.Query.filter(
      contains(string_downcase(first_name), ^query) or
        contains(string_downcase(last_name), ^query) or
        contains(email, ^query) or
        contains(string_downcase(first_name <> " " <> last_name), ^query)
    )
    |> Ash.Query.sort(first_name: :asc, last_name: :asc, id: :asc)
    |> Ash.Query.limit(10)
    |> Ash.Query.select([:id, :first_name, :last_name, :email])
    |> Ash.read!(action: :list_customers, actor: actor)
  end

  defp enum_options(values) do
    Enum.map(values, fn value ->
      label = value |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
      {label, value}
    end)
  end

  defp assignees(nil, _), do: []
  defp assignees("", _), do: []

  defp assignees(team_id, current_user) do
    case Ash.Type.cast_input(:uuid, team_id) do
      {:ok, id} ->
        User
        |> Ash.Query.filter(exists(team_memberships, team_id == ^id))
        |> Ash.Query.sort(email: :asc)
        |> Ash.Query.select([:email, :id])
        |> Ash.read!(action: :list_assignees, actor: current_user)
        |> Enum.map(&{&1.email, &1.id})

      _ ->
        []
    end
  end
end
