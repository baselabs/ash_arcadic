defmodule AshArcadic.Cast do
  @moduledoc """
  Value serialization and flat-JSON-row decode for the ArcadeDB wire.

  ArcadeDB rows are flat JSON maps (`%{"@rid" => .., "@cat" => "v", <props>}`), not
  AGE agtype text — so there is NO tag: values are typed-decoded from the resource's
  attribute map. `serialize_value/2` and `load_value/2` dispatch by the attribute's
  STORAGE class (`Ash.Type.storage_type/2`) so a `NewType` wrapper round-trips like
  the builtin it stores as. Binary-storage values (app-side-encrypted bytes, D3) are
  `Base.encode64`/`decode64` — plaintext in JSON is impossible, and equality matches
  because both the stored form and a filter param serialize identically.
  """

  @doc "Serializes an attribute value to a JSON-safe param, typed by `{type, constraints}`."
  @spec serialize_value(term(), {Ash.Type.t(), keyword()} | Ash.Type.t() | nil) :: term()
  def serialize_value(%DateTime{} = dt, _spec), do: DateTime.to_iso8601(dt)
  def serialize_value(%NaiveDateTime{} = ndt, _spec), do: NaiveDateTime.to_iso8601(ndt)
  def serialize_value(%Date{} = d, _spec), do: Date.to_iso8601(d)
  def serialize_value(%Time{} = t, _spec), do: Time.to_iso8601(t)
  def serialize_value(%Decimal{} = d, _spec), do: Decimal.to_string(d, :normal)

  def serialize_value(value, spec) when is_binary(value) do
    if binary_storage_spec?(spec), do: Base.encode64(value), else: value
  end

  def serialize_value(value, _spec), do: value

  @doc "Decodes a JSON scalar back to its Ash attribute value, typed by `{type, constraints}`."
  @spec load_value(term(), {Ash.Type.t(), keyword()} | Ash.Type.t() | nil) :: term()
  def load_value(value, spec) when is_binary(value) do
    case storage_class(spec) do
      :date -> decode_date(value)
      :utc_datetime -> decode_utc_datetime(value)
      :naive_datetime -> decode_naive_datetime(value)
      :time -> decode_time(value)
      :decimal -> decode_decimal(value)
      :binary -> decode_binary(value)
      :other -> value
    end
  end

  def load_value(value, _spec), do: value

  @doc "Whether the attribute's storage type is `:binary` (drives sensitive verifier + sort/range rejection)."
  @spec binary_storage?(Ash.Type.t(), keyword()) :: boolean()
  def binary_storage?(type, constraints), do: Ash.Type.storage_type(type, constraints) == :binary

  @doc """
  Whether an attribute's storage type supports a correct Cypher range comparison
  (`gt/lt/gte/lte`). False for `:binary` (base64 is not byte-order-preserving) and
  `:decimal` (D27 — stored as an exact string; ArcadeDB compares strings
  lexicographically, so a numeric range would be silently wrong). Drives the
  filter push-down guard: a range op on a non-comparable attr fails LOUD as
  `UnsupportedFilter` rather than returning wrong rows.
  """
  @spec range_comparable?(Ash.Type.t(), keyword()) :: boolean()
  def range_comparable?(type, constraints) do
    Ash.Type.storage_type(type, constraints) not in [:binary, :decimal]
  end

  @doc """
  The Cypher temporal constructor a bound comparison param must be wrapped in for a temporal
  attribute, or `nil`. ArcadeDB auto-coerces stored ISO8601 datetime/time strings to its native
  temporal types on write, so a `prop OP $stringparam` comparison silently matched NOTHING (the
  string param never equals a coerced temporal value — probe-verified). Wrapping the param —
  `datetime($p)` for datetime storage, `localtime($p)` for time storage — makes ArcadeDB compare
  temporal-to-temporal (probe-verified for fractional-second/usec values too). The `_usec` storage
  classes are covered SYMMETRICALLY with the decode side (`classify/1`) — omitting them reintroduces
  the silent-`[]` mis-page for a `:datetime`/`:time` attr declared `precision: :microsecond` (storage
  `:utc_datetime_usec`/`:time_usec`). `:date` is the exception: ArcadeDB does NOT coerce date-only
  strings, so it stays a string and compares correctly UNWRAPPED (`nil`).
  """
  @spec temporal_cypher_fn(Ash.Type.t(), keyword()) :: String.t() | nil
  def temporal_cypher_fn(type, constraints) do
    case Ash.Type.storage_type(type, constraints) do
      :utc_datetime -> "datetime"
      :utc_datetime_usec -> "datetime"
      :naive_datetime -> "datetime"
      :naive_datetime_usec -> "datetime"
      :time -> "localtime"
      :time_usec -> "localtime"
      _ -> nil
    end
  end

  @doc """
  Whether an attribute's storage type is numerically summable/averageable
  (`:integer`/`:float`). False for `:decimal` (stored as an exact string, so ArcadeDB
  `sum`/`avg` would concatenate/error, D27) and every non-numeric class. Drives the
  aggregate sum/avg guard (a sum over a non-numeric attr fails LOUD, never silently
  wrong or leaking).
  """
  @spec numeric_storage?(Ash.Type.t(), keyword()) :: boolean()
  def numeric_storage?(type, constraints) do
    Ash.Type.storage_type(type, constraints) in [:integer, :float]
  end

  @doc """
  Builds resource attributes from a flat ArcadeDB row map. Routes STRICTLY by
  `attribute_map` (declared attr → property name): reads only declared-attribute
  keys, `load_value`-coerces each by its type, and ignores every `@`-prefixed
  identity key (`@rid/@cat/@type/@in/@out`, kept by `Arcadic.Result`) and any
  undeclared property. No resource attribute can collide with an `@`-key.
  """
  @spec row_to_attrs(map(), %{atom() => String.t()}, %{atom() => {Ash.Type.t(), keyword()}}) ::
          map()
  def row_to_attrs(row, attribute_map, attribute_types) when is_map(row) do
    Map.new(attribute_map, fn {attr, prop} ->
      {attr, load_value(Map.get(row, prop), Map.get(attribute_types, attr))}
    end)
  end

  # --- private ---

  defp decode_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> value
    end
  end

  defp decode_utc_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> value
    end
  end

  defp decode_naive_datetime(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, ndt} -> ndt
      _ -> value
    end
  end

  defp decode_time(value) do
    case Time.from_iso8601(value) do
      {:ok, time} -> time
      _ -> value
    end
  end

  # Decimal.parse/1 returns {Decimal.t(), remainder} | :error — decode only a
  # fully-consumed decimal string; anything else passes through unchanged (a
  # non-decimal string must never raise from Decimal.new/1).
  defp decode_decimal(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> decimal
      _ -> value
    end
  end

  defp decode_binary(value) do
    case Base.decode64(value) do
      {:ok, decoded} -> decoded
      :error -> value
    end
  end

  defp binary_storage_spec?(spec) do
    case normalize_spec(spec) do
      {type, constraints} -> binary_storage?(type, constraints)
      :untyped -> false
    end
  end

  defp storage_class(spec) do
    case normalize_spec(spec) do
      {type, constraints} -> classify(Ash.Type.storage_type(type, constraints))
      :untyped -> :other
    end
  end

  defp classify(:date), do: :date
  defp classify(:utc_datetime), do: :utc_datetime
  defp classify(:utc_datetime_usec), do: :utc_datetime
  defp classify(:naive_datetime), do: :naive_datetime
  defp classify(:naive_datetime_usec), do: :naive_datetime
  defp classify(:time), do: :time

  # :time_usec decodes like :time (Time.from_iso8601 parses fractional seconds) — symmetric with the
  # temporal_cypher_fn wrapper, so a usec time round-trips AND compares correctly.
  defp classify(:time_usec), do: :time
  defp classify(:decimal), do: :decimal
  defp classify(:binary), do: :binary
  defp classify(_other), do: :other

  # `nil` means "no type info" (a defensive direct call, not a resource attribute):
  # pass the raw JSON scalar through unchanged rather than routing to `Ash.Type.Term`
  # whose storage_type is `:binary` — that would `Base.decode64` any 4-char-valid
  # string and silently corrupt it. Pass-through keeps serialize/load symmetric.
  defp normalize_spec(nil), do: :untyped
  defp normalize_spec({type, constraints}) when is_list(constraints), do: {type, constraints}
  defp normalize_spec(type), do: {type, []}
end
