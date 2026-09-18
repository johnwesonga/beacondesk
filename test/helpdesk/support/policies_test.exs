defmodule Helpdesk.Support.PoliciesTest do
  use Helpdesk.DataCase

  alias Helpdesk.Accounts.User
  alias Helpdesk.Audit.Event, as: AuditEvent
  alias Helpdesk.Support.{Attachment, Message, Team, TeamMembership, Ticket, TicketEvent}

  setup do
    # The project has no migrations yet. These temporary tables exercise the
    # real SQLite policy queries and disappear with the sandbox transaction.
    for {table, columns} <- [
          {"teams", "name TEXT, email TEXT, active INTEGER, inserted_at TEXT, updated_at TEXT"},
          {"team_memberships", "user_id TEXT, team_id TEXT"},
          {"tickets",
           "ticket_number TEXT, title TEXT, description TEXT, status TEXT, priority TEXT, source TEXT,
            category TEXT, due_at TEXT, resolved_at TEXT, closed_at TEXT, inserted_at TEXT,
            updated_at TEXT, assignee_id TEXT, reporter_id TEXT, customer_id TEXT,
            created_by_id TEXT, team_id TEXT"},
          {"messages",
           "body TEXT, body_format TEXT, message_type TEXT, source TEXT, external_message_id TEXT,
            edited_at TEXT, inserted_at TEXT, updated_at TEXT, ticket_id TEXT, user_id TEXT"},
          {"attachments",
           "file_name TEXT, file_path TEXT, content_type TEXT, byte_size INTEGER, storage_key TEXT,
            checksum TEXT, created_at TEXT, ticket_id TEXT, message_id TEXT"},
          {"ticket_events",
           "event_type TEXT, field_name TEXT, old_value TEXT, new_value TEXT, metadata TEXT,
            inserted_at TEXT, updated_at TEXT, ticket_id TEXT,
            user_id TEXT"}
        ] do
      Ecto.Adapters.SQL.query!(
        Repo,
        "CREATE TEMP TABLE #{table} (id TEXT PRIMARY KEY, #{columns})"
      )
    end

    customer = user(:customer)
    outsider = user(:customer)
    agent = user(:agent)
    other_agent = user(:agent)
    admin = user(:admin)
    team = Ash.Seed.seed!(Team, %{name: "Support"})
    membership = Ash.Seed.seed!(TeamMembership, %{user_id: agent.id, team_id: team.id})
    ticket = ticket(customer, %{team_id: team.id})
    public_reply = message(ticket, customer, :public_reply)
    internal_note = message(ticket, agent, :internal_note)

    %{
      customer: customer,
      outsider: outsider,
      agent: agent,
      other_agent: other_agent,
      admin: admin,
      team: team,
      membership: membership,
      ticket: ticket,
      public_reply: public_reply,
      internal_note: internal_note
    }
  end

  test "anonymous actors cannot read any support resource" do
    for resource <- [Ticket, Message, Attachment, TicketEvent, Team, TeamMembership] do
      assert {:ok, []} = Ash.read(resource, actor: nil)
    end
  end

  test "staff read all tickets and customers read only their reported tickets", ctx do
    assigned = ticket(ctx.outsider, %{assignee_id: ctx.other_agent.id})
    assert ids(Ticket, ctx.customer) == [ctx.ticket.id]
    assert Enum.sort(ids(Ticket, ctx.agent)) == Enum.sort([ctx.ticket.id, assigned.id])
    assert Enum.sort(ids(Ticket, ctx.other_agent)) == Enum.sort([ctx.ticket.id, assigned.id])
    assert Enum.sort(ids(Ticket, ctx.admin)) == Enum.sort([ctx.ticket.id, assigned.id])
  end

  test "being assigned or a team member does not grant staff access to customers", ctx do
    Ash.Seed.seed!(TeamMembership, %{user_id: ctx.outsider.id, team_id: ctx.team.id})
    ticket(ctx.customer, %{assignee_id: ctx.outsider.id})
    assert ids(Ticket, ctx.outsider) == []
  end

  test "internal notes are hidden from the reporter and unrelated agents", ctx do
    assert ids(Message, ctx.customer) == [ctx.public_reply.id]
    assert ids(Message, ctx.outsider) == []
    assert ids(Message, ctx.other_agent) == []

    assert Enum.sort(ids(Message, ctx.agent)) ==
             Enum.sort([ctx.public_reply.id, ctx.internal_note.id])

    assert Enum.sort(ids(Message, ctx.admin)) ==
             Enum.sort([ctx.public_reply.id, ctx.internal_note.id])
  end

  test "reply creation checks the target ticket and internal notes require staff access", ctx do
    params = %{ticket_id: ctx.ticket.id, body: "Reply", source: :web}

    assert {:ok, %Message{user_id: user_id}} =
             Ash.create(Message, params, action: :add_reply, actor: ctx.customer)

    assert user_id == ctx.customer.id

    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.create(Message, params, action: :add_reply, actor: ctx.outsider)

    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.create(Message, params, action: :add_internal_note, actor: ctx.customer)

    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.create(Message, params, action: :add_internal_note, actor: ctx.other_agent)

    assert {:ok, %Message{message_type: :internal_note}} =
             Ash.create(Message, params, action: :add_internal_note, actor: ctx.agent)

    assert length(Ash.read!(Message, actor: ctx.admin)) == 4
  end

  test "attachments inherit message privacy and reject inconsistent parents", ctx do
    public = attachment(%{ticket_id: ctx.ticket.id, message_id: ctx.public_reply.id})
    internal = attachment(%{ticket_id: ctx.ticket.id, message_id: ctx.internal_note.id})
    direct = attachment(%{ticket_id: ctx.ticket.id})
    message_only = attachment(%{message_id: ctx.public_reply.id})
    other_ticket = ticket(ctx.outsider)
    attachment(%{ticket_id: other_ticket.id, message_id: ctx.internal_note.id})
    attachment(%{})

    assert Enum.sort(ids(Attachment, ctx.customer)) ==
             Enum.sort([public.id, direct.id, message_only.id])

    assert Enum.sort(ids(Attachment, ctx.agent)) ==
             Enum.sort([public.id, internal.id, direct.id, message_only.id])

    assert ids(Attachment, ctx.outsider) == []
    assert ids(Attachment, ctx.other_agent) == []
  end

  test "only admins manage teams and memberships", ctx do
    for actor <- [nil, ctx.customer, ctx.agent] do
      refute Ash.can?({Team, :create}, actor)
      refute Ash.can?({ctx.team, :update}, actor)
      refute Ash.can?({TeamMembership, :create}, actor)
      refute Ash.can?({ctx.membership, :update}, actor)
    end

    assert Ash.can?({Team, :create}, ctx.admin)
    assert Ash.can?({ctx.team, :update}, ctx.admin)
    assert Ash.can?({TeamMembership, :create}, ctx.admin)
    assert Ash.can?({ctx.membership, :update}, ctx.admin)
    assert ids(Team, ctx.agent) == [ctx.team.id]
    assert ids(Team, ctx.other_agent) == [ctx.team.id]
    assert ids(TeamMembership, ctx.agent) == [ctx.membership.id]
    assert ids(TeamMembership, ctx.other_agent) == []
  end

  test "events are staff-only and cannot be fabricated through authorized actions", ctx do
    event =
      Ash.Seed.seed!(TicketEvent, %{
        ticket_id: ctx.ticket.id,
        user_id: ctx.agent.id,
        event_type: "message_added",
        metadata: %{"message_type" => "internal_note"}
      })

    assert ids(TicketEvent, ctx.customer) == []
    assert ids(TicketEvent, ctx.agent) == [event.id]
    assert ids(TicketEvent, ctx.other_agent) == []
    assert ids(TicketEvent, ctx.admin) == [event.id]

    for actor <- [ctx.customer, ctx.agent, ctx.admin] do
      refute Ash.can?({TicketEvent, :create_ticket_event}, actor)
    end
  end

  test "registration cannot choose a privileged role" do
    changeset =
      Ash.Changeset.for_create(User, :register_with_password, %{
        email: "customer@example.com",
        password: "password123",
        password_confirmation: "password123",
        role: :admin
      })

    refute changeset.valid?
    assert Ash.Changeset.get_attribute(changeset, :role) == :customer
  end

  test "ticket creation appends a creation event attributed to the reporter", ctx do
    created =
      Ash.create!(
        Ticket,
        %{
          title: "New request",
          description: "Please help with this request",
          status: :new,
          priority: :medium,
          source: :web
        },
        action: :create_ticket,
        actor: ctx.customer
      )

    assert [%TicketEvent{event_type: :ticket_created} = event] =
             Ash.read!(TicketEvent, actor: ctx.admin)

    assert event.ticket_id == created.id
    assert event.user_id == ctx.customer.id
    assert event.metadata == %{"action" => "create_ticket"}
  end

  test "assignment records changed fields and skips no-ops", ctx do
    new_team = Ash.Seed.seed!(Team, %{name: "Escalations"})
    Ash.Seed.seed!(TeamMembership, %{user_id: ctx.other_agent.id, team_id: new_team.id})
    params = %{assignee_id: ctx.other_agent.id, team_id: new_team.id}

    updated = Ash.update!(ctx.ticket, params, action: :assign, actor: ctx.admin)

    assert [event] = Ash.read!(AuditEvent)
    assert event.action == "ticket.assign"
    assert event.actor_id == ctx.admin.id
    assert event.ticket_id == ctx.ticket.id
    assert event.metadata == %{"changed_fields" => ["assignee_id", "team_id"]}

    Ash.update!(updated, params, action: :assign, actor: ctx.admin)
    assert length(Ash.read!(AuditEvent)) == 1

    Ash.update!(updated, %{assignee_id: nil}, action: :assign, actor: ctx.admin)

    assert Enum.any?(Ash.read!(AuditEvent), fn event ->
             event.metadata == %{"changed_fields" => ["assignee_id"]}
           end)
  end

  test "tickets can only be assigned to agents or administrators", ctx do
    Ash.Seed.seed!(TeamMembership, %{user_id: ctx.other_agent.id, team_id: ctx.team.id})
    Ash.Seed.seed!(TeamMembership, %{user_id: ctx.admin.id, team_id: ctx.team.id})

    assert {:ok, %Ticket{assignee_id: assignee_id}} =
             Ash.update(ctx.ticket, %{assignee_id: ctx.other_agent.id},
               action: :assign,
               actor: ctx.admin
             )

    assert assignee_id == ctx.other_agent.id

    assert {:ok, %Ticket{assignee_id: assignee_id}} =
             Ash.update(ctx.ticket, %{assignee_id: ctx.admin.id},
               action: :assign,
               actor: ctx.admin
             )

    assert assignee_id == ctx.admin.id

    assert {:error, error} =
             Ash.update(ctx.ticket, %{assignee_id: ctx.customer.id},
               action: :assign,
               actor: ctx.admin
             )

    assert Exception.message(error) =~ "must refer to an active agent or administrator"

    assert {:ok, %Ticket{assignee_id: nil}} =
             Ash.update(ctx.ticket, %{assignee_id: nil},
               action: :assign,
               actor: ctx.admin
             )
  end

  test "assignees must belong to the selected team", ctx do
    assert {:error, error} =
             Ash.update(ctx.ticket, %{assignee_id: ctx.other_agent.id},
               action: :assign,
               actor: ctx.admin
             )

    assert Exception.message(error) =~ "must be a member of the selected team"

    Ash.Seed.seed!(TeamMembership, %{user_id: ctx.other_agent.id, team_id: ctx.team.id})

    assigned =
      Ash.update!(ctx.ticket, %{assignee_id: ctx.other_agent.id},
        action: :assign,
        actor: ctx.admin
      )

    new_team = Ash.Seed.seed!(Team, %{name: "Specialists"})

    assert {:error, error} =
             Ash.update(assigned, %{team_id: new_team.id},
               action: :assign,
               actor: ctx.admin
             )

    assert Exception.message(error) =~ "must be a member of the selected team"

    Ash.Seed.seed!(TeamMembership, %{user_id: ctx.other_agent.id, team_id: new_team.id})

    assert {:ok, %Ticket{team_id: team_id}} =
             Ash.update(assigned, %{team_id: new_team.id},
               action: :assign,
               actor: ctx.admin
             )

    assert team_id == new_team.id
  end

  test "an assignee requires a team", ctx do
    ticket = ticket(ctx.customer, %{team_id: nil})

    assert {:error, error} =
             Ash.update(ticket, %{assignee_id: ctx.agent.id},
               action: :assign,
               actor: ctx.admin
             )

    assert Exception.message(error) =~ "must be selected when assigning a ticket"
  end

  test "tickets can only be assigned to active teams", ctx do
    active_team = Ash.Seed.seed!(Team, %{name: "Escalations", active: true})
    inactive_team = Ash.Seed.seed!(Team, %{name: "Former support team", active: false})

    assert {:ok, %Ticket{team_id: team_id}} =
             Ash.update(ctx.ticket, %{team_id: active_team.id},
               action: :assign,
               actor: ctx.admin
             )

    assert team_id == active_team.id

    assert {:error, error} =
             Ash.update(ctx.ticket, %{team_id: inactive_team.id},
               action: :assign,
               actor: ctx.admin
             )

    assert Exception.message(error) =~ "must refer to an active team"

    assert {:ok, %Ticket{team_id: nil}} =
             Ash.update(ctx.ticket, %{team_id: nil},
               action: :assign,
               actor: ctx.admin
             )
  end

  test "status, priority and detail edits retain previous entries", ctx do
    updated =
      Ash.update!(ctx.ticket, %{status: :resolved}, action: :change_status, actor: ctx.agent)

    updated = Ash.update!(updated, %{priority: :high}, action: :change_priority, actor: ctx.agent)
    Ash.update!(updated, %{title: "Updated title"}, action: :edit_details, actor: ctx.agent)
    events = Ash.read!(TicketEvent, actor: ctx.admin)
    assert length(events) == 3

    assert Enum.any?(
             events,
             &(&1.event_type == :status_changed and &1.old_value == "new" and
                 &1.new_value == "resolved")
           )

    assert Enum.any?(
             events,
             &(&1.event_type == :priority_changed and &1.old_value == "medium" and
                 &1.new_value == "high")
           )

    assert Enum.any?(events, &(&1.field_name == "title" and &1.new_value == "Updated title"))
    assert Enum.all?(events, &(&1.user_id == ctx.agent.id))
    refute Enum.any?(Ash.Resource.Info.actions(TicketEvent), &(&1.type in [:update, :destroy]))
  end

  test "status changes maintain resolved and closed timestamps", ctx do
    resolved =
      Ash.update!(ctx.ticket, %{status: :resolved}, action: :change_status, actor: ctx.agent)

    assert %DateTime{} = resolved.resolved_at
    assert resolved.closed_at == nil

    unchanged =
      Ash.update!(resolved, %{status: :resolved}, action: :change_status, actor: ctx.agent)

    assert unchanged.resolved_at == resolved.resolved_at
    assert unchanged.closed_at == nil

    closed = Ash.update!(unchanged, %{status: :closed}, action: :change_status, actor: ctx.agent)

    assert closed.resolved_at == resolved.resolved_at
    assert %DateTime{} = closed.closed_at

    reopened = Ash.update!(closed, %{status: :open}, action: :change_status, actor: ctx.agent)

    assert reopened.resolved_at == nil
    assert reopened.closed_at == nil
  end

  test "consecutive message events reference each message without copying its body", ctx do
    first_message =
      Ash.create!(Message, %{ticket_id: ctx.ticket.id, body: "Private content", source: :web},
        action: :add_internal_note,
        actor: ctx.agent
      )

    second_message =
      Ash.create!(Message, %{ticket_id: ctx.ticket.id, body: "Public content", source: :web},
        action: :add_reply,
        actor: ctx.agent
      )

    ticket_events = Ash.read!(TicketEvent, actor: ctx.admin)
    assert length(ticket_events) == 2
    assert Enum.all?(ticket_events, &(&1.event_type == :message_added))
    assert Enum.all?(ticket_events, &(&1.ticket_id == ctx.ticket.id))
    assert Enum.all?(ticket_events, &(&1.user_id == ctx.agent.id))

    assert Enum.any?(ticket_events, fn event ->
             event.metadata == %{
               "message_id" => first_message.id,
               "message_type" => "internal_note",
               "action" => "add_internal_note"
             }
           end)

    assert Enum.any?(ticket_events, fn event ->
             event.metadata == %{
               "message_id" => second_message.id,
               "message_type" => "public_reply",
               "action" => "add_reply"
             }
           end)

    audit_events = Ash.read!(AuditEvent)
    assert length(audit_events) == 2
    assert Enum.all?(audit_events, &(&1.ticket_id == ctx.ticket.id))
    assert Enum.all?(audit_events, &(&1.target_label == ctx.ticket.ticket_number))

    assert Enum.any?(audit_events, fn event ->
             event.action == "message.add.internal_note" and
               event.metadata == %{
                 "message_id" => first_message.id,
                 "message_type" => "internal_note"
               }
           end)

    assert Enum.any?(audit_events, fn event ->
             event.action == "message.add.reply" and
               event.metadata == %{
                 "message_id" => second_message.id,
                 "message_type" => "public_reply"
               }
           end)

    refute Enum.any?(audit_events, &(inspect(&1.metadata) =~ "content"))
  end

  test "rejected updates do not append events", ctx do
    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.update(ctx.ticket, %{status: :closed},
               action: :change_status,
               actor: ctx.outsider
             )

    assert {:error, %Ash.Error.Invalid{}} =
             Ash.update(ctx.ticket, %{status: :invalid}, action: :change_status, actor: ctx.admin)

    assert Ash.read!(TicketEvent, actor: ctx.admin) == []
    assert Ash.get!(Ticket, ctx.ticket.id, actor: ctx.admin).status == :new
  end

  test "an audit insert failure rolls back the update and earlier events", ctx do
    Ecto.Adapters.SQL.query!(Repo, """
    CREATE TEMP TRIGGER reject_audit_event BEFORE INSERT ON audit_events
    WHEN NEW.action = 'ticket.assign'
    BEGIN SELECT RAISE(ABORT, 'audit unavailable'); END
    """)

    new_team = Ash.Seed.seed!(Team, %{name: "Escalations"})

    assert {:error, _} =
             Ash.update(ctx.ticket, %{assignee_id: ctx.agent.id, team_id: new_team.id},
               action: :assign,
               actor: ctx.admin
             )

    assert Ash.read!(AuditEvent) == []
    ticket = Ash.get!(Ticket, ctx.ticket.id, actor: ctx.admin)
    assert ticket.assignee_id == nil
    assert ticket.team_id == ctx.team.id
  end

  defp user(role) do
    id = Ash.UUID.generate()

    Ash.Seed.seed!(User, %{
      id: id,
      role: role,
      email: Ash.CiString.new("#{role}-#{id}@example.com"),
      hashed_password: "not-used-in-tests"
    })
  end

  defp ids(resource, actor), do: resource |> Ash.read!(actor: actor) |> Enum.map(& &1.id)

  defp ticket(customer, extra \\ %{}) do
    Ash.Seed.seed!(
      Ticket,
      Map.merge(
        %{
          ticket_number: Ash.UUID.generate(),
          title: "Help",
          description: "Ticket details",
          status: :new,
          priority: :medium,
          source: :web,
          reporter_id: customer.id
        },
        extra
      )
    )
  end

  defp message(ticket, author, type) do
    Ash.Seed.seed!(Message, %{
      ticket_id: ticket.id,
      user_id: author.id,
      body: "Details",
      source: :web,
      message_type: type
    })
  end

  defp attachment(extra) do
    Ash.Seed.seed!(
      Attachment,
      Map.merge(
        %{
          file_name: "note.txt",
          file_path: "note.txt",
          content_type: "text/plain",
          byte_size: 10,
          storage_key: Ash.UUID.generate()
        },
        extra
      )
    )
  end
end
