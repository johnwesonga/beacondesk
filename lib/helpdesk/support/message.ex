defmodule Helpdesk.Support.Message do
  use Ash.Resource,
    otp_app: :helpdesk,
    domain: Helpdesk.Support,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    table "messages"
    repo Helpdesk.Repo
  end

  actions do
    defaults [:read]

    create :add_reply do
      accept [:ticket_id, :body, :body_format, :source]
      change relate_actor(:user)
      change set_attribute(:message_type, :public_reply)
      change Helpdesk.Support.Changes.RecordTicketEvent
      change {Helpdesk.Audit.Changes.AppendMessageEvent, action: "message.add.reply"}
    end

    create :add_internal_note do
      accept [:ticket_id, :body, :body_format, :source]
      change relate_actor(:user)
      change set_attribute(:message_type, :internal_note)
      change Helpdesk.Support.Changes.RecordTicketEvent
      change {Helpdesk.Audit.Changes.AppendMessageEvent, action: "message.add.internal_note"}
    end
  end

  policies do
    policy always() do
      forbid_unless actor_present()
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if actor_attribute_equals(:role, :admin)

      authorize_if expr(
                     ^actor(:role) == :agent and
                       (ticket.assignee_id == ^actor(:id) or
                          exists(ticket.team.members, user_id == ^actor(:id)))
                   )

      authorize_if expr(message_type == :public_reply and ticket.reporter_id == ^actor(:id))
    end

    policy action([:add_reply, :add_internal_note]) do
      authorize_if relating_to_actor(:user)
    end

    policy action(:add_reply) do
      authorize_if Helpdesk.Support.Checks.CanAccessTicket
    end

    policy action(:add_internal_note) do
      authorize_if {Helpdesk.Support.Checks.CanAccessTicket, staff_only?: true}
    end
  end

  changes do
    change update_change(:body, &String.trim/1)
  end

  validations do
    validate string_length(:body, min: 1, max: 10_000)
  end

  attributes do
    uuid_primary_key :id

    attribute :body, :string do
      allow_nil? false
      public? true
    end

    attribute :body_format, :atom do
      constraints one_of: [:plain_text, :markdown, :html]
      default :plain_text
    end

    attribute :message_type, :atom do
      constraints one_of: [:public_reply, :internal_note]
      allow_nil? false
      public? true
    end

    attribute :source, Helpdesk.Support.Types.TicketSource do
      allow_nil? false
      public? true
    end

    attribute :external_message_id, :string
    attribute :edited_at, :utc_datetime_usec

    timestamps()
  end

  relationships do
    belongs_to :ticket, Helpdesk.Support.Ticket do
      allow_nil? false
    end

    belongs_to :user, Helpdesk.Accounts.User do
      allow_nil? false
    end

    has_many :attachments, Helpdesk.Support.Attachment
  end
end
