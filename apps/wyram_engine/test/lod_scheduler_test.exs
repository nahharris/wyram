defmodule Wyram.Engine.LodSchedulerTest do
  use ExUnit.Case, async: false

  alias Wyram.Engine.LodScheduler

  setup do
    if Process.whereis(Wyram.Engine.StreamSupervisor) == nil do
      start_supervised!({Task.Supervisor, name: Wyram.Engine.StreamSupervisor})
    end

    :ok
  end

  test "near-busy pauses dispatch and generation workers cap active tasks" do
    owner = self()
    keys = for x <- 0..7, do: {2, x, 0, 0}

    fetch = fn key ->
      send(owner, {:fetch, self(), key})
      %{revision: 1, data: tile_payload()}
    end

    state = LodScheduler.new(2) |> LodScheduler.reset(keys, 1)

    assert LodScheduler.dispatch(state, fetch, true) == state
    refute_receive {:fetch, _, _}, 20

    state = LodScheduler.dispatch(state, fetch)
    assert map_size(state.tasks) == 2
    assert_receive {:fetch, _pid_a, first}
    assert_receive {:fetch, _pid_b, second}
    assert Enum.sort([first, second]) == Enum.sort(Enum.take(keys, 2))

    state = complete_and_ack(state, first)
    state = LodScheduler.dispatch(state, fetch)
    assert map_size(state.tasks) == 2
    assert_receive {:fetch, _pid, third}
    assert third == Enum.at(keys, 2)
    settle_tasks(state)
  end

  test "obsolete jobs keep slots across resets and old-epoch results are discarded" do
    owner = self()
    old_key = {2, 0, 0, 0}
    new_key = {2, 1, 0, 0}
    fetch = blocked_fetch(owner)

    state =
      LodScheduler.new(1) |> LodScheduler.reset([old_key], 1) |> LodScheduler.dispatch(fetch)

    assert_receive {:fetch, pid, ^old_key}
    [old_ref] = Map.keys(state.tasks)

    state = LodScheduler.reset(state, [new_key], 2)
    assert Process.alive?(pid)
    assert map_size(state.tasks) == 1
    assert state.pending == [new_key]
    assert LodScheduler.dispatch(state, fetch).tasks == state.tasks

    send(pid, {:finish, %{revision: 1, data: tile_payload()}})
    assert_receive {^old_ref, old_result}
    {state, []} = LodScheduler.complete(state, old_ref, old_result)
    assert map_size(state.tasks) == 0

    state = LodScheduler.dispatch(state, fetch)
    assert_receive {:fetch, new_pid, ^new_key}
    new_ref = task_ref(state, new_key)
    send(new_pid, {:finish, %{revision: 2, data: tile_payload()}})
    assert_receive {^new_ref, new_result}
    {state, [{2, ^new_key, 2, payload}]} = LodScheduler.complete(state, new_ref, new_result)
    assert payload == tile_payload()
    refute MapSet.member?(state.published, new_key)
    assert state.pending == []
    state = LodScheduler.reset(state, [new_key], 2)
    assert state.pending == []
    refute MapSet.member?(state.published, new_key)
    state = LodScheduler.acknowledge(state, 2, new_key, 2)
    assert MapSet.member?(state.published, new_key)
  end

  test "invalidation retires resident revisions, obsoletes old jobs, and refreshes wanted keys" do
    owner = self()
    key = {2, 0, 0, 0}
    fetch = blocked_fetch(owner)
    state = LodScheduler.new(1) |> LodScheduler.reset([key], 4) |> LodScheduler.dispatch(fetch)
    assert_receive {:fetch, old_pid, ^key}
    old_ref = task_ref(state, key)

    state = LodScheduler.invalidate(state, [key])
    assert state.pending == [key]
    refute MapSet.member?(state.published, key)
    send(old_pid, {:finish, %{revision: 1, data: tile_payload()}})
    assert_receive {^old_ref, old_result}
    {state, []} = LodScheduler.complete(state, old_ref, old_result)

    state = LodScheduler.dispatch(state, fetch)
    assert_receive {:fetch, new_pid, ^key}
    new_ref = task_ref(state, key)
    send(new_pid, {:finish, %{revision: 2, data: tile_payload()}})
    assert_receive {^new_ref, new_result}
    {state, [{4, ^key, 2, payload}]} = LodScheduler.complete(state, new_ref, new_result)
    assert payload == tile_payload()
    assert state.revisions[key] == 2
    refute MapSet.member?(state.published, key)
    assert state.outstanding == %{{4, key, 2} => byte_size(tile_payload())}
    state = LodScheduler.acknowledge(state, 4, key, 1)
    assert map_size(state.outstanding) == 1
    state = LodScheduler.acknowledge(state, 4, key, 2)
    assert state.outstanding == %{}
    assert MapSet.member?(state.published, key)
  end

  test "eight running and unacknowledged jobs share one hard slot limit" do
    owner = self()
    keys = for x <- 0..9, do: {2, x, 0, 0}

    fetch = fn key ->
      send(owner, {:fetch, self(), key})
      %{revision: 0, data: tile_payload()}
    end

    state = LodScheduler.new(8) |> LodScheduler.reset(keys, 7) |> LodScheduler.dispatch(fetch)
    assert map_size(state.tasks) == 8
    assert_receive {:fetch, _, _}, 8

    first_ref = state.tasks |> Map.keys() |> hd()
    first_key = state.tasks[first_ref].key
    assert_receive {^first_ref, result}
    {state, [{7, ^first_key, 0, _payload}]} = LodScheduler.complete(state, first_ref, result)
    assert map_size(state.tasks) == 7
    assert map_size(state.outstanding) == 1
    assert state.pending == Enum.drop(keys, 8)

    assert LodScheduler.dispatch(state, fetch).tasks == state.tasks
    state = LodScheduler.acknowledge(state, 7, first_key, 1)
    assert map_size(state.outstanding) == 1
    state = LodScheduler.acknowledge(state, 7, first_key, 0)
    state = LodScheduler.dispatch(state, fetch)
    assert map_size(state.tasks) == 8
    assert state.pending == [List.last(keys)]
    settle_tasks(state)
  end

  test "reset preserves delivered keys within an epoch and clears them on epoch change" do
    owner = self()
    key = {2, 0, 0, 0}
    another = {2, 1, 0, 0}

    fetch = fn tile ->
      send(owner, {:fetch, self(), tile})
      %{revision: 3, data: tile_payload()}
    end

    state = LodScheduler.new(1) |> LodScheduler.reset([key], 9) |> LodScheduler.dispatch(fetch)
    ref = task_ref(state, key)
    assert_receive {^ref, result}
    {state, [{9, ^key, 3, _payload}]} = LodScheduler.complete(state, ref, result)
    state = LodScheduler.acknowledge(state, 9, key, 3)
    state = LodScheduler.reset(state, [key, another], 9)

    assert state.pending == [another]
    assert MapSet.member?(state.published, key)

    state = LodScheduler.reset(state, [key], 10)
    assert state.pending == [key]
    refute MapSet.member?(state.published, key)
    settle_tasks(state)
  end

  test "obsolete transport acknowledgements free slots without publishing" do
    owner = self()
    key = {2, 0, 0, 0}

    fetch = fn tile ->
      send(owner, {:fetch, self(), tile})
      %{revision: 3, data: tile_payload()}
    end

    state = LodScheduler.new(1) |> LodScheduler.reset([key], 9) |> LodScheduler.dispatch(fetch)
    ref = task_ref(state, key)
    assert_receive {^ref, result}
    {state, [{9, ^key, 3, _payload}]} = LodScheduler.complete(state, ref, result)
    state = LodScheduler.reset(state, [key], 10)

    refute MapSet.member?(state.published, key)
    state = LodScheduler.acknowledge(state, 9, key, 3)
    refute MapSet.member?(state.published, key)
    assert map_size(state.outstanding) == 0
    assert state.pending == [key]
  end

  test "transport removed from the wanted plan becomes stale before a later re-entry" do
    owner = self()
    key = {2, 0, 0, 0}

    fetch = fn tile ->
      send(owner, {:fetch, self(), tile})
      %{revision: 3, data: tile_payload()}
    end

    state = LodScheduler.new(1) |> LodScheduler.reset([key], 9) |> LodScheduler.dispatch(fetch)
    ref = task_ref(state, key)
    assert_receive {^ref, result}
    {state, [{9, ^key, 3, _payload}]} = LodScheduler.complete(state, ref, result)

    state = LodScheduler.reset(state, [], 9)
    state = LodScheduler.reset(state, [key], 9)
    assert state.pending == [key]

    state = LodScheduler.acknowledge(state, 9, key, 3)
    refute MapSet.member?(state.published, key)
    assert state.pending == [key]
  end

  test "failures from obsolete tasks do not penalize a re-entered key" do
    owner = self()
    key = {2, 0, 0, 0}

    fetch = fn tile ->
      send(owner, {:fetch, self(), tile})

      receive do
        :fail -> raise "obsolete failure"
      end
    end

    state = LodScheduler.new(1) |> LodScheduler.reset([key], 4) |> LodScheduler.dispatch(fetch)
    ref = task_ref(state, key)
    assert_receive {:fetch, pid, ^key}
    state = LodScheduler.reset(state, [], 4) |> LodScheduler.reset([key], 4)
    assert state.pending == [key]

    send(pid, :fail)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}
    state = LodScheduler.failed(state, ref)

    assert state.failures == %{}
    assert state.pending == [key]
  end

  test "rejection frees only an exact transport, clears its stamp, and retries the same revision" do
    owner = self()
    key = {2, 0, 0, 0}

    fetch = fn tile ->
      send(owner, {:fetch, self(), tile})
      %{revision: 7, data: tile_payload()}
    end

    state = LodScheduler.new(1) |> LodScheduler.reset([key], 5) |> LodScheduler.dispatch(fetch)
    ref = task_ref(state, key)
    assert_receive {^ref, result}
    {state, [{5, ^key, 7, _payload}]} = LodScheduler.complete(state, ref, result)

    state = LodScheduler.reject(state, 5, key, 6)
    assert map_size(state.outstanding) == 1
    state = LodScheduler.reject(state, 5, key, 7)
    assert state.outstanding == %{}
    assert state.pending == [key]
    refute Map.has_key?(state.revisions, key)
    refute MapSet.member?(state.published, key)

    state = LodScheduler.dispatch(state, fetch)
    retry_ref = task_ref(state, key)
    assert_receive {^retry_ref, retry_result}
    {state, [{5, ^key, 7, _payload}]} = LodScheduler.complete(state, retry_ref, retry_result)
    state = LodScheduler.acknowledge(state, 5, key, 7)
    assert MapSet.member?(state.published, key)
  end

  test "transient pressure rejections do not consume terminal generation retries" do
    owner = self()
    key = {2, 0, 0, 0}

    fetch = fn tile ->
      send(owner, {:fetch, self(), tile})
      %{revision: 7, data: tile_payload()}
    end

    state = LodScheduler.new(1) |> LodScheduler.reset([key], 5)

    state =
      Enum.reduce(1..3, state, fn _attempt, state ->
        state = LodScheduler.dispatch(state, fetch)
        ref = task_ref(state, key)
        assert_receive {^ref, result}
        {state, [{5, ^key, 7, _payload}]} = LodScheduler.complete(state, ref, result)
        state = LodScheduler.reject(state, 5, key, 7)
        assert state.pending == [key]
        assert state.outstanding == %{}
        refute Map.has_key?(state.revisions, key)
        assert state.failures == %{}
        state
      end)

    state = LodScheduler.dispatch(state, fetch)
    ref = task_ref(state, key)
    assert_receive {^ref, result}
    {state, [{5, ^key, 7, _payload}]} = LodScheduler.complete(state, ref, result)
    state = LodScheduler.acknowledge(state, 5, key, 7)

    assert state.pending == []
    assert state.outstanding == %{}
    assert MapSet.member?(state.published, key)
  end

  test "rejecting an obsolete transport frees the old id without requeueing it" do
    owner = self()
    key = {2, 0, 0, 0}
    next = {2, 1, 0, 0}

    fetch = fn tile ->
      send(owner, {:fetch, self(), tile})
      %{revision: 1, data: tile_payload()}
    end

    state = LodScheduler.new(1) |> LodScheduler.reset([key], 5) |> LodScheduler.dispatch(fetch)
    ref = task_ref(state, key)
    assert_receive {^ref, result}
    {state, [{5, ^key, 1, _payload}]} = LodScheduler.complete(state, ref, result)
    state = LodScheduler.reset(state, [next], 6)
    state = LodScheduler.reject(state, 5, key, 1)

    assert state.pending == [next]
    assert state.outstanding == %{}
    refute MapSet.member?(state.published, key)
  end

  test "result payloads must be a bounded LT01 tile encoding" do
    owner = self()
    key = {2, 0, 0, 0}

    for invalid_data <- [<<>>, <<"BAD!", 0::96>>, <<"LT01", 0::1_048_577*8>>] do
      fetch = fn tile ->
        send(owner, {:fetch, self(), tile})
        %{revision: 1, data: invalid_data}
      end

      state = LodScheduler.new(1) |> LodScheduler.reset([key], 1) |> LodScheduler.dispatch(fetch)
      ref = task_ref(state, key)
      assert_receive {:fetch, _pid, ^key}
      assert_receive {^ref, result}
      {state, []} = LodScheduler.complete(state, ref, result)
      assert map_size(state.outstanding) == 0
      assert state.failures[key] == 1
    end
  end

  test "failed tasks retry only a bounded number of times" do
    owner = self()
    key = {2, 0, 0, 0}

    fetch = fn tile ->
      send(owner, {:fetch, self(), tile})
      raise "planned failure"
    end

    state = LodScheduler.new(1) |> LodScheduler.reset([key], 1)

    Enum.reduce(1..3, state, fn attempt, state ->
      state = LodScheduler.dispatch(state, fetch)
      ref = task_ref(state, key)
      assert_receive {:fetch, _pid, ^key}
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}
      state = LodScheduler.failed(state, ref)
      assert state.failures[key] == attempt

      if attempt < 3, do: assert(state.pending == [key])
      if attempt == 3, do: assert(state.pending == [])
      state
    end)
  end

  defp blocked_fetch(owner) do
    fn key ->
      send(owner, {:fetch, self(), key})

      receive do
        {:finish, result} -> result
      end
    end
  end

  defp tile_payload, do: <<"LT01", 0x88, 0x99, 0::80>>

  defp task_ref(state, key) do
    Enum.find_value(state.tasks, fn {ref, task} -> if task.key == key, do: ref end)
  end

  defp complete_and_ack(state, key) do
    ref = task_ref(state, key)
    assert_receive {^ref, result}
    {state, accepted} = LodScheduler.complete(state, ref, result)

    Enum.reduce(accepted, state, fn {epoch, tile, revision, _data}, acc ->
      LodScheduler.acknowledge(acc, epoch, tile, revision)
    end)
  end

  defp settle_tasks(state) do
    Enum.reduce(Map.keys(state.tasks), state, fn ref, acc ->
      assert_receive {^ref, result}
      {acc, accepted} = LodScheduler.complete(acc, ref, result)

      Enum.reduce(accepted, acc, fn {epoch, key, revision, _data}, nested ->
        LodScheduler.acknowledge(nested, epoch, key, revision)
      end)
    end)
  end
end
