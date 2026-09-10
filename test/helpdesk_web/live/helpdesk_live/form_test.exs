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
    assert Enum.sort(Enum.map(attachments, & &1.file_name)) == ["first.png", "second.png"]

    assert Enum.all?(attachments, fn attachment ->
             attachment.ticket_id == ticket.id and
               attachment.file_path ==
                 "https://storage.example.com/test-bucket/#{attachment.storage_key}"
           end)
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
