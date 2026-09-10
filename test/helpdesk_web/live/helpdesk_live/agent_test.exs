defmodule HelpdeskWeb.HelpdeskLive.AgentTest do
  use HelpdeskWeb.ConnCase
  import Phoenix.LiveViewTest
  import AshAuthentication.Plug.Helpers, only: [store_in_session: 2]
  alias Helpdesk.Accounts.User
  alias Helpdesk.Support.{Ticket, Team, TeamMembership, Message}

  test "agent inbox filters tickets and enforces update access", %{conn: conn} do
    agent = user!(:agent)
    own = ticket!(agent.id)
    other = ticket!(nil)
    conn = login(conn, agent)
    assert {:error, {:redirect, %{to: "/inbox"}}} = live(conn, ~p"/tickets")
    {:ok, view, _} = live(conn, ~p"/inbox?#{%{id: own.id}}")
    assert has_element?(view, "#agent-dashboard")
    assert has_element?(view, "#tickets-#{own.id}")
    assert has_element?(view, "#tickets-#{other.id}")
    view |> form("#inbox-filters", filters: %{scope: "mine"}) |> render_change()
    assert has_element?(view, "#tickets-#{own.id}")
    refute has_element?(view, "#tickets-#{other.id}")
    {:ok, view, _} = live(conn, ~p"/inbox?#{%{id: other.id}}")
    refute has_element?(view, "#agent-status")
    render_submit(view, "status", %{"status" => %{"status" => "closed"}})
    assert Helpdesk.Repo.get!(Ticket, other.id).status == :open
  end

  test "agent posts replies and notes, updates status, priority and assignment", %{conn: conn} do
    agent = user!(:agent)
    ticket = ticket!(agent.id)
    team = Ash.Seed.seed!(Team, %{name: "Support"})
    Ash.Seed.seed!(TeamMembership, %{team_id: team.id, user_id: agent.id})
    conn = login(conn, agent)
    {:ok, view, _} = live(conn, ~p"/inbox?#{%{id: ticket.id}}")
    view |> form("#agent-message-form", message: %{body: "Public response"}) |> render_submit()
    assert Helpdesk.Repo.get_by!(Message, body: "Public response").message_type == :public_reply
    view |> element("#internal-mode") |> render_click()

    view
    |> form("#agent-message-form", message: %{body: "Private investigation"})
    |> render_submit()

    note = Helpdesk.Repo.get_by!(Message, body: "Private investigation")
    assert note.message_type == :internal_note
    assert has_element?(view, "#messages-#{note.id}")
    view |> form("#agent-status", status: %{status: "resolved"}) |> render_submit()
    assert Helpdesk.Repo.get!(Ticket, ticket.id).resolved_at
    view |> form("#agent-priority", priority: %{priority: "high"}) |> render_submit()
    assert Helpdesk.Repo.get!(Ticket, ticket.id).priority == :high
    view |> form("#agent-assignment", assignment: %{team_id: team.id}) |> render_change()
    assert has_element?(view, "#assignment_assignee_id option[value='#{agent.id}']")

    view
    |> form("#agent-assignment", assignment: %{team_id: team.id, assignee_id: agent.id})
    |> render_submit()

    assert Helpdesk.Repo.get!(Ticket, ticket.id).team_id == team.id
  end

  test "customer and anonymous users cannot enter agent inbox", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/inbox")

    assert {:error, {:redirect, %{to: "/tickets"}}} =
             live(login(conn, user!(:customer)), ~p"/inbox")
  end

  test "selecting tickets resets attachments and respects attachment access", %{conn: conn} do
    agent = user!(:agent)
    ticket = ticket!(agent.id)
    other = ticket!(nil)

    message =
      Ash.Seed.seed!(Message, %{
        ticket_id: ticket.id,
        user_id: agent.id,
        message_type: :internal_note,
        body: "Investigation",
        source: :web
      })

    attrs = %{
      file_name: "evidence.png",
      file_path: "https://example.com/evidence.png",
      content_type: "image/png",
      byte_size: 10
    }

    direct =
      Ash.Seed.seed!(
        Helpdesk.Support.Attachment,
        Map.merge(attrs, %{ticket_id: ticket.id, storage_key: Ash.UUID.generate()})
      )

    nested =
      Ash.Seed.seed!(
        Helpdesk.Support.Attachment,
        Map.merge(attrs, %{message_id: message.id, storage_key: Ash.UUID.generate()})
      )

    private =
      Ash.Seed.seed!(
        Helpdesk.Support.Attachment,
        Map.merge(attrs, %{ticket_id: other.id, storage_key: Ash.UUID.generate()})
      )

    {:ok, view, _} = live(login(conn, agent), ~p"/inbox?#{%{id: ticket.id}}")

    assert has_element?(
             view,
             "#attachments-#{direct.id} a[href='/attachments/#{direct.id}/download']"
           )

    assert has_element?(view, "#attachments-#{nested.id}")
    refute has_element?(view, "#attachments-#{private.id}")
    view |> element("#tickets-#{other.id}") |> render_click()
    assert has_element?(view, "#inbox-attachments-empty:only-child")
    refute has_element?(view, "#attachments-#{direct.id}")
    refute has_element?(view, "#attachments-#{nested.id}")
    refute has_element?(view, "#attachments-#{private.id}")
  end

  test "assigned agents attach files, and switching tickets clears pending uploads", %{conn: conn} do
    previous_s3 = Application.get_env(:ex_aws, :s3)

    variables = %{
      "AWS_ENDPOINT_URL_S3" => "https://storage.example.com/",
      "BUCKET_NAME" => "test-bucket",
      "AWS_ACCESS_KEY_ID" => "test-key",
      "AWS_SECRET_ACCESS_KEY" => "test-secret"
    }

    previous_env = Map.new(variables, fn {key, _} -> {key, System.get_env(key)} end)
    System.put_env(variables)
    Application.put_env(:ex_aws, :s3, host: "storage.example.com")

    on_exit(fn ->
      Enum.each(previous_env, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)

      if previous_s3,
        do: Application.put_env(:ex_aws, :s3, previous_s3),
        else: Application.delete_env(:ex_aws, :s3)
    end)

    agent = user!(:agent)
    ticket = ticket!(agent.id)
    other = ticket!(nil)
    {:ok, view, _} = live(login(conn, agent), ~p"/inbox?#{%{id: ticket.id}}")
    assert has_element?(view, "#agent-attachments-form")

    upload =
      file_input(view, "#agent-attachments-form", :attachments, [
        %{name: "evidence.pdf", content: "test evidence", type: "application/pdf"}
      ])

    render_upload(upload, "evidence.pdf", 100)
    view |> form("#agent-attachments-form") |> render_submit()
    attachment = Helpdesk.Repo.get_by!(Helpdesk.Support.Attachment, file_name: "evidence.pdf")
    assert attachment.ticket_id == ticket.id
    assert has_element?(view, "#attachments-#{attachment.id}")
    assert Ash.count!(Ticket, authorize?: false) == 2

    file_input(view, "#agent-attachments-form", :attachments, [
      %{name: "pending.pdf", content: "pending", type: "application/pdf"}
    ])

    view |> element("#tickets-#{other.id}") |> render_click()
    refute has_element?(view, "#agent-attachments-form")
    render_submit(view, "save-uploads", %{})
    assert Ash.count!(Helpdesk.Support.Attachment, authorize?: false) == 1
    view |> element("#tickets-#{ticket.id}") |> render_click()
    assert has_element?(view, "#save-ticket-attachments[disabled]")
  end

  defp login(conn, user), do: conn |> init_test_session(%{}) |> store_in_session(user)

  defp user!(role) do
    user =
      Ash.Seed.seed!(User, %{
        first_name: "Alex",
        last_name: "Morgan",
        role: role,
        email: "agent-view-#{Ash.UUID.generate()}@example.com",
        hashed_password: "unused"
      })

    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)
    Ash.Resource.put_metadata(user, :token, token)
  end

  defp ticket!(assignee_id) do
    Ash.Seed.seed!(Ticket, %{
      title: "Support question",
      description: "A detailed customer request.",
      ticket_number: Ash.UUID.generate(),
      reporter_id: user!(:customer).id,
      assignee_id: assignee_id,
      status: :open,
      priority: :medium,
      source: :web
    })
  end
end
