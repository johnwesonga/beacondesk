defmodule HelpdeskWeb.HelpdeskLive.CustomerTest do
  use HelpdeskWeb.ConnCase
  import Phoenix.LiveViewTest
  import AshAuthentication.Plug.Helpers, only: [store_in_session: 2]
  alias Helpdesk.Accounts.User
  alias Helpdesk.Support.{Ticket, Message}

  test "overview and queue show only the customer's tickets and search works", %{conn: conn} do
    user = user!(:customer)
    own = ticket!(user, "Billing question")
    other = ticket!(user!(:customer), "Private issue")
    conn = login(conn, user)
    {:ok, view, _} = live(conn, ~p"/portal")
    assert has_element?(view, "#recent-#{own.id}[href='/tickets/#{own.id}']")
    refute has_element?(view, "#recent-#{other.id}")
    refute has_element?(view, "nav a[href='/admin']")
    view |> form("#customer-search", search: %{q: "Billing"}) |> render_submit()
    assert_redirect(view, "/tickets?q=Billing")
    {:ok, view, _} = live(conn, ~p"/tickets")
    assert has_element?(view, "#customer-tickets")
    assert has_element?(view, "#tickets-#{own.id}")
    refute has_element?(view, "#tickets-#{other.id}")
    view |> form("#ticket-filters", filters: %{q: "missing"}) |> render_change()
    assert has_element?(view, "#tickets-empty:only-child")
  end

  test "conversation excludes internal notes and replies cannot change author or target", %{
    conn: conn
  } do
    user = user!(:customer)
    ticket = ticket!(user, "Conversation test")
    other = ticket!(user!(:customer), "Private issue")
    staff = user!(:agent)
    public = message!(ticket, staff, :public_reply, "Public answer")
    internal = message!(ticket, staff, :internal_note, "Staff eyes only")
    conn = login(conn, user)
    {:ok, view, _} = live(conn, ~p"/tickets/#{ticket.id}")
    assert has_element?(view, "#messages-#{public.id}", "Public answer")
    refute has_element?(view, "#messages-#{internal.id}")
    view |> form("#customer-reply", reply: %{body: "   "}) |> render_submit()
    assert has_element?(view, "#customer-reply .text-error")

    render_submit(view, "send-reply", %{
      "reply" => %{
        "body" => " Thanks for your help ",
        "ticket_id" => other.id,
        "user_id" => staff.id,
        "message_type" => "internal_note",
        "body_format" => "html"
      }
    })

    reply = Helpdesk.Repo.get_by!(Message, body: "Thanks for your help")
    assert reply.ticket_id == ticket.id
    assert reply.user_id == user.id
    assert reply.message_type == :public_reply
    assert reply.body_format == :plain_text
    assert has_element?(view, "#messages-#{reply.id}")
    assert {:error, {:live_redirect, %{to: "/tickets"}}} = live(conn, ~p"/tickets/#{other.id}")
    assert {:error, {:live_redirect, %{to: "/tickets"}}} = live(conn, "/tickets/invalid-id")
  end

  test "customer can submit a ticket and see it in the queue", %{conn: conn} do
    user = user!(:customer)
    conn = login(conn, user)
    {:ok, view, _} = live(conn, ~p"/ticket/new")
    assert has_element?(view, "nav a[href='/portal']")

    view
    |> form("#ticket-form",
      ticket: %{
        title: "A billing question",
        description: "Please explain this invoice charge.",
        category: "billing",
        priority: "medium"
      }
    )
    |> render_submit()

    assert_redirect(view, "/tickets")
    ticket = Helpdesk.Repo.get_by!(Ticket, title: "A billing question")
    assert ticket.reporter_id == user.id
    {:ok, view, _} = live(conn, ~p"/tickets")
    assert has_element?(view, "#tickets-#{ticket.id}")
  end

  test "empty overview, help page and authentication guard", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/portal")
    conn = login(conn, user!(:customer))
    {:ok, view, _} = live(conn, ~p"/portal")
    assert has_element?(view, "#recent-empty:only-child")
    {:ok, view, _} = live(conn, ~p"/help")
    assert has_element?(view, "#knowledge-base")
    assert has_element?(view, "#kb-search-form")
  end

  test "ticket details show permitted attachments and staff messages", %{conn: conn} do
    customer = user!(:customer)
    admin = user!(:admin)
    ticket = ticket!(customer, "Attachment visibility")
    note = message!(ticket, admin, :internal_note, "Internal details")

    public =
      Ash.Seed.seed!(Helpdesk.Support.Attachment, %{
        ticket_id: ticket.id,
        file_name: "request.png",
        file_path: "https://example.com/request.png",
        storage_key: Ash.UUID.generate(),
        content_type: "image/png",
        byte_size: 10
      })

    private =
      Ash.Seed.seed!(Helpdesk.Support.Attachment, %{
        ticket_id: ticket.id,
        message_id: note.id,
        file_name: "internal.png",
        file_path: "https://example.com/internal.png",
        storage_key: Ash.UUID.generate(),
        content_type: "image/png",
        byte_size: 20
      })

    {:ok, view, _} = live(login(conn, customer), ~p"/tickets/#{ticket.id}")
    assert has_element?(view, "#ticket-details")

    assert has_element?(
             view,
             "#attachments-#{public.id} a[href='/attachments/#{public.id}/download']"
           )

    refute has_element?(view, "#attachments-#{private.id}")

    assert has_element?(
             view,
             "#attachment-thumbnail-#{public.id}[src='/attachments/#{public.id}/download'][loading='lazy']"
           )

    refute has_element?(view, "#attachment-thumbnail-#{private.id}")
    refute has_element?(view, "#messages-#{note.id}")
    assert get(login(conn, customer), ~p"/attachments/#{private.id}/download").status == 404
    {:ok, view, _} = live(login(conn, admin), ~p"/tickets/#{ticket.id}")
    assert has_element?(view, "#attachments-#{private.id}")
    assert has_element?(view, "#attachment-thumbnail-#{private.id}")
    assert has_element?(view, "#messages-#{note.id}")
  end

  defp login(conn, user), do: conn |> init_test_session(%{}) |> store_in_session(user)

  defp user!(role) do
    user =
      Ash.Seed.seed!(User, %{
        first_name: "Jamie",
        last_name: "Rivera",
        role: role,
        email: "customer-view-#{Ash.UUID.generate()}@example.com",
        hashed_password: "unused"
      })

    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)
    Ash.Resource.put_metadata(user, :token, token)
  end

  defp ticket!(user, title) do
    Ash.Seed.seed!(Ticket, %{
      title: title,
      description: "A detailed description of the request.",
      ticket_number: Ash.UUID.generate(),
      reporter_id: user.id,
      status: :open,
      priority: :medium,
      source: :web
    })
  end

  defp message!(ticket, user, type, body) do
    Ash.Seed.seed!(Message, %{
      ticket_id: ticket.id,
      user_id: user.id,
      message_type: type,
      body: body,
      source: :web
    })
  end
end
