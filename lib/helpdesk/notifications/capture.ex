defmodule Helpdesk.Notifications.Capture do
  @moduledoc false
  import Ecto.Query
  require Ash.Query

  alias Helpdesk.Accounts.User
  alias Helpdesk.Notifications.OutboxEvent
  alias Helpdesk.Repo
  alias Helpdesk.Support.{Message, Team, TeamMembership, Ticket}

  @doc false
  def current_candidate?(event, recipient_id) do
    case Repo.get(Ticket, event.ticket_id) do
      nil -> false
      ticket -> recipient_id in candidates(event.kind, ticket, event.actor_id)
    end
  end

  # Called only with persisted events inside RecordTicketEvent's transaction.
  def enqueue(event, record, original) do
    ticket = if match?(%Ticket{}, record), do: record, else: Repo.get!(Ticket, record.ticket_id)
    kind = kind(event, ticket, original)

    if kind do
      recipients =
        candidates(kind, ticket, event.user_id)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.reject(&(&1 == event.user_id))
        |> Enum.filter(&eligible?(&1, ticket, record, kind))

      create_and_schedule(%{
        source_event_id: event.id,
        kind: kind,
        ticket_id: ticket.id,
        message_id: if(match?(%Message{}, record), do: record.id),
        actor_id: event.user_id,
        candidate_recipient_ids: recipients,
        occurred_at: event.inserted_at,
        payload:
          Map.put(
            payload(event),
            "email_recipient_ids",
            Enum.filter(
              recipients,
              &Helpdesk.Notifications.Email.candidate?(Map.put(event, :kind, kind), &1)
            )
          )
      })
    else
      {:ok, :skipped}
    end
  end

  defp create_and_schedule(attributes) do
    with {:ok, event} <-
           Ash.create(OutboxEvent, attributes, action: :enqueue, authorize?: false) do
      if Helpdesk.Notifications.ProcessingMode.ash_oban?() do
        try do
          AshOban.run_trigger(event, :process_notification_event)
          {:ok, event}
        rescue
          error -> {:error, error}
        end
      else
        {:ok, event}
      end
    end
  end

  defp kind(%{event_type: :ticket_created}, _, _), do: :ticket_created
  defp kind(%{event_type: :assigned}, %{assignee_id: nil}, _), do: :unassigned
  defp kind(%{event_type: :assigned}, _, _), do: :assigned
  # An unassignment already routes to the final team in this operation.
  defp kind(%{event_type: :team_changed}, %{assignee_id: nil}, %{assignee_id: old})
       when not is_nil(old),
       do: nil

  defp kind(%{event_type: :team_changed}, %{assignee_id: nil}, _), do: :team_changed

  defp kind(%{event_type: :status_changed, new_value: status}, _, _)
       when status in ["waiting_on_customer", "resolved", "closed"],
       do: String.to_existing_atom(status)

  defp kind(%{event_type: :status_changed, old_value: old, new_value: new}, _, _)
       when old in ["resolved", "closed"] and
              new in ["new", "open", "waiting_on_support"],
       do: :reopened

  defp kind(%{event_type: :message_added, metadata: %{"message_type" => "public_reply"}}, _, _),
    do: :public_reply

  defp kind(%{event_type: :message_added, metadata: %{"message_type" => "internal_note"}}, _, _),
    do: :internal_note

  defp kind(_, _, _), do: nil

  defp candidates(:assigned, ticket, _), do: [ticket.assignee_id]
  defp candidates(kind, ticket, _) when kind in [:unassigned, :team_changed], do: team(ticket)

  defp candidates(kind, ticket, _) when kind in [:ticket_created, :internal_note],
    do: owner(ticket)

  defp candidates(:public_reply, %{reporter_id: actor} = ticket, actor), do: owner(ticket)

  defp candidates(kind, ticket, _) when kind in [:public_reply, :reopened],
    do: [ticket.reporter_id | owner(ticket)]

  defp candidates(_, ticket, _), do: [ticket.reporter_id]

  defp owner(ticket) do
    case ticket.assignee_id && Repo.get(User, ticket.assignee_id) do
      %User{status: :active, id: id} -> [id]
      _ -> team(ticket)
    end
  end

  defp team(%{team_id: nil}), do: []

  defp team(ticket) do
    Repo.all(
      from m in TeamMembership,
        join: t in Team,
        on: t.id == m.team_id,
        join: u in User,
        on: u.id == m.user_id,
        where:
          t.id == ^ticket.team_id and t.active == true and
            u.status == :active and u.role in [:agent, :admin],
        select: u.id
    )
  end

  defp eligible?(id, ticket, record, kind) do
    case Repo.get(User, id) do
      %User{status: :active} = user ->
        (kind != :internal_note or user.role in [:agent, :admin]) and
          visible?(Ticket, ticket.id, user) and
          (not match?(%Message{}, record) or visible?(Message, record.id, user))

      _ ->
        false
    end
  end

  defp visible?(resource, id, actor) do
    resource |> Ash.Query.filter(id == ^id) |> Ash.exists?(actor: actor)
  end

  defp payload(%{event_type: :status_changed} = event),
    do: %{"old_status" => event.old_value, "new_status" => event.new_value}

  defp payload(_), do: %{}
end
