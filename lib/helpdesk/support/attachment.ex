defmodule Helpdesk.Support.Attachment do
  use Ash.Resource,
    otp_app: :helpdesk,
    domain: Helpdesk.Support,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    table "attachments"
    repo Helpdesk.Repo
  end

  actions do
    defaults [:read]

    create :attach_to_ticket do
      accept [:ticket_id, :file_name, :file_path, :storage_key, :content_type, :byte_size]
      require_attributes [:ticket_id]
      change {Helpdesk.Audit.Changes.AppendAttachmentEvent, action: :attach_to_ticket}
    end
  end

  policies do
    policy action(:attach_to_ticket) do
      authorize_if Helpdesk.Support.Checks.CanAccessTicket
    end

    policy action_type(:read) do
      forbid_unless actor_present()
      authorize_if actor_attribute_equals(:role, :admin)

      authorize_if expr(
                     is_nil(message_id) and
                       (ticket.reporter_id == ^actor(:id) or
                          (^actor(:role) == :agent and
                             (ticket.assignee_id == ^actor(:id) or
                                exists(ticket.team.members, user_id == ^actor(:id)))))
                   )

      # A message attachment inherits the message's visibility. If both
      # parents are set, they must identify the same ticket.
      authorize_if expr(
                     not is_nil(message_id) and
                       (is_nil(ticket_id) or ticket_id == message.ticket_id) and
                       ((message.message_type == :public_reply and
                           message.ticket.reporter_id == ^actor(:id)) or
                          (^actor(:role) == :agent and
                             (message.ticket.assignee_id == ^actor(:id) or
                                exists(message.ticket.team.members, user_id == ^actor(:id)))))
                   )
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :file_name, :string do
      allow_nil? false
      public? true
    end

    attribute :file_path, :string do
      allow_nil? false
      public? true
    end

    attribute :content_type, :string, allow_nil?: false
    attribute :byte_size, :integer, allow_nil?: false
    attribute :storage_key, :string, allow_nil?: false
    attribute :checksum, :string

    create_timestamp :created_at
  end

  relationships do
    belongs_to :ticket, Helpdesk.Support.Ticket do
      public? true
    end

    belongs_to :message, Helpdesk.Support.Message do
      public? true
    end
  end

  identities do
    identity :unique_storage_key, [:storage_key]
  end
end
