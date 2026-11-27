defmodule AshArcadic.Cast do
  @moduledoc """
  Value serialization and flat-JSON-row decode for the ArcadeDB wire.

  ArcadeDB rows are flat JSON maps (`%{"@rid" => .., "@cat" => "v", <props>}`), not
  AGE agtype text — so there is NO tag: values are typed-decoded from the resource's
  attribute map. Values pass through `Ash.Type.dump_to_native/3` before wire
  encoding and `Ash.Type.cast_stored/3` after wire decoding. Binary-storage
  values use base64 on the wire. Writes and filter parameters share the same
  representation.
  """

  alias AshArcadic.Errors.QueryFailed

  @doc "Dumps an Ash value to its native representation and encodes it for ArcadeDB."
  @spec serialize_value(term(), {Ash.Type.t(), keyword()} | Ash.Type.t() | nil) :: term()
  def serialize_value(value, nil), do: encode_storage(value, nil)
  def serialize_value(value, {nil, _constraints}), do: serialize_value(value, nil)

  def serialize_value(value, spec) do
    {type, constraints} = normalize_spec(spec)

    case dump_stored(type, constraints, value) do
      {:ok, wire} ->
        wire

      :error ->
        raise QueryFailed, query: "ArcadeDB encode", reason: "native attribute dump failed"
    end
  end

  defp dump_stored(type, constraints, value) do
    case Ash.Type.dump_to_native(type, value, constraints) do
      {:ok, native} -> {:ok, encode_storage(native, Ash.Type.storage_type(type, constraints))}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp encode_storage(nil, _storage), do: nil
  defp encode_storage(value, :binary) when is_binary(value), do: Base.encode64(value)

  # Ash's UUID dump is 16 bytes. ArcadeDB's existing UUID representation is text.
  defp encode_storage(<<_::128>> = value, :uuid) do
    {:ok, uuid} = Ash.Type.cast_stored(Ash.Type.UUID, value, [])
    uuid
  end

  defp encode_storage(%DateTime{} = dt, _storage), do: DateTime.to_iso8601(dt)
  defp encode_storage(%NaiveDateTime{} = ndt, _storage), do: NaiveDateTime.to_iso8601(ndt)
  defp encode_storage(%Date{} = date, _storage), do: Date.to_iso8601(date)
  defp encode_storage(%Time{} = time, _storage), do: Time.to_iso8601(time)
  defp encode_storage(%Decimal{} = decimal, _storage), do: Decimal.to_string(decimal, :normal)
  defp encode_storage(%Ash.Vector{} = vector, :vector), do: Ash.Vector.to_list(vector)

  # Canonical strings keep map properties legal in openCypher and allow equality
  # comparisons. On an unencodable leaf the original value reaches the encode gate.
  defp encode_storage(value, :map) do
    case canonical_value(value) do
      {:ok, json} -> json
      :error -> value
    end
  end

  defp encode_storage(values, {:array, storage}) when is_list(values),
    do: Enum.map(values, &encode_storage(&1, storage))

  defp encode_storage(value, _storage), do: value

  @doc "Decodes a JSON scalar back to its Ash attribute value, typed by `{type, constraints}`."
  @spec load_value(term(), {Ash.Type.t(), keyword()} | Ash.Type.t() | nil) :: term()
  def load_value(value, nil), do: value

  def load_value(value, spec) do
    {type, constraints} = normalize_spec(spec)

    case cast_stored(type, constraints, value) do
      {:ok, loaded} ->
        loaded

      :error ->
        raise QueryFailed,
          query: "ArcadeDB decode",
          reason: "stored attribute cast failed"
    end
  end

  defp cast_stored(type, constraints, value) do
    with {:ok, native} <- decode_storage(value, Ash.Type.storage_type(type, constraints)),
         {:ok, _} = loaded <- Ash.Type.cast_stored(type, native, constraints) do
      loaded
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp decode_storage(value, :binary) when is_binary(value), do: Base.decode64(value)

  defp decode_storage(value, :map) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _ -> :error
    end
  end

  defp decode_storage(values, {:array, storage}) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case decode_storage(value, storage) do
        {:ok, native} -> {:cont, {:ok, [native | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  # Embedded documents from older servers already have their native map shape.
  # Ash's temporal and decimal types accept the ISO/exact strings directly.
  defp decode_storage(value, _storage), do: {:ok, value}

  @doc "Whether the attribute's storage type is `:binary` (drives sensitive verifier + sort/range rejection)."
  @spec binary_storage?(Ash.Type.t(), keyword()) :: boolean()
  def binary_storage?(type, constraints), do: storage_type(type, constraints) == :binary

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
    orderable_storage?(storage_type(type, constraints))
  end

  @doc """
  The Cypher temporal constructor a bound comparison param must be wrapped in for a temporal
  attribute, or `nil`. ArcadeDB auto-coerces stored ISO8601 datetime/time strings to its native
  temporal types on write, so a `prop OP $stringparam` comparison silently matched NOTHING (the
  string param never equals a coerced temporal value — probe-verified). Wrapping the param —
  `datetime($p)` for datetime storage, `localtime($p)` for time storage — makes ArcadeDB compare
  temporal-to-temporal (probe-verified for fractional-second/usec values too). The `_usec` storage
  classes use the same wrappers — omitting them reintroduces
  the silent-`[]` mis-page for a `:datetime`/`:time` attr declared `precision: :microsecond` (storage
  `:utc_datetime_usec`/`:time_usec`). `:date` is the exception: ArcadeDB does NOT coerce date-only
  strings, so it stays a string and compares correctly UNWRAPPED (`nil`).
  """
  @spec temporal_cypher_fn(Ash.Type.t(), keyword()) :: String.t() | nil
  def temporal_cypher_fn(type, constraints) do
    case storage_type(type, constraints) do
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
    storage_type(type, constraints) in [:integer, :float]
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

  # Canonical JSON: identical output for identical maps regardless of key insertion/hash order —
  # maps render as sorted `"key":value` fragment lists, so the encoding is a pure function of the
  # key-value SET (the equality law `serialize_value(m) == serialize_value(m') when m == m'`).
  # Uses Jason's tuple form per fragment so a non-UTF8 binary/atom-key failure is a SOFT :error
  # (the caller passes the original value through for the pre-wire encode gates), never a raise.
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

  defp storage_type(type, constraints),
    do: Ash.Type.storage_type(Ash.Type.get_type(type), constraints)

  defp normalize_spec({type, constraints}) when is_list(constraints),
    do: {Ash.Type.get_type(type), constraints}

  defp normalize_spec(type), do: {Ash.Type.get_type(type), []}

  defp render_list_element(nil), do: "null"
  defp render_list_element(fragment) when is_binary(fragment), do: fragment
end
