defmodule HelpdeskWeb.HelpdeskLive.FormTest do
  use HelpdeskWeb.ConnCase

  import AshAuthentication.Plug.Helpers, only: [store_in_session: 2]
  import Phoenix.LiveViewTest

  alias Helpdesk.Accounts.User
  alias Helpdesk.Support.Ticket

  test "requires an authenticated user", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/ticket/new")
  end

  test "creates a ticket for the signed-in user", %{conn: conn} do
    user = register_user!()

    conn =
      conn
      |> init_test_session(%{})
      |> store_in_session(user)

    {:ok, view, _html} = live(conn, ~p"/ticket/new")

    assert has_element?(view, "#ticket-form")
    assert has_element?(view, "#ticket_title")
    assert has_element?(view, "#ticket_description")
    assert has_element?(view, "#ticket_category")
    assert has_element?(view, "#ticket_priority")
    assert has_element?(view, "#submit-ticket")

    view
    |> form("#ticket-form",
      ticket: %{
        title: "Card charged twice",
        description: "The same payment appears twice on my statement.",
        category: "billing",
        priority: "high"
      }
    )
    |> render_submit()

    assert_redirect(view, "/tickets")

    assert [ticket] = Ash.read!(Ticket, actor: user)
    assert ticket.title == "Card charged twice"
    assert ticket.description == "The same payment appears twice on my statement."
    assert ticket.category == :billing
    assert ticket.priority == :high
    assert ticket.status == :new
    assert ticket.source == :web
    assert ticket.reporter_id == user.id
  end

  test "saves one ticket with multiple attachments and retains uploads after validation errors",
       %{conn: conn} do
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

    user = register_user!()
    require Ecto.Query
    Helpdesk.Repo.update_all(Ecto.Query.where(User, id: ^user.id), set: [role: :admin])
    conn = conn |> init_test_session(%{}) |> store_in_session(user)
    {:ok, view, _} = live(conn, ~p"/ticket/new")

    upload =
      file_input(view, "#ticket-form", :attachments, [
        %{name: "first.png", content: "first image", type: "image/png"},
        %{name: "second.png", content: "second image", type: "image/png"}
      ])

    render_upload(upload, "first.png", 100)
    render_upload(upload, "second.png", 100)

    Req.Test.stub(Helpdesk.AttachmentStore, fn conn ->
      Plug.Conn.send_resp(conn, 200, "abc")
    end)

    Req.Test.allow(Helpdesk.AttachmentStore, self(), view.pid)

    view |> form("#ticket-form", ticket: %{title: "x", description: "short"}) |> render_submit()
    assert Ash.count!(Ticket, authorize?: false) == 0
    assert Ash.count!(Helpdesk.Support.Attachment, authorize?: false) == 0

    view
    |> form("#ticket-form",
      ticket: %{
        title: "Upload request",
        description: "A detailed description for support.",
        priority: "medium"
      }
    )
    |> render_submit()

    assert_redirect(view, "/tickets")
    assert [ticket] = Ash.read!(Ticket, authorize?: false)
    attachments = Ash.read!(Helpdesk.Support.Attachment, authorize?: false)
    assert length(attachments) == 2

    assert Enum.all?(
             attachments,
             &(&1.checksum ==
                 "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
           )

    assert Enum.sort(Enum.map(attachments, & &1.file_name)) == ["first.png", "second.png"]

    assert Enum.all?(attachments, fn attachment ->
             attachment.ticket_id == ticket.id and
               attachment.file_path ==
                 "https://storage.example.com/test-bucket/#{attachment.storage_key}"
           end)
  end

  test "assignment controls follow assignment permission", %{conn: conn} do
    for role <- [:customer, :agent, :admin] do
      user = register_user!()
      Helpdesk.Repo.update!(Ecto.Changeset.change(user, role: role))
      authenticated = conn |> init_test_session(%{}) |> store_in_session(user)
      {:ok, view, _} = live(authenticated, ~p"/ticket/new")
      assert has_element?(view, "#ticket-assignment") == role in [:agent, :admin]
    end
  end

  test "agents search customers and create a ticket on their behalf", %{conn: conn} do
    agent = user!(:agent, "Support", "Agent")
    customer = user!(:customer, "Jamie", "Rivera")
    disabled = user!(:customer, "Jamie", "Disabled", :disabled)
    staff = user!(:agent, "Jamie", "Staff")
    conn = conn |> init_test_session(%{}) |> store_in_session(agent)
    {:ok, view, _} = live(conn, ~p"/ticket/new")

    view
    |> form("#ticket-form",
      ticket: %{
        title: "Customer billing issue",
        description: "The customer was charged twice.",
        priority: "high"
      }
    )
    |> render_change()

    view |> element("#customer-search") |> render_change(customer_search: %{query: "JAMIE"})
    assert has_element?(view, "#customers-#{customer.id}")
    refute has_element?(view, "#customers-#{disabled.id}")
    refute has_element?(view, "#customers-#{staff.id}")

    view |> element("#customers-#{customer.id}") |> render_click()
    assert has_element?(view, "#selected-customer")
    assert has_element?(view, "#ticket_title[value='Customer billing issue']")
    assert has_element?(view, "#ticket_priority option[value='high'][selected]")

    view |> form("#ticket-form", ticket: %{title: "x"}) |> render_submit()
    assert has_element?(view, "#selected-customer")
    assert Ash.count!(Ticket, authorize?: false) == 0
    view |> form("#ticket-form", ticket: %{title: "Customer billing issue"}) |> render_change()

    view |> form("#ticket-form") |> render_submit()
    assert_redirect(view, "/tickets")
    assert [ticket] = Ash.read!(Ticket, actor: customer)
    assert ticket.customer_id == customer.id
    assert ticket.reporter_id == customer.id
    assert ticket.created_by_id == agent.id
    assert ticket.status == :new
    assert ticket.source == :web
    assert ticket.priority == :high
  end

  test "customer search handles short queries, no results, email lookup and clearing", %{
    conn: conn
  } do
    agent = user!(:agent, "Support", "Agent")
    customer = user!(:customer, "Jamie", "Rivera")
    conn = conn |> init_test_session(%{}) |> store_in_session(agent)
    {:ok, view, _} = live(conn, ~p"/ticket/new")

    view |> element("#customer-search") |> render_change(customer_search: %{query: "J"})
    refute has_element?(view, "#customers-#{customer.id}")

    view
    |> element("#customer-search")
    |> render_change(customer_search: %{query: "no-such-customer"})

    assert has_element?(view, "#customer-results-empty:only-child", "No active customers found.")

    view
    |> form("#ticket-form",
      ticket: %{
        title: "Customer request",
        description: "A detailed customer request.",
        priority: "medium"
      }
    )
    |> render_submit()

    assert Ash.count!(Ticket, authorize?: false) == 0

    view
    |> element("#customer-search")
    |> render_change(customer_search: %{query: to_string(customer.email)})

    view |> element("#customers-#{customer.id}") |> render_click()
    view |> element("#clear-customer") |> render_click()
    refute has_element?(view, "#selected-customer")
    assert has_element?(view, "#customer-search[value='']")

    view
    |> form("#ticket-form",
      ticket: %{
        title: "My own request",
        description: "A request for my own account.",
        priority: "medium"
      }
    )
    |> render_submit()

    assert_redirect(view, "/tickets")
    assert [ticket] = Ash.read!(Ticket, actor: agent)
    assert ticket.reporter_id == agent.id
    assert is_nil(ticket.customer_id)
  end

  test "customers cannot use the picker and staff cannot select disabled customers", %{conn: conn} do
    customer = user!(:customer, "Jamie", "Rivera")
    disabled = user!(:customer, "Inactive", "Customer", :disabled)
    authenticated = conn |> init_test_session(%{}) |> store_in_session(customer)
    {:ok, view, _} = live(authenticated, ~p"/ticket/new")
    refute has_element?(view, "#ticket-customer-picker")
    render_change(view, "search-customers", %{customer_search: %{query: "Jamie"}})
    render_click(view, "select-customer", %{id: customer.id})
    refute has_element?(view, "#selected-customer")

    agent = user!(:agent, "Support", "Agent")
    authenticated = conn |> init_test_session(%{}) |> store_in_session(agent)
    {:ok, view, _} = live(authenticated, ~p"/ticket/new")
    render_click(view, "select-customer", %{id: disabled.id})
    refute has_element?(view, "#selected-customer")
    render_click(view, "select-customer", %{id: "invalid"})
    refute has_element?(view, "#selected-customer")
  end

  defp user!(role, first_name, last_name, status \\ :active) do
    user =
      Ash.Seed.seed!(User, %{
        first_name: first_name,
        last_name: last_name,
        email: "customer-picker-#{Ash.UUID.generate()}@example.com",
        hashed_password: "unused",
        role: role,
        status: status
      })

    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)
    Ash.Resource.put_metadata(user, :token, token)
  end

  defp register_user! do
    email = "ticket-form-#{System.unique_integer([:positive])}@example.com"
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
