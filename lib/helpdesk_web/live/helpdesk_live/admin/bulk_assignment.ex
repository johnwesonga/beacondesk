defmodule HelpdeskWeb.HelpdeskLive.Admin.BulkAssignment do
  use HelpdeskWeb, :live_view
  alias Helpdesk.Support.BulkAssignment
  on_mount {HelpdeskWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    case BulkAssignment.agents(socket.assigns.current_user) do
      {:ok, agents} ->
        {:ok,
         socket
         |> stream(:preview_tickets, [])
         |> assign(
           current_scope: %{user: socket.assigns.current_user},
           page_title: "Bulk assign tickets",
           source_options: Enum.map(agents, &{label(&1), &1.id}),
           destination_options:
             agents |> Enum.filter(&(&1.status == :active)) |> Enum.map(&{label(&1), &1.id}),
           form: to_form(%{"from_id" => "", "to_id" => ""}, as: :assignment),
           preview: nil
         )}

      _ ->
        {:ok, redirect(socket, to: ~p"/tickets")}
    end
  end

  @impl true
  def handle_event("validate", %{"assignment" => params}, socket) do
    {:noreply, socket |> clear_preview() |> assign(form: to_form(params, as: :assignment))}
  end

  def handle_event("preview", %{"assignment" => params}, socket) do
    socket = socket |> clear_preview() |> assign(form: to_form(params, as: :assignment))

    case BulkAssignment.preview(socket.assigns.current_user, params["from_id"], params["to_id"]) do
      {:ok, tickets} ->
        {:noreply,
         socket
         |> assign(:preview, %{
           ids: Enum.map(tickets, & &1.id),
           selected_ids: Enum.map(tickets, & &1.id),
           from_id: params["from_id"],
           to_id: params["to_id"]
         })
         |> stream(:preview_tickets, tickets, reset: true)}

      {:error, reason} ->
        failure(socket, reason)
    end
  end

  def handle_event("toggle-ticket", %{"id" => id}, socket) do
    preview = socket.assigns.preview

    if preview && id in preview.ids do
      selected_ids =
        if id in preview.selected_ids,
          do: List.delete(preview.selected_ids, id),
          else: [id | preview.selected_ids]

      {:noreply, assign(socket, :preview, %{preview | selected_ids: selected_ids})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("transfer", _, %{assigns: %{preview: nil}} = socket), do: {:noreply, socket}

  def handle_event("transfer", _, %{assigns: %{preview: %{selected_ids: []}}} = socket),
    do: failure(socket, :invalid_selection)

  def handle_event("transfer", _, socket) do
    preview = socket.assigns.preview
    socket = clear_preview(socket)

    case BulkAssignment.transfer(
           socket.assigns.current_user,
           preview.from_id,
           preview.to_id,
           preview.ids,
           preview.selected_ids
         ) do
      {:ok, count} -> {:noreply, put_flash(socket, :info, "Reassigned #{count} tickets.")}
      {:error, reason} -> failure(socket, reason)
    end
  end

  defp clear_preview(socket) do
    socket |> assign(:preview, nil) |> stream(:preview_tickets, [], reset: true)
  end

  defp humanize(value),
    do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp failure(socket, :forbidden),
    do:
      {:noreply,
       socket
       |> put_flash(:error, "Only active administrators can bulk assign tickets.")
       |> push_navigate(to: ~p"/tickets")}

  defp failure(socket, reason), do: {:noreply, put_flash(socket, :error, error_message(reason))}
  defp error_message(:same_agent), do: "Select two different agents."
  defp error_message(:invalid_selection), do: "Select at least one ticket from the preview."
  defp error_message(:invalid_agent), do: "Select a source agent and an active destination agent."

  defp error_message(:incompatible_teams),
    do:
      "The destination agent must belong to every affected ticket's team, and each team must be active. No tickets were changed."

  defp error_message(:stale_preview),
    do:
      "The source agent's tickets changed. Preview the reassignment again. No tickets were changed."

  defp error_message(_),
    do: "Tickets could not be reassigned. No tickets were changed. Please try again."

  defp label(agent),
    do:
      "#{agent.first_name} #{agent.last_name} (#{agent.email})#{if agent.status == :disabled, do: " — disabled", else: ""}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      notification_count={@notification_count}
      current_page={:bulk_assignment}
    >
      <section id="bulk-assignment" class="mx-auto max-w-3xl space-y-6">
        <header>
          <p class="text-sm font-semibold text-violet-600">Administration</p>
          <h1 class="mt-2 text-3xl font-bold">Bulk assign tickets</h1>
          <p class="mt-3 text-slate-600">
            Transfer an agent's tickets to another agent. Each ticket keeps its current team. The destination must belong to every affected team.
          </p>
        </header>
        <.form
          for={@form}
          id="bulk-assignment-form"
          phx-change="validate"
          phx-submit="preview"
          class="space-y-4 rounded-xl border border-slate-200 bg-white p-6"
        >
          <.input
            field={@form[:from_id]}
            type="select"
            label="From agent"
            prompt="Select an agent"
            options={@source_options}
            required
          />
          <.input
            field={@form[:to_id]}
            type="select"
            label="To agent"
            prompt="Select an active agent"
            options={@destination_options}
            required
          />
          <p class="text-sm text-slate-500">
            Only active tickets are transferred. Resolved and closed tickets stay with their current assignee. Disabled agents can be selected as the source.
          </p>
          <.button id="preview-assignment" type="submit" phx-disable-with="Checking…">
            Preview reassignment
          </.button>
        </.form>
        <section
          :if={@preview}
          id="assignment-preview"
          class="rounded-xl border border-slate-200 bg-white p-6"
          aria-live="polite"
        >
          <p id="assignment-count" class="font-semibold">
            {length(@preview.ids)} tickets to reassign.
          </p>
          <p id="assignment-selected-count" class="mt-2 text-sm text-slate-600">
            {length(@preview.selected_ids)} of {length(@preview.ids)} selected.
          </p>
          <p :if={@preview.ids == []} class="mt-2 text-sm text-slate-500">
            No matching tickets are assigned to this agent.
          </p>
          <p :if={@preview.ids != []} class="mt-2 text-sm text-slate-500">
            Assignment history and notifications will be recorded for each ticket.
          </p>
          <div class="mt-4 max-h-96 overflow-auto">
            <table class="w-full text-left text-sm">
              <caption class="sr-only">Tickets included in this reassignment</caption>
              <thead class="sticky top-0 bg-white text-slate-500">
                <tr>
                  <th scope="col" class="p-2">Select</th>
                  <th scope="col" class="p-2">Ticket</th>
                  <th scope="col" class="p-2">Status</th>
                  <th scope="col" class="p-2">Priority</th>
                </tr>
              </thead>
              <tbody id="assignment-tickets" phx-update="stream">
                <tr
                  :for={{id, ticket} <- @streams.preview_tickets}
                  id={id}
                  class="border-t border-slate-200"
                >
                  <td class="p-2">
                    <.input
                      id={"select-ticket-#{ticket.id}"}
                      name={"selected-ticket-#{ticket.id}"}
                      type="checkbox"
                      checked={ticket.id in @preview.selected_ids}
                      aria-label={"Select #{ticket.ticket_number}"}
                      phx-click="toggle-ticket"
                      phx-value-id={ticket.id}
                    />
                  </td>
                  <td class="p-2">
                    <.link
                      href={~p"/tickets/#{ticket.id}"}
                      target="_blank"
                      rel="noopener"
                      class="font-semibold text-sky-700 hover:underline"
                      aria-label={"#{ticket.ticket_number}: #{ticket.title} (opens in a new tab)"}
                    >
                      {ticket.ticket_number}
                    </.link>
                    <p class="mt-1 break-words">{ticket.title}</p>
                  </td>
                  <td class="p-2">{humanize(ticket.status)}</td>
                  <td class="p-2">{humanize(ticket.priority)}</td>
                </tr>
              </tbody>
            </table>
          </div>
          <button
            id="confirm-assignment"
            type="button"
            phx-click="transfer"
            phx-disable-with="Reassigning…"
            disabled={@preview.selected_ids == []}
            class="btn btn-primary mt-4"
          >
            Reassign selected tickets
          </button>
        </section>
      </section>
    </Layouts.app>
    """
  end
end
