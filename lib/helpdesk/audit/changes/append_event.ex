defmodule Helpdesk.Audit.Changes.AppendEvent do
  @moduledoc false

  alias Helpdesk.Repo

  def change(changeset, actor, build_event) when is_function(build_event, 3) do
    Ash.Changeset.around_action(changeset, fn changeset, callback ->
      Repo.transaction(fn ->
        case callback.(changeset) do
          {:ok, record, _completed_changeset, _instructions} = result ->
            record
            |> build_event.(actor, changeset)
            |> append_event(result)

          {:error, error} ->
            Repo.rollback(error)
        end
      end)
      |> case do
        {:ok, result} -> result
        {:error, error} -> {:error, error}
      end
    end)
  end

  defp append_event(:skip, result), do: result

  defp append_event(attributes, result) do
    case Helpdesk.Audit.append(attributes) do
      {:ok, _event} -> result
      {:error, error} -> Repo.rollback(error)
    end
  end
end
