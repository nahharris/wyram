defmodule Wyram.Engine.Scenery do
  @moduledoc "Supervised visual generation with bounded work and acknowledged delivery."
  use GenServer
  require Logger
  alias Wyram.Engine.{PluginManager, World}
  alias Wyram.Engine.Scenery.{EditView, Fetch, Loader, Plan}
  alias Wyram.Scenery.Config

  def start_link(options) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, if(name, do: [name: name], else: []))
  end

  def view(service, client, observer), do: GenServer.cast(service, {:view, client, observer})
  def disconnect(service, client), do: GenServer.cast(service, {:disconnect, client})

  def acknowledge(service, epoch, token),
    do: GenServer.cast(service, {:acknowledge, epoch, token})

  @impl true
  def init(options) do
    config =
      case Keyword.fetch(options, :config) do
        {:ok, config} -> config
        :error -> PluginManager.scenery()
      end

    if config do
      :ok = Config.validate(config)
      world = Keyword.get(options, :world, World)
      model = GenServer.call(world, {:watch_scenery, self()})

      if Keyword.get(options, :name, __MODULE__) == __MODULE__,
        do: send_if_started(Wyram.Engine.ClientPort, :scenery_ready)

      {:ok,
       %{
         config: config,
         model: model,
         world_ref: Process.monitor(GenServer.whereis(world)),
         supervisor: Keyword.get(options, :supervisor, Wyram.Engine.StreamSupervisor),
         fetch: Keyword.get(options, :fetch, &Fetch.run/2),
         loader: Loader.new(config),
         client: nil,
         client_ref: nil,
         observer: nil,
         plan: nil,
         epoch: 0,
         content_id: System.unique_integer([:positive, :monotonic]),
         sent: MapSet.new(),
         waiting: nil
       }}
    else
      :ignore
    end
  end

  @impl true
  def handle_cast({:view, client, observer}, state) when is_pid(client) do
    state = refresh_if_changed(state)

    if client == state.client and observer == state.observer do
      {:noreply, state}
    else
      case Plan.new(observer, state.model.generation.bounds, state.config) do
        {:ok, plan} ->
          if state.client_ref, do: Process.demonitor(state.client_ref, [:flush])

          state = %{
            state
            | client: client,
              client_ref: Process.monitor(client),
              observer: observer
          }

          {:noreply, state |> replace(plan) |> work()}

        {:error, reason} ->
          send(client, {:scenery_error, reason})
          {:noreply, state}
      end
    end
  end

  def handle_cast({:acknowledge, epoch, token}, state) do
    state = refresh_if_changed(state)

    state =
      if state.epoch == epoch and state.waiting == token and token != nil,
        do: %{state | waiting: nil},
        else: state

    {:noreply, work(state)}
  end

  def handle_cast({:disconnect, client}, %{client: client} = state) do
    if state.client_ref, do: Process.demonitor(state.client_ref, [:flush])
    {:noreply, release_view(state)}
  end

  def handle_cast({:disconnect, _}, state), do: {:noreply, state}

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    state = refresh_if_changed(state)
    {loader, accepted} = Loader.complete(state.loader, ref, result)

    case accepted do
      {:error, reason} -> Logger.warning("Scenery generation failed: #{inspect(reason)}")
      _ -> :ok
    end

    {:noreply, work(%{state | loader: loader})}
  end

  def handle_info({:scenery_changed, session, _stamp, _key}, state)
      when session == state.model.session do
    {:noreply, state |> refresh_if_changed() |> work()}
  end

  def handle_info({:scenery_changed, _, _, _}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _, reason}, %{world_ref: ref} = state),
    do: {:stop, {:world_unavailable, reason}, state}

  def handle_info({:DOWN, ref, :process, _, _}, %{client_ref: ref} = state) do
    {:noreply, release_view(state)}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, state) do
    {loader, _} = Loader.complete(state.loader, ref, {:error, {:worker_exit, reason}})
    {:noreply, work(%{state | loader: loader})}
  end

  defp release_view(state) do
    empty = %{nodes: %{}, order: [], roots: []}
    loader = Loader.reset(state.loader, empty, content(state))

    %{
      state
      | client: nil,
        client_ref: nil,
        observer: nil,
        plan: nil,
        loader: loader,
        waiting: nil,
        sent: MapSet.new()
    }
  end

  defp send_if_started(name, message) do
    if pid = Process.whereis(name), do: send(pid, message)
  end

  defp refresh_if_changed(state) do
    case EditView.stamp(state.model.edits) do
      {:ok, stamp} when stamp != state.model.stamp ->
        state = %{
          state
          | model: %{state.model | stamp: stamp},
            content_id: System.unique_integer([:positive, :monotonic])
        }

        if state.plan, do: replace(state, state.plan), else: state

      {:ok, _} ->
        state

      {:error, :unavailable} ->
        exit({:shutdown, :world_read_model_unavailable})
    end
  end

  defp replace(state, plan) do
    plan = Map.put(plan, :content, state.content_id)
    epoch = System.unique_integer([:positive, :monotonic])
    send(state.client, {:scenery_plan, epoch, state.model.stamp, plan, state.config})

    %{
      state
      | plan: plan,
        epoch: epoch,
        waiting: nil,
        sent: MapSet.new(),
        loader: Loader.reset(state.loader, plan, content(state))
    }
  end

  defp work(%{client: nil} = state), do: state

  defp work(state) do
    model = state.model
    fetch = state.fetch
    loader = Loader.dispatch(state.loader, state.supervisor, fn keys -> fetch.(model, keys) end)
    deliver(%{state | loader: loader})
  end

  defp deliver(%{waiting: waiting} = state) when not is_nil(waiting), do: state

  defp deliver(state) do
    keys =
      state.plan.order
      |> Enum.reject(&MapSet.member?(state.sent, &1))
      |> Enum.filter(&Map.has_key?(state.loader.cache, &1))
      |> Enum.take(2)

    if keys == [] do
      state
    else
      token = make_ref()
      tiles = Enum.map(keys, &{&1, Map.fetch!(state.loader.cache, &1)})
      send(state.client, {:scenery_tiles, state.epoch, token, tiles})
      %{state | waiting: token, sent: Enum.reduce(keys, state.sent, &MapSet.put(&2, &1))}
    end
  end

  defp content(state), do: {state.model.session, state.model.stamp}
end
