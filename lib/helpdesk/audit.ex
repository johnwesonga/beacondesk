defmodule Helpdesk.Audit do
  use Ash.Domain,
    otp_app: :helpdesk

  alias Helpdesk.Audit.Event

  resources do
    resource Helpdesk.Audit.Event
  end

  def append(attributes) do
    result = do_append(attributes)
    result
  end

  defp do_append(attributes) do
    # Implementation for appending audit events
    metadata = Map.get(attributes, :metadata, %{})

    Event
    |> Ash.Changeset.for_create(
      :append,
      %{
        operation_id: Map.get(attributes, :operation_id, Ash.UUID.generate()),
        action: Map.get(attributes, :action),
        actor_id: Map.get(attributes, :actor_id),
        actor_label: Map.get(attributes, :actor_label),
        target_label: Map.get(attributes, :target_label),
        ticket_id: Map.get(attributes, :ticket_id),
        metadata: stringify_keys(metadata),
        source: Map.get(attributes, :source, "admin_ui"),
        occurred_at: DateTime.utc_now()
      }
    )
    |> Ash.create()
  end

  def append!(attributes) do
    case append(attributes) do
      {:ok, event} -> event
      {:error, reason} -> raise "audit append failed: #{inspect(reason)}"
    end
  end

  defp stringify_keys(metadata),
    do: Map.new(metadata, fn {key, value} -> {Atom.to_string(key), value} end)
end
