defmodule Helpdesk.Accounts.User do
  use Ash.Resource,
    otp_app: :helpdesk,
    domain: Helpdesk.Accounts,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication],
    data_layer: AshSqlite.DataLayer

  authentication do
    add_ons do
      log_out_everywhere do
        apply_on_password_change? true
      end

      confirmation :confirm_new_user do
        monitor_fields [:email]
        confirm_on_create? true
        confirm_on_update? false
        require_interaction? true
        confirmed_at_field :confirmed_at
        auto_confirm_actions [:sign_in_with_magic_link, :reset_password_with_token]
        sender Helpdesk.Accounts.User.Senders.SendNewUserConfirmationEmail
      end
    end

    tokens do
      enabled? true
      token_resource Helpdesk.Accounts.Token
      signing_secret Helpdesk.Secrets
      store_all_tokens? true
      require_token_presence_for_authentication? true
    end

    strategies do
      password :password do
        identity_field :email
        hash_provider AshAuthentication.BcryptProvider

        resettable do
          sender Helpdesk.Accounts.User.Senders.SendPasswordResetEmail
          # these configurations will be the default in a future release
          password_reset_action_name :reset_password_with_token
          request_password_reset_action_name :request_password_reset_token
        end
      end

      remember_me :remember_me
    end
  end

  sqlite do
    table "users"
    repo Helpdesk.Repo
  end

  actions do
    read :list_customers do
      filter expr(status == :active and role == :customer)
    end

    read :list_assignees do
      filter expr(status == :active and role in [:admin, :agent])
    end

    create :create_user do
      accept [:first_name, :last_name, :email, :status]
      argument :role, Helpdesk.Accounts.User.Role, allow_nil?: false, default: :customer

      argument :password, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [min_length: 8]

      argument :password_confirmation, :string, allow_nil?: false, sensitive?: true
      change set_context(%{strategy_name: :password})
      change set_attribute(:role, arg(:role))
      change AshAuthentication.Strategy.Password.HashPasswordChange
      validate AshAuthentication.Strategy.Password.PasswordConfirmationValidation
      change update_change(:first_name, &String.trim/1)
      change update_change(:last_name, &String.trim/1)
      validate string_length(:first_name, min: 1)
      validate string_length(:last_name, min: 1)
    end

    update :manage_user do
      require_atomic? false
      accept [:first_name, :last_name, :status]
      argument :role, Helpdesk.Accounts.User.Role, allow_nil?: false
      change set_attribute(:role, arg(:role))
      change update_change(:first_name, &String.trim/1)
      change update_change(:last_name, &String.trim/1)
      validate string_length(:first_name, min: 1)
      validate string_length(:last_name, min: 1)
      validate Helpdesk.Accounts.Validations.ProtectOwnAccess
    end

    defaults [:read]

    read :get_by_subject do
      description "Get a user by the subject claim in a JWT"
      argument :subject, :string, allow_nil?: false
      get? true
      prepare AshAuthentication.Preparations.FilterBySubject
    end

    update :change_password do
      # Use this action to allow users to change their password by providing
      # their current password and a new password.

      require_atomic? false
      accept []
      argument :current_password, :string, sensitive?: true, allow_nil?: false

      argument :password, :string,
        sensitive?: true,
        allow_nil?: false,
        constraints: [min_length: 8]

      argument :password_confirmation, :string, sensitive?: true, allow_nil?: false

      validate confirm(:password, :password_confirmation)

      validate {AshAuthentication.Strategy.Password.PasswordValidation,
                strategy_name: :password, password_argument: :current_password}

      change {AshAuthentication.Strategy.Password.HashPasswordChange, strategy_name: :password}
    end

    read :sign_in_with_password do
      description "Attempt to sign in using a email and password."
      get? true

      argument :email, :ci_string do
        description "The email to use for retrieving the user."
        allow_nil? false
      end

      argument :password, :string do
        description "The password to check for the matching user."
        allow_nil? false
        sensitive? true
      end

      # validates the provided email and password and generates a token
      prepare AshAuthentication.Strategy.Password.SignInPreparation

      metadata :token, :string do
        description "A JWT that can be used to authenticate the user."
        allow_nil? false
      end
    end

    read :sign_in_with_token do
      # In the generated sign in components, we validate the
      # email and password directly in the LiveView
      # and generate a short-lived token that can be used to sign in over
      # a standard controller action, exchanging it for a standard token.
      # This action performs that exchange. If you do not use the generated
      # liveviews, you may remove this action, and set
      # `sign_in_tokens_enabled? false` in the password strategy.

      description "Attempt to sign in using a short-lived sign in token."
      get? true

      argument :token, :string do
        description "The short-lived sign in token."
        allow_nil? false
        sensitive? true
      end

      # validates the provided sign in token and generates a token
      prepare AshAuthentication.Strategy.Password.SignInWithTokenPreparation

      metadata :token, :string do
        description "A JWT that can be used to authenticate the user."
        allow_nil? false
      end
    end

    create :register_with_password do
      description "Register a new user with a email and password."

      argument :email, :ci_string do
        allow_nil? false
      end

      argument :password, :string do
        description "The proposed password for the user, in plain text."
        allow_nil? false
        constraints min_length: 8
        sensitive? true
      end

      argument :first_name, :string do
        allow_nil? false
      end

      argument :last_name, :string do
        allow_nil? false
      end

      argument :password_confirmation, :string do
        description "The proposed password for the user (again), in plain text."
        allow_nil? false
        sensitive? true
      end

      # Sets the email from the argument
      change set_attribute(:email, arg(:email))
      change set_attribute(:first_name, arg(:first_name))
      change set_attribute(:last_name, arg(:last_name))

      # Hashes the provided password
      change AshAuthentication.Strategy.Password.HashPasswordChange

      # Generates an authentication token for the user
      change AshAuthentication.GenerateTokenChange

      # validates that the password matches the confirmation
      validate AshAuthentication.Strategy.Password.PasswordConfirmationValidation

      metadata :token, :string do
        description "A JWT that can be used to authenticate the user."
        allow_nil? false
      end
    end

    action :request_password_reset_token do
      description "Send password reset instructions to a user if they exist."

      argument :email, :ci_string do
        allow_nil? false
      end

      # creates a reset token and invokes the relevant senders
      run {AshAuthentication.Strategy.Password.RequestPasswordReset, action: :get_by_email}
    end

    read :get_by_email do
      description "Looks up a user by their email"
      get_by :email
    end

    update :reset_password_with_token do
      argument :reset_token, :string do
        allow_nil? false
        sensitive? true
      end

      argument :password, :string do
        description "The proposed password for the user, in plain text."
        allow_nil? false
        constraints min_length: 8
        sensitive? true
      end

      argument :password_confirmation, :string do
        description "The proposed password for the user (again), in plain text."
        allow_nil? false
        sensitive? true
      end

      # validates the provided reset token
      validate AshAuthentication.Strategy.Password.ResetTokenValidation

      # validates that the password matches the confirmation
      validate AshAuthentication.Strategy.Password.PasswordConfirmationValidation

      # Hashes the provided password
      change AshAuthentication.Strategy.Password.HashPasswordChange

      # Generates an authentication token for the user
      change AshAuthentication.GenerateTokenChange
    end
  end

  policies do
    policy action(:list_customers) do
      authorize_if {Helpdesk.Accounts.Checks.HasPermission,
                    permission: :open_tickets_for_customers}
    end

    policy action(:list_assignees) do
      authorize_if {Helpdesk.Accounts.Checks.HasPermission, permission: :assign_tickets}
    end

    policy action([:read, :create_user, :manage_user]) do
      authorize_if {Helpdesk.Accounts.Checks.HasPermission, permission: :manage_users}
    end

    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :first_name, :string do
      allow_nil? false
      sensitive? true
    end

    attribute :last_name, :string do
      allow_nil? false
      sensitive? true
    end

    attribute :role, Helpdesk.Accounts.User.Role do
      default :customer
      allow_nil? false
      writable? false
    end

    attribute :email, :ci_string do
      allow_nil? false
      public? true
    end

    attribute :hashed_password, :string do
      allow_nil? false
      sensitive? true
    end

    attribute :status, Helpdesk.Accounts.User.Status do
      allow_nil? false
      public? true
      default :active
    end

    attribute :confirmed_at, :utc_datetime_usec
  end

  relationships do
    has_many :team_memberships, Helpdesk.Support.TeamMembership do
      destination_attribute :user_id
    end
  end

  identities do
    identity :unique_email, [:email]
  end
end
