defmodule Helpdesk.Support.TeamMembership do
  use Ash.Resource,
    otp_app: :helpdesk,
    domain: Helpdesk.Support,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    table "team_memberships"
    repo Helpdesk.Repo
  end

  actions do
    defaults [:read, create: :*, update: :*]

    create :add_member do
      accept [:user_id, :team_id]
      require_attributes [:user_id, :team_id]
      validate Helpdesk.Support.Validations.TeamMember
    end

    destroy :remove_member do
      require_atomic? false
      validate {Helpdesk.Support.Validations.TeamMember, removing?: true}
    end
  end

  policies do
    policy action_type(:read) do
      forbid_unless actor_present()
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if expr(^actor(:role) == :agent and user_id == ^actor(:id))
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if {Helpdesk.Accounts.Checks.HasPermission, permission: :manage_team_membership}
    end
  end

  attributes do
    uuid_primary_key :id
  end

  relationships do
    belongs_to :user, Helpdesk.Accounts.User do
      public? true
    end

    belongs_to :team, Helpdesk.Support.Team do
      public? true
    end
  end
end
