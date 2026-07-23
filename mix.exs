defmodule AshArcadic.MixProject do
  use Mix.Project

  @version "0.2.0"
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
      {:arcadic, "~> 0.7.1"},
      # The CDC transport for the optional `AshArcadic.Replicant.*` sink. `optional: true`
      # so non-CDC hosts don't pull it (nor its Postgrex replication deps); a host that
      # uses the sink adds `replicant` to its own deps.
      {:replicant, "~> 0.3", optional: true},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"},
      # SAT solver required by Ash.Policy.Authorizer (Ash lists it as an optional dep;
      # the policy solver raises "No SAT solver available" at DSL-verify/read time without
      # one). Pure Elixir, no NIF — CI-portable, no C toolchain.
      {:simple_sat, "~> 0.1"},

      # Dev/Test
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      # Build-time only: powers `mix spark.cheat_sheets` (DSL doc generation). Optional dep of
      # spark; never a runtime dep of the published library.
      {:igniter, "~> 0.8", only: [:dev, :test], runtime: false}
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
        "documentation/dsls/DSL-AshArcadic.DataLayer.md",
        "documentation/dsls/DSL-AshArcadic.Replicant.md",
        "CHANGELOG.md",
        "CONTRIBUTING.md",
        "LICENSE"
      ],
      groups_for_extras: [
        "DSL Reference": ~r"documentation/dsls/.*"
      ]
    ]
  end

  defp aliases do
    [
      quality: ["format --check-formatted", "credo --strict", "dialyzer"],
      "deps.audit": ["deps.unlock --check-unused", "hex.audit", "mix_audit"],
      # Regenerate the `arcade do … end` / `replicant do … end` DSL cheat sheets before
      # building docs so hexdocs always ships the current DSL reference.
      docs: ["spark.cheat_sheets --extensions AshArcadic.DataLayer,AshArcadic.Replicant", "docs"]
    ]
  end
end
