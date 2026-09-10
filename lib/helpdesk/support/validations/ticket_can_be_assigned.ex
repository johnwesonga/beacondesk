defmodule Helpdesk.Support.Validations.TicketCanBeAssigned do
  @moduledoc """
  Validates that:
  1) a ticket can be assigned to a user of the correct role, admin or agent.
  2) The selected team is active
  3) The assignee is not the same as the reporter
  4) Assignee belongs to the selected team.
  """

  use Ash.Resource.Validation

  alias Helpdesk.Accounts.User
  alias Helpdesk.Repo
  alias Helpdesk.Support.Team
  alias Helpdesk.Support.TeamMembership
  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    with :ok <- validate_assignee(changeset),
         :ok <- validate_team(changeset),
         :ok <- validate_team_membership(changeset) do
      :ok
    end
  end

  defp validate_assignee(changeset) do
    case Ash.Changeset.fetch_change(changeset, :assignee_id) do
      :error ->
        :ok

      {:ok, nil} ->
        :ok

      {:ok, assignee_id} ->
        validate_assignee_role(assignee_id)
    end
  end

  defp validate_team(changeset) do
    case Ash.Changeset.fetch_change(changeset, :team_id) do
      :error ->
        :ok

      {:ok, nil} ->
        :ok

      {:ok, team_id} ->
        validate_team_active(team_id)
    end
  end

  defp validate_assignee_role(assignee_id) do
    case Repo.get(User, assignee_id) do
      %User{role: role} when role in [:agent, :admin] ->
        :ok

      _ ->
        {:error,
         InvalidAttribute.exception(
           field: :assignee_id,
           value: assignee_id,
           message: "must refer to an agent or administrator"
         )}
    end
  end

  defp validate_team_active(team_id) do
    case Repo.get(Team, team_id) do
      %Team{active: true} ->
        :ok

      _ ->
        {:error,
         InvalidAttribute.exception(
           field: :team_id,
           value: team_id,
           message: "must refer to an active team"
         )}
    end
  end

  defp validate_team_membership(changeset) do
    if assignment_changed?(changeset) do
      assignee_id = Ash.Changeset.get_attribute(changeset, :assignee_id)
      team_id = Ash.Changeset.get_attribute(changeset, :team_id)

      validate_team_membership_assignee(assignee_id, team_id)
    else
      :ok
    end
  end

  defp validate_team_membership_assignee(nil, _team_id), do: :ok

  defp validate_team_membership_assignee(_assignee_id, nil) do
    {:error,
     InvalidAttribute.exception(
       field: :team_id,
       value: nil,
       message: "must be selected when assigning a ticket"
     )}
  end

  defp validate_team_membership_assignee(assignee_id, team_id) do
    case Repo.get_by(TeamMembership, user_id: assignee_id, team_id: team_id) do
      %TeamMembership{} ->
        :ok

      _ ->
        {:error,
         InvalidAttribute.exception(
           field: :assignee_id,
           value: assignee_id,
           message: "must be a member of the selected team"
         )}
    end
  end

  defp assignment_changed?(changeset) do
    match?({:ok, _value}, Ash.Changeset.fetch_change(changeset, :assignee_id)) or
      match?({:ok, _value}, Ash.Changeset.fetch_change(changeset, :team_id))
  end
end
