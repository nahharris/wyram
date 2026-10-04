defmodule Wyram.Engine.LodScheduler do
  @moduledoc "Bounded async LOD generation with epoch/revision rejection and exact transport acknowledgements."

  @max_outstanding 8
  @max_plan_keys 4_608
  @max_attempts 3
  @max_revision 18_446_744_073_709_551_615
  @max_payload_bytes 1_048_576
  @tile_magic "LT01"
  @sizes [2, 4, 8, 16]

  defstruct generation_workers: 1,
            pending: [],
            wanted: MapSet.new(),
            epoch: nil,
            tasks: %{},
            outstanding: %{},
            stale_outstanding: MapSet.new(),
            published: MapSet.new(),
            revisions: %{},
            failures: %{}

  @type tile_key :: {2 | 4 | 8 | 16, integer(), integer(), integer()}
  @type accepted :: {non_neg_integer(), tile_key(), non_neg_integer(), binary()}
  @type t :: %__MODULE__{
          generation_workers: pos_integer(),
          pending: [tile_key()],
          wanted: MapSet.t(tile_key()),
          epoch: non_neg_integer() | nil,
          tasks: map(),
          outstanding: map(),
          stale_outstanding: MapSet.t({non_neg_integer(), tile_key(), non_neg_integer()}),
          published: MapSet.t(tile_key()),
          revisions: map(),
          failures: map()
        }

  @spec new(pos_integer()) :: t()
  def new(generation_workers) do
    unless is_integer(generation_workers) and generation_workers in 1..8,
      do: raise(ArgumentError, "LOD generation workers must be from 1 to 8")

    %__MODULE__{generation_workers: generation_workers}
  end

  @spec reset(t(), [tile_key()], non_neg_integer()) :: t()
  def reset(%__MODULE__{} = state, ordered_keys, epoch) when is_list(ordered_keys) do
    validate_epoch!(epoch)
    keys = Enum.uniq(ordered_keys)
    validate_keys!(keys)

    if length(keys) > @max_plan_keys,
      do: raise(ArgumentError, "LOD plan exceeds #{@max_plan_keys} keys")

    wanted = MapSet.new(keys)
    same_epoch? = epoch == state.epoch
    published = planned_published(state, same_epoch?, wanted)
    revisions = if same_epoch?, do: Map.take(state.revisions, keys), else: %{}
    failures = if same_epoch?, do: Map.take(state.failures, keys), else: %{}
    {inflight_transport, stale_outstanding} = planned_transport(state, same_epoch?, epoch, wanted)
    tasks = mark_obsolete_tasks(state.tasks, epoch, wanted)
    active = active_keys(tasks, epoch, wanted)
    pending = pending_keys(keys, published, active, inflight_transport, failures)

    %{
      state
      | pending: pending,
        wanted: wanted,
        epoch: epoch,
        tasks: tasks,
        stale_outstanding: stale_outstanding,
        published: published,
        revisions: revisions,
        failures: failures
    }
  end

  @spec planned_published(t(), boolean(), MapSet.t(tile_key())) :: MapSet.t(tile_key())
  defp planned_published(state, true, wanted),
    do:
      Enum.reduce(state.published, MapSet.new([]), fn key, acc ->
        if MapSet.member?(wanted, key), do: MapSet.put(acc, key), else: acc
      end)

  defp planned_published(_state, false, _wanted), do: MapSet.new([])

  defp planned_transport(state, false, _epoch, _wanted),
    do: {MapSet.new(), state.stale_outstanding}

  defp planned_transport(state, true, epoch, wanted) do
    Enum.reduce(state.outstanding, {MapSet.new(), state.stale_outstanding}, fn {id, _bytes},
                                                                               acc ->
      track_planned_transport(id, acc, epoch, wanted)
    end)
  end

  defp track_planned_transport(
         {transport_epoch, key, _revision} = id,
         {resident, stale},
         epoch,
         wanted
       )
       when transport_epoch == epoch do
    cond do
      not MapSet.member?(wanted, key) ->
        {resident, MapSet.put(stale, id)}

      MapSet.member?(stale, id) ->
        {resident, stale}

      true ->
        {MapSet.put(resident, key), stale}
    end
  end

  defp track_planned_transport(_id, acc, _epoch, _wanted), do: acc

  defp mark_obsolete_tasks(tasks, epoch, wanted) do
    Map.new(tasks, fn {ref, task} ->
      current? = task.epoch == epoch and MapSet.member?(wanted, task.key) and not task.obsolete?
      {ref, if(current?, do: task, else: %{task | obsolete?: true})}
    end)
  end

  defp active_keys(tasks, epoch, wanted) do
    Enum.reduce(tasks, MapSet.new(), fn {_ref, task}, acc ->
      if task.epoch == epoch and MapSet.member?(wanted, task.key) and not task.obsolete?,
        do: MapSet.put(acc, task.key),
        else: acc
    end)
  end

  @spec pending_keys(
          [tile_key()],
          MapSet.t(tile_key()),
          MapSet.t(tile_key()),
          MapSet.t(tile_key()),
          map()
        ) :: [tile_key()]
  defp pending_keys(keys, published, active, inflight_transport, failures) do
    Enum.reject(keys, fn key ->
      MapSet.member?(published, key) or MapSet.member?(active, key) or
        MapSet.member?(inflight_transport, key) or Map.get(failures, key, 0) >= @max_attempts
    end)
  end

  @spec invalidate(t(), [tile_key()]) :: t()
  def invalidate(%__MODULE__{} = state, keys) when is_list(keys) do
    keys = Enum.uniq(keys)
    validate_keys!(keys)
    invalidated = MapSet.new(keys)

    tasks =
      Map.new(state.tasks, fn {ref, task} ->
        stale? = task.epoch == state.epoch and MapSet.member?(invalidated, task.key)
        {ref, if(stale?, do: %{task | obsolete?: true}, else: task)}
      end)

    stale_outstanding =
      Enum.reduce(state.outstanding, state.stale_outstanding, fn
        {{epoch, key, _revision} = id, _bytes}, stale
        when epoch == state.epoch ->
          if MapSet.member?(invalidated, key), do: MapSet.put(stale, id), else: stale

        _, stale ->
          stale
      end)

    requeue = Enum.filter(keys, &MapSet.member?(state.wanted, &1))
    pending = Enum.uniq(requeue ++ Enum.reject(state.pending, &MapSet.member?(invalidated, &1)))
    published = Enum.reduce(keys, state.published, &MapSet.delete(&2, &1))
    revisions = Map.drop(state.revisions, keys)
    failures = Map.drop(state.failures, keys)

    %{
      state
      | pending: pending,
        tasks: tasks,
        stale_outstanding: stale_outstanding,
        published: published,
        revisions: revisions,
        failures: failures
    }
  end

  @spec dispatch(t(), (tile_key() -> term()), boolean()) :: t()
  def dispatch(%__MODULE__{} = state, fetch, near_busy \\ false)
      when is_function(fetch, 1) and is_boolean(near_busy) do
    if near_busy do
      state
    else
      free_total = @max_outstanding - map_size(state.tasks) - map_size(state.outstanding)
      free_workers = state.generation_workers - map_size(state.tasks)
      count = min(free_total, free_workers)
      dispatch_count(state, fetch, max(count, 0))
    end
  end

  @spec complete(t(), reference(), term()) :: {t(), [accepted()]}
  def complete(%__MODULE__{} = state, ref, result) when is_reference(ref) do
    case Map.pop(state.tasks, ref) do
      {nil, _tasks} ->
        {state, []}

      {task, tasks} ->
        Process.demonitor(ref, [:flush])
        state = %{state | tasks: tasks}
        complete_task(state, task, result)
    end
  end

  @spec failed(t(), reference()) :: t()
  def failed(%__MODULE__{} = state, ref) when is_reference(ref) do
    case Map.pop(state.tasks, ref) do
      {nil, _tasks} ->
        state

      {task, tasks} ->
        Process.demonitor(ref, [:flush])
        failed_job(%{state | tasks: tasks}, task)
    end
  end

  @spec acknowledge(t(), non_neg_integer(), tile_key(), non_neg_integer()) :: t()
  def acknowledge(%__MODULE__{} = state, epoch, key, revision) do
    id = {epoch, key, revision}

    case Map.pop(state.outstanding, id) do
      {nil, _outstanding} ->
        state

      {_bytes, outstanding} ->
        publish_acknowledged(state, outstanding, id, epoch, key, revision)
    end
  end

  @spec reject(t(), non_neg_integer(), tile_key(), non_neg_integer()) :: t()
  def reject(%__MODULE__{} = state, epoch, key, revision) do
    id = {epoch, key, revision}

    case Map.pop(state.outstanding, id) do
      {nil, _outstanding} ->
        state

      {_bytes, outstanding} ->
        reject_acknowledged(state, outstanding, id, epoch, key, revision)
    end
  end

  defp complete_task(state, task, result) do
    if current_task?(task, state) do
      complete_current_task(state, task, result)
    else
      {state, []}
    end
  end

  defp complete_current_task(state, task, result) do
    case normalize_result(result) do
      {:ok, revision, data} -> publish_result(state, task, revision, data)
      :error -> {failed_job(state, task), []}
    end
  end

  defp current_task?(task, state) do
    not task.obsolete? and task.epoch == state.epoch and
      MapSet.member?(state.wanted, task.key)
  end

  defp publish_acknowledged(state, outstanding, id, epoch, key, revision) do
    stale? = MapSet.member?(state.stale_outstanding, id)

    published =
      if not stale? and epoch == state.epoch and MapSet.member?(state.wanted, key) and
           Map.get(state.revisions, key) == revision do
        MapSet.put(state.published, key)
      else
        state.published
      end

    %{
      state
      | outstanding: outstanding,
        stale_outstanding: MapSet.delete(state.stale_outstanding, id),
        published: published
    }
  end

  defp reject_acknowledged(state, outstanding, id, epoch, key, revision) do
    stale_outstanding = MapSet.delete(state.stale_outstanding, id)

    if stale_transport?(state, id, epoch, key) do
      %{state | outstanding: outstanding, stale_outstanding: stale_outstanding}
    else
      requeue_rejected(state, outstanding, stale_outstanding, key, revision)
    end
  end

  defp stale_transport?(state, id, epoch, key) do
    MapSet.member?(state.stale_outstanding, id) or epoch != state.epoch or
      not MapSet.member?(state.wanted, key)
  end

  defp requeue_rejected(state, outstanding, stale_outstanding, key, revision) do
    revisions =
      if Map.get(state.revisions, key) == revision,
        do: Map.delete(state.revisions, key),
        else: state.revisions

    pending = if key in state.pending, do: state.pending, else: [key | state.pending]

    %{
      state
      | outstanding: outstanding,
        stale_outstanding: stale_outstanding,
        revisions: revisions,
        pending: pending
    }
  end

  defp dispatch_count(state, _fetch, 0), do: state
  defp dispatch_count(%{pending: []} = state, _fetch, _count), do: state

  defp dispatch_count(state, fetch, count) do
    [key | pending] = state.pending
    task = Task.Supervisor.async_nolink(Wyram.Engine.StreamSupervisor, fn -> fetch.(key) end)
    job = %{task: task, key: key, epoch: state.epoch, obsolete?: false}
    state = %{state | pending: pending, tasks: Map.put(state.tasks, task.ref, job)}
    dispatch_count(state, fetch, count - 1)
  end

  defp publish_result(state, task, revision, data) do
    key = task.key
    id = {task.epoch, key, revision}

    cond do
      revision <= Map.get(state.revisions, key, -1) ->
        {state, []}

      Map.has_key?(state.outstanding, id) ->
        state = %{
          state
          | revisions: Map.put(state.revisions, key, revision),
            stale_outstanding: MapSet.delete(state.stale_outstanding, id),
            failures: Map.delete(state.failures, key)
        }

        {state, []}

      true ->
        state = %{
          state
          | outstanding: Map.put(state.outstanding, id, byte_size(data)),
            revisions: Map.put(state.revisions, key, revision),
            failures: Map.delete(state.failures, key)
        }

        {state, [{task.epoch, key, revision, data}]}
    end
  end

  defp normalize_result({:ok, result}), do: normalize_result(result)

  defp normalize_result(%{revision: revision, data: data})
       when is_integer(revision) and revision in 0..@max_revision and is_binary(data) and
              byte_size(data) >= 4 and byte_size(data) <= @max_payload_bytes and
              binary_part(data, 0, 4) == @tile_magic,
       do: {:ok, revision, data}

  defp normalize_result(_), do: :error

  defp failed_job(state, task) do
    if task.obsolete? or task.epoch != state.epoch or not MapSet.member?(state.wanted, task.key) do
      state
    else
      record_failure(state, task)
    end
  end

  defp record_failure(state, task) do
    count = Map.get(state.failures, task.key, 0) + 1
    failures = Map.put(state.failures, task.key, count)

    pending =
      if not task.obsolete? and task.epoch == state.epoch and
           MapSet.member?(state.wanted, task.key) and
           count < @max_attempts and task.key not in state.pending do
        [task.key | state.pending]
      else
        state.pending
      end

    %{state | pending: pending, failures: failures}
  end

  defp validate_epoch!(epoch) do
    unless is_integer(epoch) and epoch >= 0 and epoch <= @max_revision,
      do: raise(ArgumentError, "LOD epoch must be a nonnegative u64")
  end

  defp validate_keys!(keys) do
    unless Enum.all?(keys, &valid_key?/1),
      do:
        raise(
          ArgumentError,
          "LOD plan keys must use sizes 2, 4, 8 or 16 and integer tile coordinates"
        )
  end

  defp valid_key?({size, x, y, z}),
    do: size in @sizes and Enum.all?([x, y, z], &is_integer/1)

  defp valid_key?(_), do: false
end
