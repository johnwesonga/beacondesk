defmodule Helpdesk.Notifications.Notification do
  @moduledoc "Persistent in-app notifications owned by an active recipient."
  use Ash.Resource,
    otp_app: :helpdesk,
    domain: Helpdesk.Notifications,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    table "notifications"
    repo Helpdesk.Repo

    custom_indexes do
      index [:recipient_id, :inserted_at, :id]
      index [:recipient_id, :read_at]
    end
  end

  actions do
    read :read do
      primary? true

      pagination do
        keyset? true
        countable true
        default_limit 20
        max_page_size 100
        required? false
      end
    end

    create :deliver do
      public? false
      accept [:outbox_event_id, :recipient_id, :ticket_id, :message_id, :kind]
    end

    update :mark_read do
      require_atomic? false
      accept []
      change set_attribute(:read_at, &DateTime.utc_now/0)
    end
  end

  policies do
    policy action(:deliver) do
      forbid_if always()
    end

    policy action([:read, :mark_read]) do
      forbid_unless actor_present()

      authorize_if expr(
                     recipient_id == ^actor(:id) and recipient.status == :active and
                       (recipient.role in [:admin, :agent] or
                          (recipient.role == :customer and ticket.reporter_id == ^actor(:id))) and
                       not is_nil(ticket.id) and
                       (kind != "internal_note" or recipient.role in [:admin, :agent]) and
                       (is_nil(message_id) or
                          (message.ticket_id == ticket_id and
                             (recipient.role == :admin or
                                (recipient.role == :agent and
                                   (ticket.assignee_id == ^actor(:id) or
                                      exists(ticket.team.members, user_id == ^actor(:id)))) or
                                (message.message_type == :public_reply and
                                   ticket.reporter_id == ^actor(:id)))))
                   )
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :kind, :string, allow_nil?: false, public?: true
    attribute :read_at, :utc_datetime_usec, public?: true
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :outbox_event, Helpdesk.Notifications.OutboxEvent, allow_nil?: false
    belongs_to :recipient, Helpdesk.Accounts.User, allow_nil?: false
    belongs_to :ticket, Helpdesk.Support.Ticket, allow_nil?: false
    belongs_to :message, Helpdesk.Support.Message
  end

  identities do
    identity :unique_event_recipient, [:outbox_event_id, :recipient_id]
  end
end
