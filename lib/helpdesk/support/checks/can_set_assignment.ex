defmodule Helpdesk.Support.Checks.CanSetAssignment do
  @moduledoc "Requires assignment permission when a ticket's routing changes."
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_), do: "actor can assign tickets when setting or changing assignment"

  @impl true
  def match?(actor, %{changeset: %Ash.Changeset{} = changeset}, _) do
    assigning? =
      changeset.action.name == :assign or
        Enum.any?([:team_id, :assignee_id], fn field ->
          Ash.Changeset.changing_attribute?(changeset, field)
        end)

    not assigning? or Helpdesk.Accounts.Authorization.allowed?(actor, :assign_tickets)
  end

  def match?(_, _, _), do: false
end
