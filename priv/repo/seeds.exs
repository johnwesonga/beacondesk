alias Helpdesk.Support.KnowledgeBaseArticle
require Ash.Query

articles = [
  %{
    title: "Reset your password",
    slug: "reset-your-password",
    summary: "Request a secure password-reset link and regain access to your account.",
    category: "Accounts & security",
    featured: true,
    position: 10,
    body: """
    If you cannot sign in, open the sign-in page and select **Forgot password?**.

    1. Enter the email address associated with your account.
    2. Open the password-reset email from Consilium.
    3. Follow the link and choose a new password.

    For your security, reset links expire and can only be used once. Request a new link if the original one has expired.
    """
  },
  %{
    title: "Keep your account secure",
    slug: "keep-your-account-secure",
    summary: "Practical steps for protecting your Consilium account.",
    category: "Accounts & security",
    featured: false,
    position: 20,
    body: """
    Use a unique password that you do not use for another service. Never share password-reset links or sign-in credentials with another person.

    If you notice unexpected account activity, reset your password and contact support with the approximate time and details of the activity.
    """
  },
  %{
    title: "Understand invoice charges",
    slug: "understand-invoice-charges",
    summary: "Learn where charges, credits, and billing dates appear on an invoice.",
    category: "Billing & plans",
    featured: true,
    position: 30,
    body: """
    Each invoice shows the billing period, subscription charges, applicable credits, taxes, and the final amount due.

    If a charge looks incorrect, create a support ticket and include the invoice number, the line item in question, and the amount you expected. Do not include complete card details.
    """
  },
  %{
    title: "Update your billing details",
    slug: "update-your-billing-details",
    summary: "Change the billing contact and information shown on future invoices.",
    category: "Billing & plans",
    featured: false,
    position: 40,
    body: """
    A workspace administrator can update the billing contact, company name, and billing address from the workspace billing settings.

    Changes apply to future invoices. Contact support if you need help correcting information on an invoice that has already been issued.
    """
  },
  %{
    title: "Connect an app to your workspace",
    slug: "connect-an-app-to-your-workspace",
    summary: "Authorize an integration and confirm that it can access the correct workspace.",
    category: "Apps & integrations",
    featured: true,
    position: 50,
    body: """
    Open your workspace integration settings, choose the app you want to connect, and follow its authorization flow.

    Confirm that you selected the correct workspace and granted the permissions required by the integration. You may need an administrator to approve the connection.
    """
  },
  %{
    title: "Troubleshoot webhook delivery",
    slug: "troubleshoot-webhook-delivery",
    summary: "Check endpoint availability, response codes, and webhook configuration.",
    category: "Apps & integrations",
    featured: false,
    position: 60,
    body: """
    Verify that the webhook URL is public, uses HTTPS, and responds within the configured timeout. A successful endpoint should return a 2xx response.

    Review recent delivery attempts for response codes and errors. When contacting support, include the delivery time and request identifier, but omit signing secrets.
    """
  }
]

Enum.each(articles, fn attributes ->
  existing_article =
    KnowledgeBaseArticle
    |> Ash.Query.filter(slug == ^attributes.slug)
    |> Ash.read_one!(authorize?: false)

  article =
    case existing_article do
      nil ->
        KnowledgeBaseArticle
        |> Ash.Changeset.for_create(:create, attributes)
        |> Ash.create!(authorize?: false)

      article ->
        article
        |> Ash.Changeset.for_update(:update, attributes)
        |> Ash.update!(authorize?: false)
    end

  unless article.published do
    article
    |> Ash.Changeset.for_update(:publish)
    |> Ash.update!(authorize?: false)
  end
end)

IO.puts("Seeded #{length(articles)} knowledge-base articles.")
