defmodule HelpdeskWeb.HelpdeskLive.BulkAssignmentTest do
  use HelpdeskWeb.ConnCase
  import Phoenix.LiveViewTest
  import AshAuthentication.Plug.Helpers, only: [store_in_session: 2]
  alias Helpdesk.Accounts.User
  alias Helpdesk.Support.{BulkAssignment, Team, TeamMembership, Ticket, TicketEvent}
  alias Helpdesk.Repo

  setup do
    admin = user!(:admin)
    source = user!(:agent)
    destination = user!(:agent)
    team = Ash.Seed.seed!(Team, %{name: Ash.UUID.generate()})

    for user <- [source, destination],
        do: Ash.Seed.seed!(TeamMembership, %{team_id: team.id, user_id: user.id})

    %{admin: admin, source: source, destination: destination, team: team}
  end

  test "admin previews and transfers only active tickets with history and notifications", ctx do
    first = ticket!(ctx, :open)
    second = ticket!(ctx, :waiting_on_customer)
    resolved = ticket!(ctx, :resolved)
    closed = ticket!(ctx, :closed)
    {:ok, view, _} = live(login(ctx.conn, ctx.admin), ~p"/admin/bulk-assignment")
    assert has_element?(view, "nav a[aria-current='page'][href='/admin/bulk-assignment']")

    view
    |> form("#bulk-assignment-form",
      assignment: %{from_id: ctx.source.id, to_id: ctx.destination.id}
    )
    |> render_submit()

    assert has_element?(view, "#assignment-count", "2 tickets")

    for ticket <- [first, second] do
      assert has_element?(view, "#preview_tickets-#{ticket.id}", ticket.title)

      assert has_element?(
               view,
               "#preview_tickets-#{ticket.id} a[href='/tickets/#{ticket.id}']",
               ticket.ticket_number
             )
    end

    assert has_element?(view, "#preview_tickets-#{second.id}", "Waiting on customer")
    assert has_element?(view, "#preview_tickets-#{first.id}", "Medium")
    refute has_element?(view, "#preview_tickets-#{resolved.id}")
    refute has_element?(view, "#preview_tickets-#{closed.id}")
    assert Repo.get!(Ticket, first.id).assignee_id == ctx.source.id
    view |> element("#confirm-assignment") |> render_click()
    assert has_element?(view, "#flash-info", "Reassigned 2 tickets.")
    refute has_element?(view, "#assignment-preview")

    for ticket <- [first, second] do
      assert Repo.get!(Ticket, ticket.id).assignee_id == ctx.destination.id
      assert Repo.get!(Ticket, ticket.id).team_id == ctx.team.id
      event = Repo.get_by!(TicketEvent, ticket_id: ticket.id)
      assert event.event_type == :assigned
      assert event.user_id == ctx.admin.id
      assert event.old_value == ctx.source.id
      assert event.new_value == ctx.destination.id
      assert Repo.get_by!(Helpdesk.Audit.Event, ticket_id: ticket.id).actor_id == ctx.admin.id
      notification = Repo.get_by!(Helpdesk.Notifications.OutboxEvent, ticket_id: ticket.id)
      assert ctx.destination.id in notification.candidate_recipient_ids
    end

    for ticket <- [resolved, closed],
        do: assert(Repo.get!(Ticket, ticket.id).assignee_id == ctx.source.id)

    render_click(view, "transfer")
    assert Ash.count!(TicketEvent, authorize?: false) == 2
  end

  test "changing agents clears the ticket preview and repeated previews replace the list", ctx do
    ticket = ticket!(ctx, :open)
    {:ok, view, _} = live(login(ctx.conn, ctx.admin), ~p"/admin/bulk-assignment")
    params = %{from_id: ctx.source.id, to_id: ctx.destination.id}
    view |> form("#bulk-assignment-form", assignment: params) |> render_submit()
    assert has_element?(view, "#preview_tickets-#{ticket.id}")
    view |> form("#bulk-assignment-form", assignment: params) |> render_change()
    refute has_element?(view, "#assignment-preview")
    view |> form("#bulk-assignment-form", assignment: params) |> render_submit()
    assert has_element?(view, "#preview_tickets-#{ticket.id}")
    Repo.update!(Ecto.Changeset.change(ticket, status: :resolved))
    view |> form("#bulk-assignment-form", assignment: params) |> render_submit()
    refute has_element?(view, "#preview_tickets-#{ticket.id}")
    assert has_element?(view, "#confirm-assignment[disabled]")
  end

  test "non-admins and revoked administrators cannot transfer", ctx do
    ticket = ticket!(ctx, :open)
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(ctx.conn, ~p"/admin/bulk-assignment")

    for actor <- [ctx.source, user!(:customer)] do
      assert {:error, {:redirect, %{to: "/tickets"}}} =
               live(login(ctx.conn, actor), ~p"/admin/bulk-assignment")

      assert {:error, :forbidden} =
               BulkAssignment.transfer(actor, ctx.source.id, ctx.destination.id, [ticket.id])
    end

    {:ok, view, _} = live(login(ctx.conn, ctx.admin), ~p"/admin/bulk-assignment")

    view
    |> form("#bulk-assignment-form",
      assignment: %{from_id: ctx.source.id, to_id: ctx.destination.id}
    )
    |> render_submit()

    Repo.update!(Ecto.Changeset.change(ctx.admin, role: :agent))
    view |> element("#confirm-assignment") |> render_click()
    assert_redirect(view, "/tickets")
    assert Repo.get!(Ticket, ticket.id).assignee_id == ctx.source.id
  end

  test "incompatible teams prevent every transfer", ctx do
    first = ticket!(ctx, :open)
    other_team = Ash.Seed.seed!(Team, %{name: Ash.UUID.generate()})
    second = ticket!(%{ctx | team: other_team}, :open)

    assert {:error, :incompatible_teams} =
             BulkAssignment.preview(ctx.admin, ctx.source.id, ctx.destination.id)

    assert {:error, :incompatible_teams} =
             BulkAssignment.transfer(
               ctx.admin,
               ctx.source.id,
               ctx.destination.id,
               Enum.sort([first.id, second.id])
             )

    for ticket <- [first, second],
        do: assert(Repo.get!(Ticket, ticket.id).assignee_id == ctx.source.id)

    assert Ash.count!(TicketEvent, authorize?: false) == 0
  end

  test "a changed ticket set requires a new preview", ctx do
    first = ticket!(ctx, :open)
    assert {:ok, tickets} = BulkAssignment.preview(ctx.admin, ctx.source.id, ctx.destination.id)
    ids = Enum.map(tickets, & &1.id)
    ticket!(ctx, :new)

    assert {:error, :stale_preview} =
             BulkAssignment.transfer(ctx.admin, ctx.source.id, ctx.destination.id, ids)

    assert Repo.get!(Ticket, first.id).assignee_id == ctx.source.id
  end

  test "invalid destinations, empty results, and disabled source agents", ctx do
    assert {:ok, []} = BulkAssignment.preview(ctx.admin, ctx.source.id, ctx.destination.id)
    assert {:error, :same_agent} = BulkAssignment.preview(ctx.admin, ctx.source.id, ctx.source.id)

    assert {:error, :invalid_agent} =
             BulkAssignment.preview(ctx.admin, "invalid", ctx.destination.id)

    assert {:error, :invalid_agent} =
             BulkAssignment.preview(ctx.admin, ctx.source.id, user!(:customer).id)

    ticket = ticket!(ctx, :open)
    Repo.update!(Ecto.Changeset.change(ctx.source, status: :disabled))

    assert {:ok, [%Ticket{id: id}]} =
             BulkAssignment.preview(ctx.admin, ctx.source.id, ctx.destination.id)

    assert id == ticket.id
    Repo.update!(Ecto.Changeset.change(ctx.destination, status: :disabled))

    assert {:error, :invalid_agent} =
             BulkAssignment.transfer(ctx.admin, ctx.source.id, ctx.destination.id, [id])
  end

  test "a failure during the second assignment rolls back the first and its events", ctx do
    first = ticket!(ctx, :open)
    ticket!(ctx, :open)
    {:ok, tickets} = BulkAssignment.preview(ctx.admin, ctx.source.id, ctx.destination.id)
    ids = Enum.map(tickets, & &1.id)
    blocked_id = List.last(ids)

    Ecto.Adapters.SQL.query!(
      Repo,
      "CREATE TEMP TRIGGER fail_bulk_assignment BEFORE UPDATE ON tickets WHEN OLD.id = '#{blocked_id}' BEGIN SELECT RAISE(ABORT, 'test unavailable'); END"
    )

    assert {:error, :assignment_failed} =
             BulkAssignment.transfer(ctx.admin, ctx.source.id, ctx.destination.id, ids)

    assert Repo.get!(Ticket, first.id).assignee_id == ctx.source.id
    assert Ash.count!(TicketEvent, authorize?: false) == 0
    assert Ash.count!(Helpdesk.Audit.Event, authorize?: false) == 0
    assert Ash.count!(Helpdesk.Notifications.OutboxEvent, authorize?: false) == 0
  end

  test "admin transfers only selected tickets and cannot submit an empty selection", ctx do
    first = ticket!(ctx, :open)
    second = ticket!(ctx, :open)
    {:ok, view, _} = live(login(ctx.conn, ctx.admin), ~p"/admin/bulk-assignment")

    view
    |> form("#bulk-assignment-form",
      assignment: %{from_id: ctx.source.id, to_id: ctx.destination.id}
    )
    |> render_submit()

    assert has_element?(view, "#select-ticket-#{first.id}[checked]")
    view |> element("#select-ticket-#{first.id}") |> render_click()
    view |> element("#select-ticket-#{second.id}") |> render_click()
    assert has_element?(view, "#assignment-selected-count", "0 of 2 selected")
    assert has_element?(view, "#confirm-assignment[disabled]")
    render_click(view, "transfer")
    assert Repo.get!(Ticket, first.id).assignee_id == ctx.source.id
    view |> element("#select-ticket-#{second.id}") |> render_click()
    assert has_element?(view, "#assignment-selected-count", "1 of 2 selected")
    render_click(view, "toggle-ticket", %{id: Ash.UUID.generate()})
    assert has_element?(view, "#assignment-selected-count", "1 of 2 selected")
    view |> element("#confirm-assignment") |> render_click()
    assert has_element?(view, "#flash-info", "Reassigned 1 tickets.")
    assert Repo.get!(Ticket, first.id).assignee_id == ctx.source.id
    assert Repo.get!(Ticket, second.id).assignee_id == ctx.destination.id
    assert Ash.count!(TicketEvent, authorize?: false) == 1
  end

  test "service rejects empty selections and IDs outside the preview", ctx do
    ticket = ticket!(ctx, :open)

    for ids <- [[], [Ash.UUID.generate()], [ticket.id, Ash.UUID.generate()]] do
      assert {:error, :invalid_selection} =
               BulkAssignment.transfer(
                 ctx.admin,
                 ctx.source.id,
                 ctx.destination.id,
                 [ticket.id],
                 ids
               )
    end

    assert Repo.get!(Ticket, ticket.id).assignee_id == ctx.source.id
  end

  defp ticket!(ctx, status) do
    Ash.Seed.seed!(Ticket, %{
      title: "Transfer request",
      description: "A ticket for bulk assignment testing.",
      ticket_number: Ash.UUID.generate(),
      status: status,
      priority: :medium,
      source: :web,
      team_id: ctx.team.id,
      assignee_id: ctx.source.id,
      reporter_id: ctx.admin.id
    })
  end

  defp user!(role) do
    Ash.Seed.seed!(User, %{
      first_name: "Test",
      last_name: "Agent",
      email: "bulk-#{Ash.UUID.generate()}@example.com",
      role: role,
      hashed_password: "unused"
    })
  end

  defp login(conn, user) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> init_test_session(%{})
    |> store_in_session(Ash.Resource.put_metadata(user, :token, token))
  end
end
