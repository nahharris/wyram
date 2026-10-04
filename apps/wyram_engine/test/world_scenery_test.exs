defmodule Wyram.Engine.WorldSceneryTest do
  use ExUnit.Case, async: true
  alias Wyram.Engine.Scenery.EditView
  alias Wyram.Engine.World

  setup do
    directory =
      Path.join(System.tmp_dir!(), "wyram-edit-view-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    chunk = %{data: :binary.copy(<<42::little-16>>, 4096), revision: 7}
    edits = %{{-2, -1, -2} => chunk}

    state = %{
      path: Path.join(directory, "world.json"),
      generation: %{resource: nil, identity: "legacy-v1", seed: 41, bounds: {0, 511}},
      seed: 41,
      plugins: %{},
      blocks: %{"test:stone" => 42},
      edited: edits,
      edit_view: EditView.new(edits),
      scenery_session: make_ref(),
      scenery_watchers: %{}
    }

    {:ok, state: state, chunk: chunk}
  end

  test "visual readers receive generation and protected edits without region activation", %{
    state: state
  } do
    assert {:reply, model, ^state} = World.handle_call(:scenery_read_model, nil, state)
    assert model.generation == state.generation
    assert model.session == state.scenery_session
    assert model.stamp == 0
    assert model.edits == state.edit_view

    assert EditView.snapshot(model.edits, [{-2, -1, -2}, {9, 9, 9}], 0) ==
             {:ok, 0, [{{-2, -1, -2}, state.edited[{-2, -1, -2}].data}]}
  end

  test "only durable edits publish a new snapshot and invalidate subscribed workers", %{
    state: state,
    chunk: chunk
  } do
    assert {:reply, model, watched} = World.handle_call({:watch_scenery, self()}, nil, state)
    assert model.stamp == 0
    edited = %{chunk | data: :binary.copy(<<0>>, 8192), revision: 8}

    assert {:reply, :ok, next} =
             World.handle_call({:persist_edit, {-2, -1, -2}, edited}, nil, watched)

    assert next.edited[{-2, -1, -2}] == edited
    assert_receive {:scenery_changed, session, 1, {-2, -1, -2}}
    assert session == model.session
    assert {:ok, 1, [{_, data}]} = EditView.snapshot(model.edits, [{-2, -1, -2}], 1)
    assert data == edited.data
    assert {:error, :stale} = EditView.snapshot(model.edits, [{-2, -1, -2}], 0)
    assert Jason.decode!(File.read!(state.path))["chunks"]["-2,-1,-2"]["revision"] == 8

    failed = %{next | path: Path.join([Path.dirname(state.path), "missing", "world.json"])}

    assert {:reply, {:error, :enoent}, ^failed} =
             World.handle_call({:persist_edit, {-2, -1, -2}, chunk}, nil, failed)

    assert {:ok, 1, [{_, ^data}]} = EditView.snapshot(model.edits, [{-2, -1, -2}], 1)
    refute_receive {:scenery_changed, _, _, _}, 10
  end

  test "duplicate subscriptions reuse a monitor and terminated readers are removed", %{
    state: state
  } do
    assert {:reply, _, watched} = World.handle_call({:watch_scenery, self()}, nil, state)
    assert {:reply, _, again} = World.handle_call({:watch_scenery, self()}, nil, watched)
    assert watched == again
    [{pid, ref}] = Map.to_list(watched.scenery_watchers)
    assert pid == self()
    assert {:noreply, cleaned} = World.handle_info({:DOWN, ref, :process, pid, :normal}, watched)
    assert cleaned.scenery_watchers == %{}
    Process.demonitor(ref, [:flush])
  end
end
