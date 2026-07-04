defmodule AshArcadic.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/baselabs/ash_arcadic"

  def project do
    [
      app: :ash_arcadic,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      consolidate_protocols: Mix.env() != :test,
      deps: deps(),
      package: package(),
      docs: docs(),
      aliases: aliases(),
      name: "AshArcadic",
      description:
        "Ash Framework DataLayer for ArcadeDB — native OpenCypher over the HTTP command API.",
      source_url: @source_url,
      homepage_url: @source_url,
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_core_path: "priv/plts",
        plt_local_path: "priv/plts"
      ]
    ]
  end

  def cli do
    [preferred_envs: [credo: :test, dialyzer: :test]]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Runtime
      {:ash, "~> 3.11"},
      {:spark, ">= 2.3.3 and < 3.0.0-0"},
      {:splode, "~> 0.3"},
      {:arcadic, path: "../arcadic"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"},

      # Dev/Test
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["rjpalermo"],
      files:
        ~w(lib .formatter.exs mix.exs README* LICENSE* CHANGELOG* usage-rules.md documentation),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "README.md",
        "usage-rules.md",
        "CHANGELOG.md",
        "CONTRIBUTING.md",
        "LICENSE"
      ]
    ]
  end

  defp aliases do
    [
      quality: ["format --check-formatted", "credo --strict", "dialyzer"],
      "deps.audit": ["deps.unlock --check-unused", "hex.audit", "mix_audit"]
      # Once AshArcadic.DataLayer defines its `arcade do ... end` section, add a
      # `docs` alias that generates the DSL cheat sheet first:
      #   docs: ["spark.cheat_sheets --extensions AshArcadic.DataLayer", "docs"]
    ]
  end
end
