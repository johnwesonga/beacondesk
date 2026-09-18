defmodule Helpdesk.Accounts.Authorization do
  @moduledoc """
  Defines which capabilities each helpdesk role has.

  Capabilities grant access to an operation, not every record. Ash resource
  policies must additionally enforce reporter ownership, team membership,
  and assignment scope. Use those policies to authorize individual records.
  """

  alias Helpdesk.Accounts.User

  @permissions [
    :view_operations,
    :create_tickets,
    :open_tickets_for_customers,
    :read_tickets,
    :edit_tickets,
    :assign_tickets,
    :change_ticket_status,
    :change_ticket_priority,
    :add_public_replies,
    :add_internal_notes,
    :read_ticket_events,
    :manage_users,
    :manage_teams,
    :manage_team_membership
  ]

  @role_permissions %{
    admin: @permissions,
    agent: [
      :create_tickets,
      :open_tickets_for_customers,
      :read_tickets,
      :edit_tickets,
      :assign_tickets,
      :change_ticket_status,
      :change_ticket_priority,
      :add_public_replies,
      :add_internal_notes,
      :read_ticket_events
    ],
    customer: [:create_tickets, :read_tickets, :add_public_replies]
  }

  def permissions, do: @permissions

  def allowed?(%User{role: role, status: :active}, permission) when permission in @permissions do
    permission in Map.get(@role_permissions, role, [])
  end

  def allowed?(_actor, _permission), do: false
  def any_allowed?(actor, permissions), do: Enum.any?(permissions, &allowed?(actor, &1))

  def authorize(actor, permission) do
    if allowed?(actor, permission), do: :ok, else: {:error, :forbidden}
  end
end
