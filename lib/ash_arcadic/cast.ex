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

  # `:map`-storage values ride the wire as a CANONICAL JSON STRING (keys recursively sorted, so
  # equal maps always encode to the SAME string — equality/in filters on new-format rows are
  # consistent). Why: ArcadeDB's 26.10 line enforces the openCypher property-value rule — property
  # values must be primitives or arrays of primitives — so a map-valued property write that ≤26.9
  # servers stored as an embedded document is now rejected 400 (`InvalidPropertyTypeException`;
  # SQL keeps MAP first-class but this data layer writes openCypher). A JSON string is a legal
  # property value on EVERY supported server version, and it also lifts the old 32-level server
  # nesting cap. On UNENCODABLE content (a non-UTF8 binary nested inside) the encoder returns
  # :error and the value passes through UNCHANGED — the pre-wire encode gates then reject it
  # value-free naming the attribute (Rule 4), exactly as they did when maps rode the wire raw.
  def serialize_value(value, spec) when is_map(value) do
    case storage_class(spec) do
      :map_json ->
        case encode_canonical_json(value) do
          {:ok, json} -> json
          :error -> value
        end

      _ ->
        value
    end
  end

  # `{:array, :map}` storage: element-wise — the array stays a server-visible LIST (arrays of
  # primitives are legal property values), each map element becoming its canonical JSON string.
  # Same soft-fail contract: one unencodable element returns the ORIGINAL list for the gates.
  def serialize_value(value, spec) when is_list(value) do
    case storage_class(spec) do
      :array_of_map_json ->
        case encode_canonical_list(value) do
          {:ok, encoded} -> encoded
          :error -> value
        end

      _ ->
        value
    end
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
      :map_json -> decode_map_json(value)
      :other -> value
    end
  end

  # New-format rows decode the canonical JSON string; rows stored as embedded documents by
  # ash_arcadic <= 1.1 on a <=26.9 server come back as maps and pass through unchanged.
  def load_value(value, _spec) when is_map(value), do: value

  # `{:array, :map}` rows: a list of canonical JSON strings decodes element-wise (nil kept);
  # a list of maps (legacy embedded rows) passes through unchanged.
  def load_value(value, spec) when is_list(value) do
    case storage_class(spec) do
      :array_of_map_json ->
        Enum.map(value, fn
          %{} = element -> element
          nil -> nil
          element when is_binary(element) -> decode_map_json(element)
          element -> element
        end)

      _ ->
        value
    end
  end

  def load_value(value, _spec), do: value

  @doc "Whether the attribute's storage type is `:binary` (drives sensitive verifier + sort/range rejection)."
  @spec binary_storage?(Ash.Type.t(), keyword()) :: boolean()
  def binary_storage?(type, constraints), do: Ash.Type.storage_type(type, constraints) == :binary

  # The ALLOWLIST of storage types with a total order ArcadeDB compares correctly (a range/keyset op
  # over anything else is silently wrong): the ordered scalars + `:date` (stored an ISO string —
  # lexicographic == chronological) + the coerced temporal family. NOT included, deliberately:
  # `:binary` (base64 not byte-order-preserving), `:decimal` (exact string, lexicographic ≠ numeric),
  # `:map`/`{:array,_}` (composites — `:struct`/`:union`/`:keyword`/`:tuple` store as `:map`),
  # `:vector` (a float list, no total order — order by DISTANCE via vector search, never the raw
  # vector), `:duration`, and ANY unknown/custom storage — unknown fails CLOSED (the delta-review
  # catch: a denylist here silently admits every future non-orderable storage).
  @orderable_storage [
    :integer,
    :float,
    :boolean,
    :string,
    :ci_string,
    :uuid,
    :date,
    :utc_datetime,
    :utc_datetime_usec,
    :naive_datetime,
    :naive_datetime_usec,
    :time,
    :time_usec
  ]

  @doc """
  Whether a STORAGE type has a total order ArcadeDB compares correctly — the allowlist above; any
  storage NOT on it (binary/decimal/map/array/vector/duration/custom) fails CLOSED. Shared by the
  `can?({:sort, storage})` gate and `range_comparable?/2` so sort and range stay symmetric.
  """
  @spec orderable_storage?(term()) :: boolean()
  def orderable_storage?(storage), do: storage in @orderable_storage

  @doc """
  Whether an attribute's storage type has a TOTAL ORDER ArcadeDB compares correctly for a range/keyset
  op (`gt/lt/gte/lte`) — `orderable_storage?/1` over the attribute's resolved storage type. An
  ALLOWLIST (fail-closed): a range/keyset op on a non-orderable attr fails LOUD
  (`UnsupportedFilter`/`UnsortableField`), never silently wrong/truncated rows.
  """
  @spec range_comparable?(Ash.Type.t(), keyword()) :: boolean()
  def range_comparable?(type, constraints) do
    orderable_storage?(Ash.Type.storage_type(type, constraints))
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

  # Lenient like every other decode arm: a non-JSON string (a legacy plain-string value, or a
  # corrupted row) passes through raw rather than erroring mid-load.
  defp decode_map_json(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _} -> value
    end
  end

  # Canonical JSON: identical output for identical maps regardless of key insertion/hash order —
  # maps render as sorted `"key":value` fragment lists, so the encoding is a pure function of the
  # key-value SET (the equality law `serialize_value(m) == serialize_value(m') when m == m'`).
  # Uses Jason's tuple form per fragment so a non-UTF8 binary/atom-key failure is a SOFT :error
  # (the caller passes the original value through for the pre-wire encode gates), never a raise.
  defp encode_canonical_json(value), do: canonical_value(value)

  defp encode_canonical_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn
      # A nil ELEMENT stays JSON null in the outer array (legal there), not the
      # string "null".
      nil, {:ok, acc} ->
        {:cont, {:ok, [nil | acc]}}

      element, {:ok, acc} ->
        case canonical_value(element) do
          {:ok, encoded} -> {:cont, {:ok, [encoded | acc]}}
          :error -> {:halt, :error}
        end
    end)
    |> case do
      {:ok, encoded} -> {:ok, Enum.reverse(encoded)}
      :error -> :error
    end
  end

  # Temporal/decimal leaves serialize exactly as Jason encodes them (ISO8601 / plain string), so
  # a map written on <=26.9 servers (raw-map wire form) and the same map written as canonical
  # JSON agree element-for-element. (Struct clauses precede the is_map clause — structs ARE maps.)
  defp canonical_value(%DateTime{} = v), do: {:ok, inspect_json(DateTime.to_iso8601(v))}
  defp canonical_value(%NaiveDateTime{} = v), do: {:ok, inspect_json(NaiveDateTime.to_iso8601(v))}
  defp canonical_value(%Date{} = v), do: {:ok, inspect_json(Date.to_iso8601(v))}
  defp canonical_value(%Time{} = v), do: {:ok, inspect_json(Time.to_iso8601(v))}
  defp canonical_value(%Decimal{} = v), do: {:ok, inspect_json(Decimal.to_string(v, :normal))}

  # Any OTHER struct with a Jason encoder (Ash.CiString, custom Derive structs) encodes as its
  # JSON leaf — via Jason's TUPLE form, so a struct WITHOUT an encoder is a soft :error (the
  # raw struct never rides a raise; the caller passes the original value through for the gates).
  # The __struct__ pattern keeps PLAIN maps on the sorted-fragments path below.
  defp canonical_value(%{__struct__: _} = v) do
    case Jason.encode(v) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, _} -> :error
    end
  end

  defp canonical_value(map) when is_map(map) do
    map
    |> Enum.reduce_while({:ok, []}, fn {key, value}, {:ok, acc} ->
      with {:ok, key_json} <- canonical_key(key),
           {:ok, value_json} <- canonical_value(value) do
        {:cont, {:ok, ["#{key_json}:#{value_json}" | acc]}}
      else
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, fragments} -> {:ok, "{" <> Enum.join(Enum.sort(fragments), ",") <> "}"}
      :error -> :error
    end
  end

  defp canonical_value(list) when is_list(list) do
    case encode_canonical_list(list) do
      # nil elements render as JSON null INSIDE the joined array literal.
      {:ok, encoded} -> {:ok, "[" <> Enum.map_join(encoded, ",", &render_list_element/1) <> "]"}
      :error -> :error
    end
  end

  defp canonical_value(nil), do: {:ok, "null"}
  defp canonical_value(true), do: {:ok, "true"}
  defp canonical_value(false), do: {:ok, "false"}
  defp canonical_value(v) when is_number(v), do: encode_json_scalar(v)
  defp canonical_value(v) when is_binary(v), do: encode_json_scalar(v)
  # Jason encodes bare atom VALUES as strings; atoms as map keys go through canonical_key.
  defp canonical_value(v) when is_atom(v), do: encode_json_scalar(Atom.to_string(v))
  defp canonical_value(_other), do: :error

  defp canonical_key(key) when is_binary(key), do: encode_json_scalar(key)
  defp canonical_key(key) when is_atom(key), do: encode_json_scalar(Atom.to_string(key))
  # Jason accepts numeric keys via String.Chars — the canonical form mirrors that, so a
  # numeric-keyed map still ENCODES (a soft :error here would pass the raw map through, and
  # the encode gate would wave it on — Jason encodes it too — sending a map to a 26.10 wire
  # that rejects map properties).
  defp canonical_key(key) when is_integer(key), do: encode_json_scalar(Integer.to_string(key))
  defp canonical_key(key) when is_float(key), do: encode_json_scalar(Float.to_string(key))
  defp canonical_key(_other), do: :error

  defp inspect_json(s), do: Jason.encode!(s)

  # Normalizes Jason's {:error, %Jason.EncodeError{}} (whose message carries the offending
  # bytes) to the soft :error the canonical encoder's callers branch on — the value NEVER
  # rides out of this function.
  defp encode_json_scalar(scalar) do
    case Jason.encode(scalar) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, _} -> :error
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

  # The map-family storage classes (see serialize_value's :map comment): `:map` (also the
  # storage of :struct/:keyword/:tuple/:union — the same openCypher property-value rule hits
  # them all) and `{:array, :map}`.
  defp classify(:map), do: :map_json
  defp classify({:array, :map}), do: :array_of_map_json
  defp classify(_other), do: :other

  # `nil` means "no type info" (a defensive direct call, not a resource attribute):
  # pass the raw JSON scalar through unchanged rather than routing to `Ash.Type.Term`
  # whose storage_type is `:binary` — that would `Base.decode64` any 4-char-valid
  # string and silently corrupt it. Pass-through keeps serialize/load symmetric.
  defp normalize_spec(nil), do: :untyped
  defp normalize_spec({type, constraints}) when is_list(constraints), do: {type, constraints}
  defp normalize_spec(type), do: {type, []}

  defp render_list_element(nil), do: "null"
  defp render_list_element(fragment) when is_binary(fragment), do: fragment
end
