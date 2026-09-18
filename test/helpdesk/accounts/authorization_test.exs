defmodule Helpdesk.Accounts.AuthorizationTest do
  use ExUnit.Case, async: true

  alias Helpdesk.Accounts.{Authorization, User}
  alias Helpdesk.Accounts.Checks.HasPermission

  test "customers can submit and follow up on tickets but cannot manage them" do
    customer = %User{role: :customer}

    for permission <- [:create_tickets, :read_tickets, :add_public_replies] do
      assert Authorization.allowed?(customer, permission)
    end

    for permission <- [
          :open_tickets_for_customers,
          :assign_tickets,
          :edit_tickets,
          :change_ticket_status,
          :change_ticket_priority,
          :add_internal_notes,
          :read_ticket_events,
          :manage_users,
          :manage_teams,
          :manage_team_membership
        ] do
      refute Authorization.allowed?(customer, permission)
    end
  end

  test "agents handle tickets and administrators also manage the organization" do
    for permission <- Authorization.permissions() do
      assert Authorization.allowed?(%User{role: :admin}, permission)

      if permission in [:view_operations, :manage_users, :manage_teams, :manage_team_membership] do
        refute Authorization.allowed?(%User{role: :agent}, permission)
      else
        assert Authorization.allowed?(%User{role: :agent}, permission)
      end
    end
  end

  test "unknown actors, roles and permissions are denied" do
    for actor <- [nil, %User{role: nil}, %User{role: :unknown}] do
      assert Authorization.authorize(actor, :read_tickets) == {:error, :forbidden}
    end

    refute Authorization.allowed?(%User{role: :admin}, :manage_tickets)
    refute Authorization.allowed?(%User{role: :admin}, :unknown)
    assert Authorization.authorize(%User{role: :customer}, :create_tickets) == :ok
  end

  test "policy check supports individual capabilities and alternatives" do
    actor = %User{role: :customer}
    assert HasPermission.match?(actor, %{}, permission: :create_tickets)
    refute HasPermission.match?(actor, %{}, permission: :assign_tickets)
    assert HasPermission.match?(actor, %{}, permissions: [:assign_tickets, :read_tickets])
    refute HasPermission.match?(actor, %{}, [])
  end
end
