defmodule Helpdesk.Support.Validations.ActiveCustomer do
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    customer_id = Ash.Changeset.get_argument(changeset, :customer_id)

    case customer_id && Helpdesk.Repo.get(Helpdesk.Accounts.User, customer_id) do
      %Helpdesk.Accounts.User{role: :customer, status: :active} ->
        :ok

      _ ->
        {:error, field: :customer_id, message: "must refer to an active customer"}
    end
  end
end
