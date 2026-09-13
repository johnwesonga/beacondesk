defmodule Helpdesk.Notifications.Preference do
  use Ash.Resource,
    otp_app: :helpdesk,
    domain: Helpdesk.Notifications,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    table "notification_preferences"
    repo Helpdesk.Repo
  end

  actions do
    defaults [:read]

    create :set do
      accept [:kind, :email_enabled]
      change relate_actor(:user)
      upsert? true
      upsert_identity :unique_user_kind
      upsert_fields [:email_enabled]
    end
  end

  policies do
    policy always() do
      forbid_unless actor_attribute_equals(:status, :active)
      forbid_unless Helpdesk.Notifications.ActiveUser
      authorize_if always()
    end

    policy action(:read) do
      authorize_if expr(user_id == ^actor(:id))
    end

    policy action(:set) do
      authorize_if relating_to_actor(:user)
    end
  end

  validations do
    validate attribute_in(
               :kind,
               ~w(ticket_created assigned public_reply waiting_on_customer resolved closed reopened)
             )
  end

  attributes do
    uuid_primary_key :id

    attribute :kind, :string do
      allow_nil? false
    end

    attribute :email_enabled, :boolean, allow_nil?: false, default: true
    timestamps()
  end

  relationships do
    belongs_to :user, Helpdesk.Accounts.User, allow_nil?: false
  end

  identities do
    identity :unique_user_kind, [:user_id, :kind]
  end
end
