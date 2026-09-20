defmodule Helpdesk.Support.Checks.CanAttachToMessage do
  use Ash.Policy.SimpleCheck
  require Ash.Query

  @impl true
  def describe(_), do: "actor authored and can read the target message"

  @impl true
  def match?(nil, _, _), do: false

  def match?(actor, %{changeset: changeset}, _) do
    id = Ash.Changeset.get_attribute(changeset, :message_id)

    if id && Helpdesk.Accounts.Authorization.allowed?(actor, :add_public_replies) do
      Helpdesk.Support.Message
      |> Ash.Query.filter(id == ^id and user_id == ^actor.id)
      |> Ash.exists?(actor: actor, authorize?: true)
    else
      false
    end
  end
end
