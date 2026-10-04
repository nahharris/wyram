defmodule Wyram.Engine.Scenery.ServiceTest do
  use ExUnit.Case, async: true
  alias Wyram.Engine.Scenery
  alias Wyram.Engine.Scenery.EditView
  alias Wyram.Scenery.{Config, Key}

  defmodule ReadModel do
    use GenServer
    def init(model), do: {:ok, model}
    def handle_call({:watch_scenery, _}, _, model), do: {:reply, model, model}
  end

  setup do
    owner = self()
    supervisor = start_supervised!({Task.Supervisor, []})
    edits = EditView.new(%{})
    model = %{generation: %{bounds: {0, 15}}, edits: edits, stamp: 0, session: make_ref()}
    {:ok, world} = GenServer.start_link(ReadModel, model)
    on_exit(fn -> if Process.alive?(world), do: GenServer.stop(world) end)

    fetch = fn model, keys ->
      send(owner, {:started, self(), model.stamp, keys})
      receive do: (:finish -> {:ok, Enum.map(keys, &empty/1)})
    end

    service =
      start_supervised!(
        Supervisor.child_spec(
          {Scenery,
           name: nil,
           world: world,
           supervisor: supervisor,
           config: Config.new!(%{distance: 128, max_level: 1}),
           fetch: fetch},
          restart: :temporary
        )
      )

    {:ok, service: service, model: model, supervisor: supervisor}
  end

  test "retired service jobs hold worker slots and the new view resumes after they exit", %{
    service: service,
    supervisor: supervisor
  } do
    owner = self()

    retired =
      for _ <- 1..2 do
        {:ok, pid} =
          Task.Supervisor.start_child(supervisor, fn ->
            send(owner, {:retired_started, self()})
            receive do: (:stop -> :ok)
          end)

        assert_receive {:retired_started, ^pid}
        pid
      end

    Scenery.view(service, self(), {0, 0, 0})
    assert_receive {:scenery_plan, _, _, _, _}
    refute_receive {:started, _, _, _}, 40
    assert length(Task.Supervisor.children(supervisor)) == 2
    send(hd(retired), :stop)
    assert_receive {:started, worker, 0, _}, 1000
    assert Process.alive?(worker)
    assert length(Task.Supervisor.children(supervisor)) == 2
    send(List.last(retired), :stop)
    assert_receive {:started, _, 0, _}, 1000
  end

  test "generation and delivery remain bounded until the client acknowledges", %{service: service} do
    Scenery.view(service, self(), {0, 0, 0})
    assert_receive {:scenery_plan, epoch, _, plan, _}
    assert length(plan.roots) > 4
    assert_receive {:started, one, 0, keys_one}
    assert_receive {:started, two, 0, keys_two}
    refute_receive {:started, _, _, _}, 10
    send(one, :finish)
    assert_receive {:scenery_tiles, ^epoch, token, tiles_one}
    assert Enum.map(tiles_one, &elem(&1, 0)) == keys_one
    assert_receive {:started, three, 0, _}
    send(two, :finish)
    assert_receive {:started, _, 0, _}
    refute_receive {:scenery_tiles, _, _, _}, 10
    Scenery.acknowledge(service, epoch, make_ref())
    refute_receive {:scenery_tiles, _, _, _}, 10
    Scenery.acknowledge(service, epoch, token)
    assert_receive {:scenery_tiles, ^epoch, _, tiles_two}
    assert Enum.map(tiles_two, &elem(&1, 0)) == keys_two
    assert map_size(:sys.get_state(service).loader.tasks) == 2
    assert Process.alive?(three)
  end

  test "view changes discard old work and content changes reject still-wanted old jobs", %{
    service: service,
    model: model
  } do
    Scenery.view(service, self(), {0, 0, 0})
    assert_receive {:scenery_plan, first, _, _, _}
    assert_receive {:started, one, 0, _}
    assert_receive {:started, two, 0, _}
    Scenery.view(service, self(), {2048, 0, 2048})
    assert_receive {:scenery_plan, second, _, _, _}
    assert second > first
    refute_receive {:started, _, _, _}, 10
    send(one, :finish)
    assert_receive {:started, three, 0, _}
    refute_receive {:scenery_tiles, _, _, _}, 10
    EditView.put(model.edits, {128, 0, 128}, :binary.copy(<<0>>, 8192))
    send(service, {:scenery_changed, model.session, 1, {128, 0, 128}})
    assert_receive {:scenery_plan, third, 1, _, _}
    assert third > second
    send(three, :finish)
    assert_receive {:started, _, 1, _}
    send(two, :finish)
    assert_receive {:started, _, 1, _}
    refute_receive {:scenery_tiles, _, _, _}, 10
  end

  test "identical views preserve cache and reader termination releases wanted tiles", %{
    service: service
  } do
    viewer = spawn(fn -> receive do: (:stop -> :ok) end)
    Scenery.view(service, viewer, {0, 0, 0})
    :sys.get_state(service)
    before = :sys.get_state(service)
    Scenery.view(service, viewer, {0, 0, 0})
    assert :sys.get_state(service).epoch == before.epoch
    send(viewer, :stop)
    monitor = Process.monitor(viewer)
    assert_receive {:DOWN, ^monitor, :process, ^viewer, _}
    eventually(fn -> assert :sys.get_state(service).client == nil end)
    assert :sys.get_state(service).loader.wanted == MapSet.new()
  end

  test "acknowledgement checks the edit stamp before delivering already cached tiles", %{
    service: service,
    model: model
  } do
    Scenery.view(service, self(), {0, 0, 0})
    assert_receive {:scenery_plan, epoch, 0, _, _}
    assert_receive {:started, one, 0, _}
    assert_receive {:started, two, 0, _}
    send(one, :finish)
    assert_receive {:scenery_tiles, ^epoch, token, _}
    assert_receive {:started, _, 0, _}
    send(two, :finish)
    assert_receive {:started, _, 0, _}
    EditView.put(model.edits, {0, 0, 0}, :binary.copy(<<0>>, 8192))
    Scenery.acknowledge(service, epoch, token)
    assert_receive {:scenery_plan, next, 1, _, _}
    assert next > epoch
    refute_receive {:scenery_tiles, ^epoch, _, _}, 10
  end

  test "an unavailable world read model stops delivery before the owner death notification", %{
    service: service,
    model: model
  } do
    Scenery.view(service, self(), {0, 0, 0})
    assert_receive {:scenery_plan, _, _, _, _}
    assert_receive {:started, worker, 0, _}
    assert_receive {:started, _, 0, _}
    monitor = Process.monitor(service)
    :ets.delete(model.edits)
    send(worker, :finish)

    assert_receive {:DOWN, ^monitor, :process, ^service,
                    {:shutdown, :world_read_model_unavailable}},
                   1000

    refute_receive {:scenery_tiles, _, _, _}, 10
  end

  test "coalesced durable edits retain unrelated cached tiles and reject old generation", %{
    service: service,
    model: model
  } do
    Scenery.view(service, self(), {0, 0, 0})
    assert_receive {:scenery_plan, epoch, 0, initial_plan, _}
    assert_receive {:started, one, 0, _}
    assert_receive {:started, two, 0, _}
    send(one, :finish)
    assert_receive {:scenery_tiles, ^epoch, token, _}
    assert_receive {:started, retired_one, 0, _}
    send(two, :finish)
    assert_receive {:started, retired_two, 0, _}
    cached = :sys.get_state(service).loader.cache
    assert map_size(cached) == 4
    edited = cached |> Map.keys() |> Enum.sort() |> Enum.take(2)

    # Multiple durable writes can precede the service's next event. Invalidating
    # only that event's chunk would retain stale data from the earlier write.
    for %Key{position: {x, y, z}} <- edited do
      EditView.put(model.edits, {x * 2, y * 2, z * 2}, :binary.copy(<<0>>, 8192))
    end

    Scenery.acknowledge(service, epoch, token)
    assert_receive {:scenery_plan, next, 2, next_plan, _}
    assert next > epoch
    expected = Map.drop(cached, edited)
    assert next_plan.lineage == initial_plan.lineage
    refute next_plan.content == initial_plan.content
    assert Enum.all?(edited, &(next_plan.revisions[&1] == 2))
    assert Enum.all?(Map.keys(expected), &(next_plan.revisions[&1] == 0))
    assert :sys.get_state(service).loader.cache == expected
    assert map_size(:sys.get_state(service).loader.tasks) == 2
    refute_receive {:scenery_tiles, ^epoch, _, _}, 10

    send(retired_one, :finish)
    assert_receive {:started, _, 2, _}
    send(retired_two, :finish)
    assert_receive {:started, _, 2, _}
    assert :sys.get_state(service).loader.cache == expected
  end

  test "overwritten change history falls back to a complete cache reset", %{
    service: service,
    model: model
  } do
    Scenery.view(service, self(), {0, 0, 0})
    assert_receive {:scenery_plan, epoch, 0, _, _}
    assert_receive {:started, one, 0, _}
    assert_receive {:started, _, 0, _}
    send(one, :finish)
    assert_receive {:scenery_tiles, ^epoch, token, _}
    assert_receive {:started, _, 0, _}
    assert map_size(:sys.get_state(service).loader.cache) == 2

    for _ <- 1..1025 do
      EditView.put(model.edits, {500, 0, 500}, :binary.copy(<<0>>, 8192))
    end

    Scenery.acknowledge(service, epoch, token)
    assert_receive {:scenery_plan, next, 1025, _, _}
    assert next > epoch
    assert :sys.get_state(service).loader.cache == %{}
  end

  defp eventually(assertion, attempts \\ 50)
  defp eventually(assertion, 1), do: assertion.()

  defp eventually(assertion, attempts) do
    assertion.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(2)
      eventually(assertion, attempts - 1)
  end

  defp empty(%Key{position: {x, y, z}, level: level}),
    do: <<"WSL1", level, 0, 0, 0, x::little-signed-32, y::little-signed-32, z::little-signed-32>>
end
