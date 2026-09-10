defmodule Mix.Tasks.Helpdesk.User.CreateTest do
  use Helpdesk.DataCase

  import ExUnit.CaptureIO

  alias Helpdesk.Accounts.User
  alias Mix.Tasks.Helpdesk.User.Create

  setup do
    previous_password = System.get_env("HELPDESK_ADMIN_PASSWORD")
    previous_shell = Mix.shell()
    System.put_env("HELPDESK_ADMIN_PASSWORD", "test-password-123")
    Mix.shell(Mix.Shell.IO)

    on_exit(fn ->
      Mix.shell(previous_shell)

      if previous_password do
        System.put_env("HELPDESK_ADMIN_PASSWORD", previous_password)
      else
        System.delete_env("HELPDESK_ADMIN_PASSWORD")
      end
    end)

    :ok
  end

  test "creates an admin by default" do
    email = "admin-#{Ash.UUID.generate()}@example.com"

    output =
      capture_io(fn ->
        Create.run([email, "--first-name", " Jane Ann ", "--last-name", " Smith "])
      end)

    user = Enum.find(Ash.read!(User, authorize?: false), &(to_string(&1.email) == email))
    assert user.first_name == "Jane Ann"
    assert user.last_name == "Smith"
    assert user.role == :admin
    assert Bcrypt.verify_pass("test-password-123", user.hashed_password)
    assert output =~ "Created admin user"
    refute output =~ "test-password-123"
  end

  test "creates users with the requested roles" do
    for input <- ["customer", "agent", ":customer"] do
      role = if input == "agent", do: :agent, else: :customer
      email = "#{role}-#{Ash.UUID.generate()}@example.com"

      capture_io(fn ->
        Create.run([email, "--role", input, "--first-name", "Alex", "--last-name", "Morgan"])
      end)

      user = Enum.find(Ash.read!(User, authorize?: false), &(to_string(&1.email) == email))
      assert user.role == role
    end
  end

  test "rejects unsupported roles with a useful error" do
    assert_raise Mix.Error, ~r/expected admin, agent, customer/, fn ->
      Create.run(["user@example.com", "--role", "owner"])
    end
  end

  test "rejects missing or blank names" do
    for {args, flag} <- [
          {[], "first-name"},
          {["--first-name", "Alex"], "last-name"},
          {["--first-name", "   ", "--last-name", "Morgan"], "first-name"},
          {["--first-name", "Alex", "--last-name", "  "], "last-name"}
        ] do
      assert_raise Mix.Error, "--#{flag} is required and must not be blank", fn ->
        Create.run(["user@example.com" | args])
      end
    end
  end

  test "requires a password" do
    System.delete_env("HELPDESK_ADMIN_PASSWORD")

    assert_raise Mix.Error, "HELPDESK_ADMIN_PASSWORD must be set", fn ->
      Create.run(["user@example.com", "--first-name", "Alex", "--last-name", "Morgan"])
    end
  end
end
