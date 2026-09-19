defmodule Helpdesk.Support.BulkAssignment do
  @moduledoc "Admin-only reassignment using the existing ticket assignment action."
  alias Helpdesk.Accounts.User
  alias Helpdesk.Repo
  alias Helpdesk.Support.Ticket
  require Ash.Query

  def agents(actor) do
    with {:ok, actor} <- administrator(actor) do
      User
      |> Ash.Query.filter(role in [:agent, :admin])
      |> Ash.Query.sort(email: :asc)
      |> Ash.read(actor: actor)
    end
  end

  def preview(actor, from_id, to_id) do
    with {:ok, _actor, tickets} <- prepare(actor, from_id, to_id) do
      {:ok, tickets}
    end
  end

  def transfer(actor, from_id, to_id, expected_ids, selected_ids \\ nil) do
    selected_ids = if is_nil(selected_ids), do: expected_ids, else: selected_ids

    Repo.transaction(fn ->
      with {:ok, actor, tickets} <- prepare(actor, from_id, to_id),
           true <- Enum.map(tickets, & &1.id) == expected_ids,
           :ok <- validate_selection(selected_ids, expected_ids) do
        tickets = Enum.filter(tickets, &(&1.id in selected_ids))

        Enum.each(tickets, fn ticket ->
          case Ash.update(ticket, %{assignee_id: to_id}, action: :assign, actor: actor) do
            {:ok, _} -> :ok
            {:error, _} -> Repo.rollback(:assignment_failed)
          end
        end)

        length(tickets)
      else
        false -> Repo.rollback(:stale_preview)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp validate_selection(ids, expected_ids) when is_list(ids) and ids != [] do
    if Enum.all?(ids, &(&1 in expected_ids)), do: :ok, else: {:error, :invalid_selection}
  end

  defp validate_selection(_, _), do: {:error, :invalid_selection}

  defp prepare(actor, from_id, to_id) do
    with {:ok, actor} <- administrator(actor),
         {:ok, from_id} <- cast_id(from_id),
         {:ok, to_id} <- cast_id(to_id),
         :ok <- different_agents(from_id, to_id),
         %User{role: from_role} when from_role in [:agent, :admin] <- Repo.get(User, from_id),
         %User{role: to_role, status: :active} when to_role in [:agent, :admin] <-
           Repo.get(User, to_id) do
      query = Ticket |> Ash.Query.filter(assignee_id == ^from_id) |> Ash.Query.sort(id: :asc)
      query = Ash.Query.filter(query, status not in [:resolved, :closed])

      with {:ok, tickets} <- Ash.read(query, actor: actor) do
        if Enum.all?(tickets, fn ticket ->
             Ash.Changeset.for_update(ticket, :assign, %{assignee_id: to_id}, actor: actor).valid?
           end) do
          {:ok, actor, tickets}
        else
          {:error, :incompatible_teams}
        end
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_agent}
    end
  end

  defp administrator(%User{id: id}) do
    case Repo.get(User, id) do
      %User{role: :admin, status: :active} = actor -> {:ok, actor}
      _ -> {:error, :forbidden}
    end
  end

  defp administrator(_), do: {:error, :forbidden}

  defp cast_id(value) do
    case Ash.Type.cast_input(:uuid, value) do
      {:ok, id} when is_binary(id) -> {:ok, id}
      _ -> {:error, :invalid_agent}
    end
  end

  defp different_agents(id, id), do: {:error, :same_agent}
  defp different_agents(_, _), do: :ok
end
