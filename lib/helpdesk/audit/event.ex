defmodule Helpdesk.Audit.Event do
  use Ash.Resource,
    otp_app: :helpdesk,
    domain: Helpdesk.Audit,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "audit_events"
    repo Helpdesk.Repo
  end

  actions do
    read :read do
      primary? true

      pagination do
        keyset? true
        required? false
        default_limit 25
        countable true
      end
    end

    create :append do
      public? false

      accept [
        :operation_id,
        :action,
        :actor_id,
        :actor_label,
        :target_label,
        :ticket_id,
        :metadata,
        :source,
        :occurred_at
      ]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :operation_id, :uuid, allow_nil?: false, public?: true
    attribute :action, :string, allow_nil?: false, public?: true
    attribute :actor_id, :uuid, allow_nil?: false, public?: true
    attribute :actor_label, :string, allow_nil?: false, public?: true
    attribute :target_label, :string, allow_nil?: false, public?: true
    attribute :ticket_id, :uuid, public?: true
    attribute :metadata, :map, allow_nil?: false, public?: true, default: %{}
    attribute :source, :string, allow_nil?: false, public?: true, default: "admin_ui"
    attribute :request_id, :string, public?: true
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true
    create_timestamp :inserted_at
  end

  identities do
    identity :unique_operation, [:operation_id]
  end
end
