defmodule AshArcadic.Test.TestURL do
  @moduledoc false
  # ARCADIC_TEST_URL, userinfo-stripped. Credentials ride ARCADIC_TEST_PASSWORD +
  # the explicit auth tuple — a URL like http://root:pass@host would otherwise
  # defeat credential-override fixtures (the HTTP layer lets URL userinfo win
  # over the Authorization header; arcadic 1.1.0 rejects the combination at
  # connect, and this helper keeps the suite working under EITHER env shape).
  def base do
    url = System.fetch_env!("ARCADIC_TEST_URL")

    case URI.new(url) do
      {:ok, %URI{userinfo: userinfo} = uri} when is_binary(userinfo) and userinfo != "" ->
        %{uri | userinfo: nil} |> URI.to_string()

      _ ->
        url
    end
  end
end
