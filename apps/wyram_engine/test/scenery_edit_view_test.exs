defmodule Wyram.Engine.Scenery.EditViewTest do
  use ExUnit.Case, async: true
  alias Wyram.Engine.Scenery.EditView
  @air :binary.copy(<<0>>, 8192)

  test "saved edits are read without generation and only the owning process can write" do
    key = {-1, -12, 3}
    table = EditView.new(%{key => %{data: @air, revision: 8}})
    assert EditView.stamp(table) == {:ok, 0}
    assert EditView.snapshot(table, [key, {99, 0, 99}], 0) == {:ok, 0, [{key, @air}]}
    owner = self()

    worker =
      spawn(fn ->
        send(owner, {:read, EditView.snapshot(table, [key], 0)})

        try do
          EditView.put(table, key, @air)
          send(owner, :wrote)
        rescue
          ArgumentError -> send(owner, :protected)
        end
      end)

    assert is_pid(worker)
    assert_receive {:read, {:ok, 0, [{^key, @air}]}}
    assert_receive :protected
    refute_receive :wrote, 10
    assert EditView.put(table, key, :binary.copy(<<1>>, 8192)) == 1
    assert EditView.stamp(table) == {:ok, 1}
    assert EditView.snapshot(table, [key], 0) == {:error, :stale}
    assert EditView.snapshot(table, [key], 1) == {:ok, 1, [{key, :binary.copy(<<1>>, 8192)}]}
  end

  test "snapshots are bounded and unavailable tables return errors" do
    table = EditView.new(%{})

    assert EditView.snapshot(table, List.duplicate({0, 0, 0}, 257), 0) ==
             {:error, :oversized_snapshot}

    assert EditView.snapshot(table, [{0, 0}], 0) == {:error, :invalid_snapshot}
    assert EditView.snapshot(table, [{62_501, 0, 0}], 0) == {:error, :invalid_snapshot}
    assert EditView.snapshot(table, [{0.0, 0, 0}], 0) == {:error, :invalid_snapshot}
    assert EditView.snapshot(table, [], 0) == {:ok, 0, []}
    :ets.delete(table)
    assert EditView.stamp(table) == {:error, :unavailable}
    assert EditView.snapshot(table, [], 0) == {:error, :unavailable}
  end

  test "concurrent snapshots never pair a material version with a different stamp" do
    key = {0, 0, 0}
    table = EditView.new(%{key => %{data: @air, revision: 0}})
    owner = self()

    worker =
      spawn_link(fn ->
        send(owner, :reading)

        loop = fn loop, reads ->
          receive do
            :finish -> send(owner, {:finished, reads})
          after
            0 ->
              case EditView.stamp(table) do
                {:ok, expected} ->
                  case EditView.snapshot(table, [key], expected) do
                    {:ok, stamp, [{^key, <<version::little-64, _::binary>>}]} ->
                      if version != stamp, do: raise("incoherent snapshot")

                    {:error, :stale} ->
                      :ok
                  end
              end

              loop.(loop, reads + 1)
          end
        end

        loop.(loop, 0)
      end)

    assert_receive :reading

    for version <- 1..1000 do
      data = <<version::little-64, 0::size(8184 * 8)>>
      assert EditView.put(table, key, data) == version
      if rem(version, 100) == 0, do: Process.sleep(1)
    end

    send(worker, :finish)
    assert_receive {:finished, reads}, 1000
    assert reads > 0
  end
end
