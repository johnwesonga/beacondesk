defmodule Helpdesk.Support.KnowledgeBaseArticle do
  use Ash.Resource,
    otp_app: :helpdesk,
    domain: Helpdesk.Support,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    table "knowledge_base_articles"
    repo Helpdesk.Repo
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:title, :slug, :summary, :body, :category, :featured, :position]
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:title, :slug, :summary, :body, :category, :featured, :position]
    end

    update :publish do
      require_atomic? false
      accept []
      change set_attribute(:published, true)
      change set_attribute(:published_at, &DateTime.utc_now/0)
    end

    update :unpublish do
      require_atomic? false
      accept []
      change set_attribute(:published, false)
      change set_attribute(:published_at, nil)
    end

    destroy :destroy do
      primary? true
      require_atomic? false
    end
  end

  policies do
    bypass actor_attribute_equals(:role, :admin) do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if expr(published == true)
    end

    policy action_type([:create, :update, :destroy]) do
      forbid_if always()
    end
  end

  validations do
    validate string_length(:title, min: 1, max: 200)
    validate match(:title, ~r/\S/u), message: "must not be blank"

    validate string_length(:slug, min: 1, max: 200)

    validate match(:slug, ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/),
      message: "must contain lowercase letters, numbers, and single hyphens only"

    validate string_length(:summary, min: 1, max: 500)
    validate match(:summary, ~r/\S/u), message: "must not be blank"
    validate string_length(:body, min: 1, max: 100_000)
    validate match(:body, ~r/\S/u), message: "must not be blank"
    validate string_length(:category, min: 1, max: 80)
    validate match(:category, ~r/\S/u), message: "must not be blank"
    validate numericality(:position, greater_than_or_equal_to: 0)
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string do
      allow_nil? false
      public? true
    end

    attribute :slug, :string do
      allow_nil? false
      public? true
    end

    attribute :summary, :string do
      allow_nil? false
      public? true
    end

    attribute :body, :string do
      allow_nil? false
      public? true
    end

    attribute :category, :string do
      allow_nil? false
      public? true
    end

    attribute :featured, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :position, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :published, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :published_at, :utc_datetime_usec do
      public? true
    end

    timestamps()
  end

  identities do
    identity :unique_slug, [:slug]
  end
end
