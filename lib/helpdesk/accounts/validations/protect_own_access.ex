defmodule Helpdesk.Accounts.Validations.ProtectOwnAccess do
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, %{actor: actor}) do
    if actor && changeset.data.id == actor.id do
      cond do
        Ash.Changeset.get_attribute(changeset, :role) != :admin ->
          {:error, field: :role, message: "you cannot change your own administrator role"}

        Ash.Changeset.get_attribute(changeset, :status) != :active ->
          {:error, field: :status, message: "you cannot disable your own account"}

        true ->
          :ok
      end
    else
      :ok
    end
  end
end
