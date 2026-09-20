defmodule HelpdeskWeb.HelpdeskLive.MessageAttachmentsTest do
  use HelpdeskWeb.ConnCase
  import Phoenix.LiveViewTest
  import AshAuthentication.Plug.Helpers, only: [store_in_session: 2]
  alias Helpdesk.Accounts.User
  alias Helpdesk.Support.{Attachment, Message, Ticket}
  alias Helpdesk.Repo

  setup do
    variables = %{
      "AWS_ENDPOINT_URL_S3" => "https://storage.example.com/",
      "BUCKET_NAME" => "test-bucket",
      "AWS_ACCESS_KEY_ID" => "test-key",
      "AWS_SECRET_ACCESS_KEY" => "test-secret"
    }

    previous = Map.new(variables, fn {key, _} -> {key, System.get_env(key)} end)
    previous_s3 = Application.get_env(:ex_aws, :s3)
    System.put_env(variables)
    Application.put_env(:ex_aws, :s3, host: "storage.example.com")

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)

      if previous_s3,
        do: Application.put_env(:ex_aws, :s3, previous_s3),
        else: Application.delete_env(:ex_aws, :s3)
    end)

    customer = user!(:customer)
    agent = user!(:agent)
    ticket = ticket!(customer, agent)
    %{customer: customer, agent: agent, ticket: ticket}
  end

  test "customer reply attachments persist with the message and retain uploads after failure",
       ctx do
    {:ok, view, _} = live(login(ctx.conn, ctx.customer), ~p"/tickets/#{ctx.ticket.id}")
    upload!(view, "#customer-reply")
    Req.Test.stub(Helpdesk.AttachmentStore, &Plug.Conn.send_resp(&1, 404, "missing"))
    Req.Test.allow(Helpdesk.AttachmentStore, self(), view.pid)
    view |> form("#customer-reply", reply: %{body: "Evidence for my request."}) |> render_submit()
    assert Ash.count!(Message, authorize?: false) == 0
    assert Ash.count!(Attachment, authorize?: false) == 0
    assert Ash.count!(Helpdesk.Support.TicketEvent, authorize?: false) == 0
    assert has_element?(view, "#flash-error", "Your message was not sent")
    assert has_element?(view, "#customer-reply textarea", "Evidence for my request.")
    Req.Test.stub(Helpdesk.AttachmentStore, &Plug.Conn.send_resp(&1, 200, "abc"))
    view |> form("#customer-reply", reply: %{body: "   "}) |> render_submit()
    assert Ash.count!(Message, authorize?: false) == 0
    view |> form("#customer-reply", reply: %{body: "Evidence for my request."}) |> render_submit()
    [message] = Ash.read!(Message, actor: ctx.customer)
    [attachment] = Ash.read!(Attachment, actor: ctx.customer)
    assert attachment.message_id == message.id
    assert attachment.ticket_id == ctx.ticket.id

    assert attachment.checksum ==
             "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    assert has_element?(view, "#messages-#{message.id} #message-file-#{attachment.id} a")
    assert has_element?(view, "#message-attachment-thumbnail-#{attachment.id}")

    assert Repo.get_by!(Helpdesk.Audit.Event, action: "attach_to_message").ticket_id ==
             ctx.ticket.id
  end

  test "internal-note attachments stay hidden from the customer", ctx do
    {:ok, view, _} = live(login(ctx.conn, ctx.agent), ~p"/inbox?#{%{id: ctx.ticket.id}}")
    view |> element("#internal-mode") |> render_click()
    upload!(view, "#agent-message-form")
    Req.Test.stub(Helpdesk.AttachmentStore, &Plug.Conn.send_resp(&1, 200, "abc"))
    Req.Test.allow(Helpdesk.AttachmentStore, self(), view.pid)
    view |> form("#agent-message-form", message: %{body: "Internal evidence."}) |> render_submit()
    [message] = Ash.read!(Message, actor: ctx.agent)
    [attachment] = Ash.read!(Attachment, actor: ctx.agent)
    assert message.message_type == :internal_note
    assert attachment.message_id == message.id
    assert has_element?(view, "#message-file-#{attachment.id}")
    assert Ash.read!(Attachment, actor: ctx.customer) == []
    {:ok, customer_view, _} = live(login(ctx.conn, ctx.customer), ~p"/tickets/#{ctx.ticket.id}")
    refute has_element?(customer_view, "#message-file-#{attachment.id}")

    assert get(login(ctx.conn, ctx.customer), ~p"/attachments/#{attachment.id}/download").status ==
             404
  end

  test "mode changes and ticket switches clear pending reply uploads", ctx do
    other = ticket!(ctx.customer, ctx.agent)
    {:ok, view, _} = live(login(ctx.conn, ctx.agent), ~p"/inbox?#{%{id: ctx.ticket.id}}")
    upload!(view, "#agent-message-form")
    assert has_element?(view, "#agent-message-form progress")
    view |> element("#internal-mode") |> render_click()
    refute has_element?(view, "#agent-message-form progress")
    upload!(view, "#agent-message-form")
    view |> element("#tickets-#{other.id}") |> render_click()
    refute has_element?(view, "#agent-message-form progress")

    view
    |> form("#agent-message-form", message: %{body: "Reply without old attachments."})
    |> render_submit()

    assert Ash.count!(Attachment, authorize?: false) == 0
  end

  test "only an authorized message author can attach and ticket IDs cannot be forged", ctx do
    message =
      Ash.create!(Message, %{ticket_id: ctx.ticket.id, body: "Customer message", source: :web},
        action: :add_reply,
        actor: ctx.customer
      )

    attrs = %{
      message_id: message.id,
      file_name: "test.png",
      file_path: "test.png",
      storage_key: Ash.UUID.generate(),
      content_type: "image/png",
      byte_size: 3
    }

    for actor <- [nil, ctx.agent, user!(:customer)] do
      assert {:error, _} = Ash.create(Attachment, attrs, action: :attach_to_message, actor: actor)
    end

    assert {:error, _} =
             Ash.create(Attachment, Map.put(attrs, :ticket_id, Ash.UUID.generate()),
               action: :attach_to_message,
               actor: ctx.customer
             )

    assert Ash.count!(Attachment, authorize?: false) == 0
  end

  defp upload!(view, form_id) do
    view
    |> file_input(form_id, :message_attachments, [
      %{name: "evidence.png", content: "abc", type: "image/png"}
    ])
    |> render_upload("evidence.png", 100)
  end

  defp ticket!(customer, agent) do
    Ash.Seed.seed!(Ticket, %{
      title: "Reply attachments",
      description: "Customer needs to send supporting evidence.",
      ticket_number: Ash.UUID.generate(),
      reporter_id: customer.id,
      assignee_id: agent.id,
      status: :open,
      priority: :medium,
      source: :web
    })
  end

  defp user!(role) do
    user =
      Ash.Seed.seed!(User, %{
        first_name: "Test",
        last_name: "User",
        email: "message-files-#{Ash.UUID.generate()}@example.com",
        hashed_password: "unused",
        role: role
      })

    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)
    Ash.Resource.put_metadata(user, :token, token)
  end

  defp login(conn, user), do: conn |> init_test_session(%{}) |> store_in_session(user)
end
