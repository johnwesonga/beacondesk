defmodule Helpdesk.Support.Team do
  use Ash.Resource,
    otp_app: :helpdesk,
    domain: Helpdesk.Support,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    table "teams"
    repo Helpdesk.Repo
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:name, :email, :active]
    end

    update :update do
      primary? true
      accept [:name, :email, :active]
    end
  end

  policies do
    policy action_type(:read) do
      forbid_unless actor_present()
      # authorize_if actor_attribute_equals(:role, :admin)
      # authorize_if expr(^actor(:role) == :agent and exists(members, user_id == ^actor(:id)))
      authorize_if {Helpdesk.Accounts.Checks.HasPermission,
                    permission: [:manage_teams, :assign_tickets]}
    end

    policy action_type([:create, :update]) do
      # authorize_if actor_attribute_equals(:role, :admin)
      authorize_if {Helpdesk.Accounts.Checks.HasPermission, permission: [:manage_teams]}
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :email, :ci_string, public?: true
    attribute :active, :boolean, default: true, allow_nil?: false
    timestamps()
  end

  relationships do
    has_many :tickets, Helpdesk.Support.Ticket
    has_many :members, Helpdesk.Support.TeamMembership
  end

  identities do
    identity :unique_name, [:name]
  end
end
