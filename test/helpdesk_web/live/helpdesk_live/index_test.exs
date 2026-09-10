defmodule HelpdeskWeb.HelpdeskLive.IndexTest do
  use HelpdeskWeb.ConnCase

  import AshAuthentication.Plug.Helpers, only: [store_in_session: 2]
  import Phoenix.LiveViewTest

  require Ecto.Query

  alias Helpdesk.Accounts.User
  alias Helpdesk.Support.Ticket

  test "requires an authenticated user", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/tickets")
  end

  test "lists only accessible tickets and filters the stream", %{conn: conn} do
    user = register_user!()
    other_user = register_user!()
    billing_ticket = create_ticket!(user, "Duplicate card charge", :high, :billing)
    login_ticket = create_ticket!(user, "Cannot sign in", :low, :bug)
    other_ticket = create_ticket!(other_user, "Other customer ticket", :medium, :howto)

    conn =
      conn
      |> init_test_session(%{})
      |> store_in_session(user)

    {:ok, view, _html} = live(conn, ~p"/tickets")

    assert has_element?(view, "#ticket-filters")
    assert has_element?(view, "#filters_q")
    assert has_element?(view, "#filters_status")
    assert has_element?(view, "#filters_priority")
    assert has_element?(view, "#filters_sort")
    assert has_element?(view, "#new-ticket")
    assert has_element?(view, "#tickets-#{billing_ticket.id}")
    assert has_element?(view, "#tickets-#{login_ticket.id}")
    refute has_element?(view, "#tickets-#{other_ticket.id}")
    refute has_element?(view, "#edit-ticket-#{billing_ticket.id}")
    assert has_element?(view, "#ticket-assignee-#{billing_ticket.id}", "Unassigned")

    view
    |> form("#ticket-filters", filters: %{q: "Duplicate"})
    |> render_change()

    assert_patch(view, "/tickets?q=Duplicate")
    assert has_element?(view, "#tickets-#{billing_ticket.id}")
    refute has_element?(view, "#tickets-#{login_ticket.id}")

    render_patch(view, ~p"/tickets?priority=low")
    assert has_element?(view, "#tickets-#{login_ticket.id}")
    refute has_element?(view, "#tickets-#{billing_ticket.id}")

    render_patch(view, ~p"/tickets?status=closed")
    assert has_element?(view, "#tickets[data-empty=true]")

    render_patch(view, ~p"/tickets?sort=oldest")
    assert has_element?(view, "#filters_sort option[value=oldest][selected]")
  end

  test "staff can assign a ticket through the modal", %{conn: conn} do
    user = register_user!()
    Helpdesk.Repo.update_all(Ecto.Query.where(User, id: ^user.id), set: [role: :admin])
    team = Ash.Seed.seed!(Helpdesk.Support.Team, %{name: "Assignment team"})
    Ash.Seed.seed!(Helpdesk.Support.TeamMembership, %{team_id: team.id, user_id: user.id})
    ticket = create_ticket!(user, "Assignment request", :medium, :billing)
    conn = conn |> init_test_session(%{}) |> store_in_session(user)
    {:ok, view, _} = live(conn, ~p"/tickets")
    view |> element("#assign-ticket-#{ticket.id}") |> render_click()
    assert has_element?(view, "#assignment-modal")
    view |> form("#assignment-form", assignment: %{team_id: team.id}) |> render_change()
    assert has_element?(view, "#assignment_assignee_id option[value='#{user.id}']")

    view
    |> form("#assignment-form", assignment: %{team_id: team.id, assignee_id: user.id})
    |> render_submit()

    refute has_element?(view, "#assignment-modal")
    saved = Helpdesk.Repo.get!(Ticket, ticket.id)
    assert saved.team_id == team.id
    assert saved.assignee_id == user.id
    assert has_element?(view, "#ticket-assignee-#{ticket.id}", "Assigned to: #{user.email}")
  end

  test "customers cannot open an assignment modal", %{conn: conn} do
    user = register_user!()
    ticket = create_ticket!(user, "Customer request", :medium, :billing)
    conn = conn |> init_test_session(%{}) |> store_in_session(user)
    {:ok, view, _} = live(conn, ~p"/tickets")
    refute has_element?(view, "#assign-ticket-#{ticket.id}")
    render_click(view, "open-assignment", %{"id" => ticket.id})
    refute has_element?(view, "#assignment-modal")
  end

  test "pagination preserves filters, scopes counts, and resets the stream", %{conn: conn} do
    user = register_user!()
    other = register_user!()

    tickets =
      for index <- 1..21 do
        Ash.Seed.seed!(Ticket, %{
          title: "Paged request #{index}",
          description: "Detailed pagination test request",
          ticket_number: Ash.UUID.generate(),
          reporter_id: user.id,
          status: :open,
          priority: :high,
          source: :web,
          updated_at: DateTime.add(~U[2026-01-01 00:00:00Z], index)
        })
      end

    hidden = create_ticket!(other, "Paged request private", :high, :billing)
    conn = conn |> init_test_session(%{}) |> store_in_session(user)
    {:ok, view, _} = live(conn, ~p"/tickets?q=Paged&status=open&priority=high&sort=oldest")
    assert has_element?(view, "#ticket-count", "21")
    assert has_element?(view, "#tickets-#{hd(tickets).id}")
    refute has_element?(view, "#tickets-#{List.last(tickets).id}")
    refute has_element?(view, "#tickets-#{hidden.id}")
    assert has_element?(view, "#tickets-previous[disabled]")
    view |> element("#tickets-next") |> render_click()
    assert has_element?(view, "#tickets-page-2[aria-current=page]")
    assert has_element?(view, "#filters_status option[value=open][selected]")
    assert has_element?(view, "#filters_q[value=Paged]")
    assert has_element?(view, "#tickets-#{List.last(tickets).id}")
    refute has_element?(view, "#tickets-#{hd(tickets).id}")
    assert has_element?(view, "#tickets-next[disabled]")
    view |> form("#ticket-filters", filters: %{q: "no match"}) |> render_change()
    assert has_element?(view, "#tickets-page-1[aria-current=page]")
    assert has_element?(view, "#tickets-empty:only-child")
    render_patch(view, ~p"/tickets?page=999")
    assert has_element?(view, "#tickets-page-2[aria-current=page]")

    for invalid <- ["0", "-1", "bad", "999999999999999999999"] do
      render_patch(view, ~p"/tickets?#{%{page: invalid}}")
      assert has_element?(view, "#tickets-page-1[aria-current=page]")
    end

    Helpdesk.Repo.update_all(Ecto.Query.where(User, id: ^user.id), set: [role: :admin])
    {:ok, view, _} = live(conn, ~p"/tickets?page=2")
    assert has_element?(view, "#ticket-count", "22")
    assert has_element?(view, "#tickets-page-2[aria-current=page]")
  end

  defp create_ticket!(user, title, priority, category) do
    Ash.create!(
      Ticket,
      %{
        title: title,
        description: "A sufficiently detailed description for this ticket",
        priority: priority,
        category: category
      },
      action: :create_ticket,
      actor: user
    )
  end

  defp register_user! do
    email = "ticket-index-#{System.unique_integer([:positive])}@example.com"
    password = "secure-password"

    Ash.create!(
      User,
      %{
        email: email,
        password: password,
        first_name: "Test",
        last_name: "User",
        password_confirmation: password
      },
      action: :register_with_password,
      authorize?: false
    )
  end
end
