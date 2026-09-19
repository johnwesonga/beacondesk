defmodule HelpdeskWeb.HelpdeskLive.TeamFormTest do
  use HelpdeskWeb.ConnCase
  import Phoenix.LiveViewTest
  import AshAuthentication.Plug.Helpers, only: [store_in_session: 2]
  require Ecto.Query
  alias Helpdesk.Accounts.User
  alias Helpdesk.Support.Team

  test "admins create and edit teams", %{conn: conn} do
    user = user!()
    Helpdesk.Repo.update_all(Ecto.Query.where(User, id: ^user.id), set: [role: :admin])
    conn = conn |> init_test_session(%{}) |> store_in_session(user)
    {:ok, view, _} = live(conn, ~p"/teams")
    view |> element("#new-team") |> render_click()
    assert_patch(view, "/teams/new")
    assert has_element?(view, "#team-modal")

    view
    |> form("#team-form", team: %{name: "Billing", email: "billing@example.com", active: true})
    |> render_submit()

    assert_patch(view, "/teams")
    refute has_element?(view, "#team-modal")
    team = Helpdesk.Repo.get_by!(Team, name: "Billing")
    assert team.active
    assert has_element?(view, "#teams-#{team.id}")
    view |> element("#edit-team-#{team.id}") |> render_click()
    assert_patch(view, "/teams/#{team.id}/edit")
    assert has_element?(view, "#team_name[value=Billing]")
    view |> form("#team-form", team: %{name: "Billing support", active: false}) |> render_submit()
    assert_patch(view, "/teams")
    refute has_element?(view, "#team-modal")
    updated = Helpdesk.Repo.get!(Team, team.id)
    assert updated.name == "Billing support"
    refute updated.active
  end

  test "customers cannot manage teams", %{conn: conn} do
    conn = conn |> init_test_session(%{}) |> store_in_session(user!())
    assert {:error, {:redirect, %{to: "/tickets"}}} = live(conn, ~p"/teams/new")
  end

  test "team index lists active and inactive teams with edit links", %{conn: conn} do
    user = user!()
    Helpdesk.Repo.update_all(Ecto.Query.where(User, id: ^user.id), set: [role: :admin])
    conn = conn |> init_test_session(%{}) |> store_in_session(user)
    {:ok, view, _} = live(conn, ~p"/teams")
    assert has_element?(view, "#teams-empty:only-child")
    assert has_element?(view, "#new-team[href='/teams/new']")

    active = Ash.Seed.seed!(Team, %{name: "Billing", active: true})
    inactive = Ash.Seed.seed!(Team, %{name: "Archived", active: false})
    {:ok, view, _} = live(conn, ~p"/teams")
    assert has_element?(view, "#teams-#{active.id}")
    assert has_element?(view, "#teams-#{inactive.id}")
    refute has_element?(view, "#teams-empty:only-child")
    assert has_element?(view, "#edit-team-#{active.id}[href='/teams/#{active.id}/edit']")
  end

  test "team index rejects customers and anonymous visitors", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/teams")
    conn = conn |> init_test_session(%{}) |> store_in_session(user!())
    assert {:error, {:redirect, %{to: "/tickets"}}} = live(conn, ~p"/teams")
  end

  test "direct modal URLs retain validation errors and support cancellation", %{conn: conn} do
    user = user!()
    Helpdesk.Repo.update_all(Ecto.Query.where(User, id: ^user.id), set: [role: :admin])
    team = Ash.Seed.seed!(Team, %{name: "Existing team"})
    conn = conn |> init_test_session(%{}) |> store_in_session(user)
    {:ok, view, _} = live(conn, ~p"/teams/#{team.id}/edit")
    assert has_element?(view, "#team-modal")
    view |> form("#team-form", team: %{name: ""}) |> render_submit()
    assert has_element?(view, "#team-modal")
    assert Helpdesk.Repo.get!(Team, team.id).name == "Existing team"
    view |> element("#cancel-team") |> render_click()
    assert_patch(view, "/teams")
    refute has_element?(view, "#team-modal")
    assert has_element?(view, "#teams-#{team.id}")
    view |> element("#new-team") |> render_click()
    render_click(view, "cancel")
    assert_patch(view, "/teams")
    refute has_element?(view, "#team-modal")
  end

  test "admins add and remove members while active assignments block removal", %{conn: conn} do
    admin = user!()
    agent = user!()
    customer = user!()
    Helpdesk.Repo.update_all(Ecto.Query.where(User, id: ^admin.id), set: [role: :admin])
    Helpdesk.Repo.update_all(Ecto.Query.where(User, id: ^agent.id), set: [role: :agent])
    team = Ash.Seed.seed!(Team, %{name: "Membership team"})
    conn = conn |> init_test_session(%{}) |> store_in_session(admin)
    {:ok, view, _} = live(conn, ~p"/teams")
    view |> element("#manage-members-#{team.id}") |> render_click()
    assert has_element?(view, "#members-modal")
    assert has_element?(view, "#members-empty:only-child")
    refute has_element?(view, "#member_user_id option[value='#{customer.id}']")
    view |> form("#add-member-form", member: %{user_id: agent.id}) |> render_submit()

    membership =
      Helpdesk.Repo.get_by!(Helpdesk.Support.TeamMembership, team_id: team.id, user_id: agent.id)

    assert has_element?(view, "#members-#{membership.id}")
    render_submit(view, "add-member", %{"member" => %{"user_id" => agent.id}})
    assert Ash.count!(Helpdesk.Support.TeamMembership, authorize?: false) == 1
    assert has_element?(view, "#flash-error", "Already belongs to this team.")
    refute has_element?(view, "#flash-error", "Bread Crumbs")

    ticket =
      Ash.Seed.seed!(Helpdesk.Support.Ticket, %{
        ticket_number: Ash.UUID.generate(),
        title: "Active assignment",
        description: "Active ticket assigned to this team member",
        team_id: team.id,
        assignee_id: agent.id,
        reporter_id: customer.id,
        status: :open,
        priority: :medium,
        source: :web
      })

    view |> element("#remove-member-#{membership.id}") |> render_click()
    assert has_element?(view, "#members-#{membership.id}")
    assert Helpdesk.Repo.get(Helpdesk.Support.TeamMembership, membership.id)

    assert has_element?(
             view,
             "#flash-error",
             "Reassign this member's active tickets in this team before removing them."
           )

    refute has_element?(view, "#flash-error", "Value: nil")
    refute has_element?(view, "#flash-error", "Bread Crumbs")

    Helpdesk.Repo.update_all(Ecto.Query.where(Helpdesk.Support.Ticket, id: ^ticket.id),
      set: [status: :resolved]
    )

    view |> element("#remove-member-#{membership.id}") |> render_click()
    assert has_element?(view, "#members-empty:only-child")
    refute Helpdesk.Repo.get(Helpdesk.Support.TeamMembership, membership.id)

    assert {:error, _} =
             Ash.create(Helpdesk.Support.TeamMembership, %{team_id: team.id, user_id: agent.id},
               action: :add_member,
               actor: customer
             )
  end

  defp user! do
    Ash.create!(
      User,
      %{
        email: "team-#{Ash.UUID.generate()}@example.com",
        password: "password123",
        first_name: "Test",
        last_name: "User",
        password_confirmation: "password123"
      },
      action: :register_with_password,
      authorize?: false
    )
  end
end
