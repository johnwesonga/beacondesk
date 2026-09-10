defmodule Mix.Tasks.Helpdesk.User.Create do
  use Mix.Task

  @shortdoc "Creates a Helpdesk user"

  @moduledoc """
  Creates a user account outside the public web application.

      HELPDESK_ADMIN_PASSWORD="a secure password" mix helpdesk.user.create user@example.com --first-name "Jane" --last-name "Smith"
      HELPDESK_ADMIN_PASSWORD="a secure password" mix helpdesk.user.create user@example.com --first-name "Jane" --last-name "Smith" --role customer

  Both name options are required. Quote names that contain spaces.
  The password must be at least eight characters. In development, confirmation
  mail is available in the local mailbox at `/dev/mailbox`. The role defaults
  to `admin`; accepted roles are customer, agent, and admin.
  """

  @impl Mix.Task
  def run(args) do
    {options, positional, invalid} =
      OptionParser.parse(args,
        strict: [role: :string, first_name: :string, last_name: :string],
        aliases: [r: :role]
      )

    {email, role, first_name, last_name} = parse_arguments!(options, positional, invalid)

    password =
      System.get_env("HELPDESK_ADMIN_PASSWORD") ||
        Mix.raise("HELPDESK_ADMIN_PASSWORD must be set")

    Mix.Task.run("app.start")

    # Role is intentionally not accepted by public registration. Only this
    # trusted CLI sets it directly on the changeset.
    changeset =
      Helpdesk.Accounts.User
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: email,
        password: password,
        first_name: first_name,
        last_name: last_name,
        password_confirmation: password
      })
      |> Ash.Changeset.force_change_attribute(:role, role)

    case Ash.create(changeset, authorize?: false) do
      {:ok, user} ->
        confirmation =
          if user.confirmed_at, do: "confirmed", else: "confirmation required"

        Mix.shell().info("Created #{user.role} user #{email} (#{confirmation})")

      {:error, error} ->
        message = error |> Ash.Error.to_error_class() |> Exception.message()
        Mix.raise("Could not create user: #{message}")
    end
  end

  defp parse_arguments!(options, [email], []) do
    role = options |> Keyword.get(:role, "admin") |> parse_role!()
    {email, role, required_name!(options, :first_name), required_name!(options, :last_name)}
  end

  defp parse_arguments!(_options, _positional, _invalid) do
    Mix.raise(
      "usage: mix helpdesk.user.create EMAIL --first-name NAME --last-name NAME [--role ROLE]"
    )
  end

  defp required_name!(options, key) do
    value = options |> Keyword.get(key, "") |> String.trim()

    if value == "" do
      flag = key |> Atom.to_string() |> String.replace("_", "-")
      Mix.raise("--#{flag} is required and must not be blank")
    end

    value
  end

  defp parse_role!(role) do
    roles = Helpdesk.Accounts.User.Role.values()
    normalized_role = String.trim_leading(role, ":")

    Enum.find(roles, &(Atom.to_string(&1) == normalized_role)) ||
      Mix.raise("invalid role #{inspect(role)}; expected #{Enum.join(roles, ", ")}")
  end
end
