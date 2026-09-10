defmodule Helpdesk.Notifications.OutboxEvent do
  @moduledoc """
  Internal durable notification intent, stored with the originating ticket write.

  Only trusted server code may enqueue with authorization explicitly disabled.
  Source event and kind identify an occurrence independently of worker retries.
  Payloads must contain only server-derived routing data, never message bodies.
  """
  use Ash.Resource,
    otp_app: :helpdesk,
    domain: Helpdesk.Notifications,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    table "notification_outbox_events"
    repo Helpdesk.Repo

    custom_indexes do
      index [:status, :next_attempt_at]
    end
  end

  actions do
    defaults [:read]

    create :enqueue do
      public? false

      accept [
        :source_event_id,
        :kind,
        :ticket_id,
        :message_id,
        :actor_id,
        :candidate_recipient_ids,
        :payload,
        :occurred_at
      ]
    end
  end

  policies do
    policy always() do
      forbid_if always()
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :source_event_id, :uuid, allow_nil?: false
    attribute :ticket_id, :uuid, allow_nil?: false
    attribute :message_id, :uuid
    attribute :actor_id, :uuid

    attribute :kind, :atom do
      allow_nil? false

      constraints one_of: [
                    :ticket_created,
                    :assigned,
                    :unassigned,
                    :team_changed,
                    :public_reply,
                    :internal_note,
                    :waiting_on_customer,
                    :resolved,
                    :closed,
                    :reopened
                  ]
    end

    attribute :candidate_recipient_ids, {:array, :uuid}, allow_nil?: false, default: []
    attribute :payload, :map, allow_nil?: false, default: %{}
    attribute :schema_version, :integer, allow_nil?: false, default: 1
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false

    attribute :status, :atom do
      allow_nil? false
      default :pending
      constraints one_of: [:pending, :processing, :processed, :failed]
    end

    attribute :attempts, :integer, allow_nil?: false, default: 0

    attribute :next_attempt_at, :utc_datetime_usec,
      allow_nil?: false,
      default: &DateTime.utc_now/0

    attribute :lease_token, :uuid
    attribute :lease_expires_at, :utc_datetime_usec
    attribute :processed_at, :utc_datetime_usec
    attribute :last_error_code, :string
    timestamps()
  end

  identities do
    identity :unique_source_event_kind, [:source_event_id, :kind]
  end
end
