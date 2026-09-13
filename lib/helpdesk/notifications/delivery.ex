defmodule Helpdesk.Notifications.Delivery do
  @moduledoc "Internal durable email delivery state. Mutated only by trusted workers."
  use Ash.Resource,
    otp_app: :helpdesk,
    domain: Helpdesk.Notifications,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    table "notification_deliveries"
    repo Helpdesk.Repo

    custom_indexes do
      index [:status, :next_attempt_at]
      index [:status, :lease_expires_at]
    end
  end

  actions do
    defaults [:read]

    create :enqueue do
      accept [:notification_id]
    end
  end

  policies do
    policy always() do
      forbid_if always()
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :channel, :atom, allow_nil?: false, default: :email, constraints: [one_of: [:email]]

    attribute :status, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :sending, :sent, :skipped, :failed]]

    attribute :attempts, :integer, allow_nil?: false, default: 0

    attribute :next_attempt_at, :utc_datetime_usec,
      allow_nil?: false,
      default: &DateTime.utc_now/0

    attribute :lease_token, :uuid
    attribute :lease_expires_at, :utc_datetime_usec
    attribute :sent_at, :utc_datetime_usec
    attribute :last_error_code, :string
    attribute :provider_message_id, :string
    timestamps()
  end

  relationships do
    belongs_to :notification, Helpdesk.Notifications.Notification, allow_nil?: false
  end

  identities do
    identity :unique_notification_channel, [:notification_id, :channel]
  end
end
