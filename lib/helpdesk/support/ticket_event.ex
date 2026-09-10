defmodule Helpdesk.Support.TicketEvent do
  @moduledoc """
  Append-only audit entries created by trusted support workflow changes.

  No update or destroy actions are exposed. Direct database access must also
  respect this invariant.

  Examples:
  ==========
  ticket_created
  assigned
  team_changed
  status_changed
  priority_changed
  message_added
  attachment_added
  details_changed

  Resolving, reopening and closing are recorded as status_changed events with
  the previous and new status values.
  """
  use Ash.Resource,
    otp_app: :helpdesk,
    domain: Helpdesk.Support,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    table "ticket_events"
    repo Helpdesk.Repo
  end

  actions do
    defaults [:read]

    create :create_ticket_event do
      accept [:ticket_id, :event_type, :field_name, :old_value, :new_value, :metadata]
      change relate_actor(:user)
    end
  end

  policies do
    policy action_type(:read) do
      forbid_unless actor_present()
      authorize_if actor_attribute_equals(:role, :admin)

      authorize_if expr(
                     ^actor(:role) == :agent and
                       (ticket.assignee_id == ^actor(:id) or
                          exists(ticket.team.members, user_id == ^actor(:id)))
                   )
    end

    policy action(:create_ticket_event) do
      forbid_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :event_type, :atom do
      allow_nil? false

      constraints one_of: [
                    :ticket_created,
                    :assigned,
                    :team_changed,
                    :status_changed,
                    :priority_changed,
                    :details_changed,
                    :message_added,
                    :attachment_added
                  ]
    end

    attribute :field_name, :string
    attribute :old_value, :string
    attribute :new_value, :string
    attribute :metadata, :map

    timestamps()
  end

  relationships do
    belongs_to :ticket, Helpdesk.Support.Ticket do
      allow_nil? false
      public? true
    end

    belongs_to :user, Helpdesk.Accounts.User do
      public? true
    end
  end
end
