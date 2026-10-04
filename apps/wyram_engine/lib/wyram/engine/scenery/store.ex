defmodule Wyram.Engine.Scenery.Store do
  @moduledoc "Optional bounded visual storage. Only scenery workers wait on its file I/O."
  use GenServer
  alias Wyram.Engine.{Native, PluginManager}
  alias Wyram.Engine.Scenery.{StoreFiles, Wire}
  alias Wyram.Scenery.Key

  def start_link(options) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, if(name, do: [name: name], else: []))
  end

  def get(server, requests) do
    if valid_requests?(requests),
      do: call(server, {:get, requests}, List.duplicate(nil, length(requests))),
      else: {:error, :invalid_cache_batch}
  end

  def put(server, entries), do: call(server, {:put, entries}, {:error, :cache_unavailable})
  def stats(server), do: GenServer.call(server, :stats)

  @impl true
  def init(options) do
    case limits(options) do
      nil -> :ignore
      {bytes, entries} -> initialize(Keyword.fetch!(options, :directory), bytes, entries)
    end
  end

  @impl true
  def handle_call(:stats, _, state) do
    result = Map.take(state, [:bytes, :max_bytes, :max_entries, :hits, :misses, :enabled])
    {:reply, Map.put(result, :entries, map_size(state.entries)), state}
  end

  def handle_call({:get, requests}, _, %{enabled: false} = state),
    do:
      {:reply, List.duplicate(nil, length(requests)),
       %{state | misses: state.misses + length(requests)}}

  def handle_call({:get, requests}, _, state) do
    {values, state} = Enum.map_reduce(requests, state, &lookup/2)
    binaries = Enum.reject(values, &is_nil/1)
    {:ok, validity} = Native.validate_visual_tiles(binaries)
    checks = Enum.zip(binaries, validity) |> Map.new()

    {values, state} =
      Enum.zip(requests, values)
      |> Enum.map_reduce(state, &accept_hit(&1, &2, checks))

    {:reply, values, state}
  end

  def handle_call({:put, _}, _, %{enabled: false} = state),
    do: {:reply, {:error, :cache_unavailable}, state}

  def handle_call({:put, entries}, _, state) do
    if valid_entries?(entries) do
      {result, next} = Enum.reduce_while(entries, {:ok, state}, &write_entry/2)
      {:reply, result, next}
    else
      {:reply, {:error, :invalid_cache_batch}, state}
    end
  end

  defp limits(options) do
    case Keyword.fetch(options, :max_bytes) do
      {:ok, bytes} ->
        {bytes, Keyword.fetch!(options, :max_entries)}

      :error ->
        case PluginManager.scenery() do
          nil -> nil
          config -> {config.cache_bytes, config.max_tiles * 4}
        end
    end
  end

  defp initialize(directory, bytes, entries)
       when bytes in 8..268_435_456 and entries in 1..16_384 do
    state = %{
      directory: directory,
      max_bytes: bytes,
      max_entries: entries,
      entries: %{},
      bytes: 8,
      clock: 0,
      hits: 0,
      misses: 0,
      enabled: true,
      free: :gb_sets.from_list(Enum.to_list(0..(entries - 1)))
    }

    case File.mkdir_p(directory) do
      :ok ->
        bound = StoreFiles.scan_bound(directory, entries)
        state = Enum.reduce(0..(bound - 1), state, &restore/2) |> room(0)

        state =
          if StoreFiles.write_slots(directory, entries) == :ok,
            do: state,
            else: %{state | enabled: false}

        {:ok, state}

      _ ->
        {:ok, %{state | bytes: 0, enabled: false}}
    end
  end

  defp accept_hit({{identity, _}, bytes}, state, checks) do
    if bytes && checks[bytes] do
      {bytes, %{state | hits: state.hits + 1}}
    else
      state = if bytes, do: drop(state, identity), else: state
      {nil, %{state | misses: state.misses + 1}}
    end
  end

  defp restore(slot, state) do
    case StoreFiles.header(state.directory, slot) do
      {:ok, entry} when slot < state.max_entries ->
        state = drop(state, entry.identity)

        %{
          state
          | entries: Map.put(state.entries, entry.identity, entry),
            bytes: state.bytes + entry.size,
            clock: max(state.clock, entry.used),
            free: :gb_sets.delete(slot, state.free)
        }

      :missing ->
        state

      _ ->
        if StoreFiles.remove(state.directory, slot) == :ok,
          do: state,
          else: %{state | enabled: false}
    end
  end

  defp lookup({identity, _key} = request, state) do
    case Map.fetch(state.entries, identity) do
      {:ok, entry} ->
        case StoreFiles.read(state.directory, entry.slot, request) do
          {:ok, bytes} ->
            clock = state.clock + 1

            {bytes,
             %{
               state
               | clock: clock,
                 entries: Map.put(state.entries, identity, %{entry | used: clock})
             }}

          :miss ->
            {nil, drop(state, identity)}
        end

      :error ->
        {nil, state}
    end
  end

  defp write_entry({identity, _, bytes} = value, {:ok, state}) do
    size = StoreFiles.size(bytes)

    if size + 8 > state.max_bytes do
      {:halt, {{:error, :oversized_cache_entry}, state}}
    else
      state = state |> drop(identity) |> room(size)
      write_available(value, state, size)
    end
  end

  defp write_available(_, %{enabled: false} = state, _),
    do: {:halt, {{:error, :cache_unavailable}, state}}

  defp write_available({identity, _, _} = value, state, size) do
    {slot, free} = :gb_sets.take_smallest(state.free)

    case StoreFiles.write(state.directory, slot, value) do
      :ok ->
        clock = state.clock + 1
        entry = %{identity: identity, slot: slot, size: size, used: clock}

        {:cont,
         {:ok,
          %{
            state
            | free: free,
              clock: clock,
              bytes: state.bytes + size,
              entries: Map.put(state.entries, identity, entry)
          }}}

      _ ->
        {:halt, {{:error, :cache_unavailable}, %{state | enabled: false}}}
    end
  end

  defp room(%{enabled: false} = state, _), do: state

  defp room(state, incoming) do
    if state.bytes + incoming <= state.max_bytes and
         (incoming == 0 or not :gb_sets.is_empty(state.free)) do
      state
    else
      {identity, _} = Enum.min_by(state.entries, fn {_, entry} -> {entry.used, entry.slot} end)
      state |> drop(identity) |> room(incoming)
    end
  end

  defp drop(state, identity) do
    case Map.fetch(state.entries, identity) do
      {:ok, entry} ->
        if StoreFiles.remove(state.directory, entry.slot) == :ok do
          %{
            state
            | entries: Map.delete(state.entries, identity),
              bytes: state.bytes - entry.size,
              free: :gb_sets.add(entry.slot, state.free)
          }
        else
          %{state | enabled: false}
        end

      :error ->
        state
    end
  end

  defp valid_requests?(requests) when is_list(requests) and length(requests) <= 2,
    do:
      Enum.all?(requests, fn
        {identity, key} when is_binary(identity) and byte_size(identity) == 32 ->
          Key.validate(key) == :ok

        _ ->
          false
      end)

  defp valid_requests?(_), do: false

  defp valid_entries?(entries) when is_list(entries) and length(entries) <= 2 do
    Enum.all?(entries, fn
      {identity, key, bytes}
      when is_binary(identity) and byte_size(identity) == 32 and is_binary(bytes) ->
        Key.validate(key) == :ok and Wire.valid_tile?({key, bytes})

      _ ->
        false
    end) and
      Native.validate_visual_tiles(Enum.map(entries, &elem(&1, 2))) ==
        {:ok, List.duplicate(true, length(entries))}
  end

  defp valid_entries?(_), do: false

  defp call(server, message, fallback) do
    # Retain a worker slot during slow I/O instead of abandoning queued calls.
    # The generation supervisor bounds these callers; renderer code never waits.
    GenServer.call(server, message, :infinity)
  catch
    :exit, _ -> fallback
  end
end
