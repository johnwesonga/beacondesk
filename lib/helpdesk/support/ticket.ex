defmodule Helpdesk.Support.Ticket do
  use Ash.Resource,
    otp_app: :helpdesk,
    domain: Helpdesk.Support,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    table "tickets"
    repo Helpdesk.Repo
  end

  actions do
    defaults [:read]

    create :create_ticket do
      accept [
        :title,
        :description,
        :status,
        :priority,
        :source,
        :category,
        :team_id,
        :assignee_id
      ]

      change relate_actor(:reporter)
      validate Helpdesk.Support.Validations.TicketCanBeAssigned, only_when_valid?: true
      change Helpdesk.Support.Changes.CreateTicketNumber
      change Helpdesk.Support.Changes.RecordTicketEvent
      change {Helpdesk.Audit.Changes.AppendTicketEvent, action: "ticket.created"}

      change set_attribute(:status, :new)
      change set_attribute(:source, :web)
    end

    update :update_ticket do
      require_atomic? false

      accept [
        :title,
        :description,
        :status,
        :priority,
        :source,
        :category,
        :team_id,
        :assignee_id
      ]

      validate Helpdesk.Support.Validations.TicketCanBeAssigned, only_when_valid?: true
      change Helpdesk.Support.Changes.RecordTicketEvent
      change {Helpdesk.Audit.Changes.AppendTicketEvent, action: "ticket.updated"}
    end

    update :assign do
      require_atomic? false
      accept [:assignee_id, :team_id]

      validate Helpdesk.Support.Validations.TicketCanBeAssigned, only_when_valid?: true
      change Helpdesk.Support.Changes.RecordTicketEvent
      change {Helpdesk.Audit.Changes.AppendTicketEvent, action: "ticket.assign"}
    end

    update :change_status do
      require_atomic? false
      accept [:status]

      change Helpdesk.Support.Changes.SetStatusTimestamps
      change Helpdesk.Support.Changes.RecordTicketEvent
      change {Helpdesk.Audit.Changes.AppendTicketEvent, action: "ticket.change_status"}
    end

    update :change_priority do
      require_atomic? false
      accept [:priority]

      change Helpdesk.Support.Changes.RecordTicketEvent
      change {Helpdesk.Audit.Changes.AppendTicketEvent, action: "ticket.change_priority"}
    end

    update :edit_details do
      require_atomic? false
      accept [:title, :category, :due_at]
      change Helpdesk.Support.Changes.RecordTicketEvent
      change {Helpdesk.Audit.Changes.AppendTicketEvent, action: "ticket.updated"}
    end
  end

  policies do
    policy action([:create_ticket, :update_ticket, :assign]) do
      authorize_if Helpdesk.Support.Checks.CanSetAssignment
    end

    policy always() do
      forbid_unless actor_present()
      authorize_if always()
    end

    policy action(:create_ticket) do
      authorize_if relating_to_actor(:reporter)
    end

    policy action(:create_ticket) do
      authorize_if {Helpdesk.Accounts.Checks.HasPermission, permission: :create_tickets}
    end

    policy action_type(:read) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :agent)
      authorize_if expr(^actor(:role) == :customer and reporter_id == ^actor(:id))
    end

    policy action_type(:update) do
      authorize_if actor_attribute_equals(:role, :admin)

      authorize_if expr(
                     ^actor(:role) == :agent and
                       (assignee_id == ^actor(:id) or
                          exists(team.members, user_id == ^actor(:id)))
                   )
    end
  end

  changes do
    change update_change(:title, &String.trim/1)
    change update_change(:description, &String.trim/1)
  end

  validations do
    validate string_length(:title, min: 3, max: 160)
    validate string_length(:description, min: 10, max: 10_000)
  end

  attributes do
    uuid_primary_key :id

    attribute :ticket_number, :string do
      allow_nil? false
      public? true
    end

    attribute :title, :string do
      allow_nil? false
      public? true
    end

    # Action input, not persisted on the ticket.
    attribute :description, :string do
      public? true
      allow_nil? false
    end

    attribute :status, Helpdesk.Support.Types.TicketStatus do
      public? true
      allow_nil? false
    end

    attribute :priority, Helpdesk.Support.TicketPriority do
      public? true
      allow_nil? false
    end

    attribute :source, Helpdesk.Support.TicketSource do
      public? true
      allow_nil? false
    end

    attribute :category, Helpdesk.Support.Types.TicketCategory, public?: true
    attribute :due_at, :utc_datetime_usec
    attribute :resolved_at, :utc_datetime_usec
    attribute :closed_at, :utc_datetime_usec

    timestamps()
  end

  relationships do
    belongs_to :assignee, Helpdesk.Accounts.User do
      public? true
    end

    belongs_to :reporter, Helpdesk.Accounts.User do
      public? true
    end

    has_many :messages, Helpdesk.Support.Message do
      destination_attribute :ticket_id
    end

    has_many :ticket_events, Helpdesk.Support.TicketEvent do
      destination_attribute :ticket_id
    end

    belongs_to :team, Helpdesk.Support.Team do
      public? true
    end
  end

  identities do
    identity :unique_ticket_number, [:ticket_number]
  end
end
