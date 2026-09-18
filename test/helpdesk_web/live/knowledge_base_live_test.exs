defmodule HelpdeskWeb.KnowledgeBaseLiveTest do
  use HelpdeskWeb.ConnCase
  import Phoenix.LiveViewTest
  import AshAuthentication.Plug.Helpers, only: [store_in_session: 2]
  alias Helpdesk.Support.KnowledgeBaseArticle

  test "guests can browse published articles without signing in", %{conn: conn} do
    article = article!(%{})
    draft = article!(%{published: false})
    {:ok, view, _} = live(conn, ~p"/help")
    assert has_element?(view, "#public-help-sign-in[href='/sign-in']")
    assert has_element?(view, "#kb-article-#{article.id}")
    refute has_element?(view, "#kb-article-#{draft.id}")
    {:ok, view, _} = live(conn, ~p"/help/#{article.slug}")
    assert has_element?(view, "#kb-article-body", article.body)
    assert {:error, {:live_redirect, %{to: "/help"}}} = live(conn, ~p"/help/#{draft.slug}")
  end

  test "all roles can browse published articles, but not drafts", %{conn: conn} do
    published = article!(%{title: "Visible article"})
    draft = article!(%{published: false, category: "Draft category"})

    for role <- [:customer, :agent, :admin] do
      {:ok, view, _} = live(login(conn, role), ~p"/help")
      assert has_element?(view, "#kb-article-#{published.id}")
      refute has_element?(view, "#kb-article-#{draft.id}")
      refute has_element?(view, "#kb-category option", "Draft category")
      view |> element("#kb-article-#{published.id}") |> render_click()
      assert_redirect(view, ~p"/help/#{published.slug}")
    end
  end

  test "search, categories, empty results and URL state", %{conn: conn} do
    billing =
      article!(%{
        title: "Invoice adjustment",
        category: "Test billing",
        body: "Unique reimbursement instructions."
      })

    account = article!(%{title: "Account adjustment", category: "Test accounts"})
    {:ok, view, _} = live(login(conn, :customer), ~p"/help")

    view
    |> form("#kb-search-form", search: %{q: "ADJUSTMENT", category: "Test billing"})
    |> render_change()

    assert has_element?(view, "#kb-article-#{billing.id}")
    refute has_element?(view, "#kb-article-#{account.id}")

    view
    |> form("#kb-search-form", search: %{q: "no-matching-article", category: ""})
    |> render_submit()

    assert has_element?(view, "#kb-empty:only-child")
    {:ok, view, _} = live(login(conn, :customer), ~p"/help?#{%{q: "REIMBURSEMENT"}}")
    assert has_element?(view, "#kb-article-#{billing.id}")
  end

  test "article details escape content and unavailable articles redirect", %{conn: conn} do
    article = article!(%{body: "Steps to follow\n\n<script>alert('unsafe')</script>"})
    draft = article!(%{published: false})

    for role <- [:customer, :admin] do
      authenticated = login(conn, role)
      {:ok, view, _} = live(authenticated, ~p"/help/#{article.slug}")
      assert has_element?(view, "#kb-article h1", article.title)
      assert has_element?(view, "#kb-article-body", "<script>")
      refute has_element?(view, "#kb-article-body script")
      assert has_element?(view, "#kb-back[href='/help']")

      for slug <- [draft.slug, "nonexistent-article"] do
        assert {:error, {:live_redirect, %{to: "/help"}}} = live(authenticated, ~p"/help/#{slug}")
      end
    end
  end

  test "pagination retains filters", %{conn: conn} do
    for n <- 1..21,
        do: article!(%{category: "Pagination", title: "Page article #{n}", position: n})

    {:ok, view, _} = live(login(conn, :customer), ~p"/help?#{%{category: "Pagination"}}")
    assert has_element?(view, "#kb-next")
    view |> element("#kb-next") |> render_click()
    assert has_element?(view, "#kb-articles article", "Page article 21")
    refute has_element?(view, "#kb-next")
    assert has_element?(view, "#kb-category option[value='Pagination'][selected]")
    view |> element("#kb-previous") |> render_click()
    assert has_element?(view, "#kb-next")
  end

  defp article!(attrs) do
    Ash.Seed.seed!(
      KnowledgeBaseArticle,
      Map.merge(
        %{
          title: "Test article",
          slug: "test-#{Ash.UUID.generate()}",
          summary: "A useful summary.",
          body: "Detailed instructions.",
          category: "Testing",
          published: true
        },
        attrs
      )
    )
  end

  defp login(conn, role) do
    user =
      Ash.Seed.seed!(Helpdesk.Accounts.User, %{
        first_name: "Reader",
        last_name: "User",
        email: "kb-#{Ash.UUID.generate()}@example.com",
        role: role,
        hashed_password: "unused"
      })

    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> init_test_session(%{})
    |> store_in_session(Ash.Resource.put_metadata(user, :token, token))
  end
end
