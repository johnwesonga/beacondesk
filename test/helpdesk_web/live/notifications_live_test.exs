defmodule HelpdeskWeb.NotificationsLiveTest do
  use HelpdeskWeb.ConnCase
  import Phoenix.LiveViewTest
  import AshAuthentication.Plug.Helpers, only: [store_in_session: 2]
  alias Helpdesk.Notifications.{Notification, OutboxEvent}
  alias Helpdesk.Support.Ticket
  alias Helpdesk.Accounts.User

  setup %{conn: conn} do
    user =
      Ash.create!(
        User,
        %{
          email: "#{Ash.UUID.generate()}@example.com",
          password: "password123",
          password_confirmation: "password123",
          first_name: "Test",
          last_name: "User"
        },
        action: :register_with_password,
        authorize?: false
      )

    ticket =
      Ash.create!(
        Ticket,
        %{title: "Billing help", description: "Please explain my bill", priority: :medium},
        action: :create_ticket,
        actor: user
      )

    %{conn: conn |> init_test_session(%{}) |> store_in_session(user), user: user, ticket: ticket}
  end

  test "lists notifications, marks read, filters unread and opens a ticket", ctx do
    notification = notification(ctx)
    {:ok, view, _} = live(ctx.conn, "/notifications")
    assert has_element?(view, "#notification-badge", "1")
    assert has_element?(view, "#open-#{notification.id}")
    view |> element("#read-#{notification.id}") |> render_click()
    refute has_element?(view, "#notification-badge")
    view |> element("#notifications-filter-unread") |> render_click()
    assert has_element?(view, "#notifications-empty")
    view |> element("#notifications-filter-all") |> render_click()
    view |> element("#open-#{notification.id}") |> render_click()
    assert_redirect(view, "/tickets/#{ctx.ticket.id}")
  end

  test "pagination and mark all read", ctx do
    for _ <- 1..21, do: notification(ctx)
    {:ok, view, _} = live(ctx.conn, "/notifications")
    assert has_element?(view, "#notifications-next:not([disabled])")
    view |> element("#notifications-next") |> render_click()
    assert has_element?(view, "#notifications-next[disabled]")
    view |> element("#notifications-previous") |> render_click()
    assert has_element?(view, "#notifications-previous[disabled]")
    view |> element("#mark-all-notifications-read") |> render_click()
    assert {:ok, 0} = Helpdesk.Notifications.unread_count(ctx.user)
    refute has_element?(view, "#notification-badge")
  end

  test "subscription refresh updates inbox and bell", ctx do
    {:ok, view, _} = live(ctx.conn, "/notifications")
    assert has_element?(view, "#notifications-empty")
    notification = notification(ctx)
    # The same refresh message used by the coalescing subscription hook.
    send(view.pid, :refresh_notification_state)
    assert has_element?(view, "#open-#{notification.id}")
    assert has_element?(view, "#notification-badge", "1")
  end

  test "mark all read preserves notifications newer than the cutoff", ctx do
    earlier = notification(ctx)
    cutoff = DateTime.utc_now()
    later = notification(ctx)

    Helpdesk.Repo.update!(
      Ecto.Changeset.change(later, inserted_at: DateTime.add(cutoff, 1, :second))
    )

    assert {:ok, :ok} = Helpdesk.Notifications.mark_all_read(ctx.user, cutoff)
    assert Helpdesk.Repo.get!(Notification, earlier.id).read_at
    assert is_nil(Helpdesk.Repo.get!(Notification, later.id).read_at)
  end

  test "anonymous visitors must sign in" do
    assert {:error, {:redirect, %{to: "/sign-in"}}} =
             live(build_conn(), "/notifications")
  end

  test "saves email preferences without disabling in-app notifications", ctx do
    notification(ctx)
    {:ok, view, _} = live(ctx.conn, "/notifications")

    view
    |> form("#notification-preferences", preferences: %{resolved: "false"})
    |> render_submit()

    assert {:ok, preferences} = Helpdesk.Notifications.email_preferences(ctx.user)
    refute preferences["resolved"]
    assert has_element?(view, "#notification-badge", "1")
  end

  test "unavailable notification cannot navigate", ctx do
    {:ok, view, _} = live(ctx.conn, "/notifications")
    render_click(view, "open", %{"id" => Ash.UUID.generate()})
    assert has_element?(view, "#flash-error")
  end

  defp notification(ctx) do
    event =
      Ash.create!(
        OutboxEvent,
        %{
          source_event_id: Ash.UUID.generate(),
          ticket_id: ctx.ticket.id,
          kind: :resolved,
          candidate_recipient_ids: [ctx.user.id],
          occurred_at: DateTime.utc_now()
        },
        action: :enqueue,
        authorize?: false
      )

    Ash.create!(
      Notification,
      %{
        outbox_event_id: event.id,
        recipient_id: ctx.user.id,
        ticket_id: ctx.ticket.id,
        kind: "resolved"
      },
      action: :deliver,
      authorize?: false
    )
  end
end
