defmodule Wyram.Engine.CharacterBatchTest do
  use ExUnit.Case, async: true
  alias Wyram.Engine.Native

  test "a batch with missing terrain reports unavailable for every body" do
    requests = [
      {{0.5, 0.0, 0.5}, {1.0, -0.1, 0.0}, 0.28, 1.8},
      {{-0.5, 0.0, -0.5}, {0.0, 0.0, 0.0}, 0.28, 1.8}
    ]

    assert {:ok, results} = Native.sweep_bodies([], requests)
    assert length(results) == 2
    for {_, _, unavailable} <- results, do: assert(unavailable)
  end

  test "malformed chunks and oversized query batches are rejected" do
    assert {:error, _} = Native.sweep_bodies([{{0, 0, 0}, <<0>>}], [])
    request = {{0.5, 0.0, 0.5}, {0.0, 0.0, 0.0}, 0.28, 1.8}
    assert {:error, _} = Native.sweep_bodies([], List.duplicate(request, 257))
  end

  test "fixed-step replay is independent of native render schedules" do
    alias Wyram.Character.{Input, Profile, State}

    chunks =
      for x <- -1..0, y <- -1..0, z <- -1..0 do
        data =
          if y == -1, do: :binary.copy(<<1::little-16>>, 4096), else: :binary.copy(<<0>>, 8192)

        {{x, y, z}, data}
      end

    input = %{Input.idle() | forward: 1.0}

    replay = fn rate ->
      {body, _} =
        Enum.reduce(1..(rate * 2), {State.new(Profile.default(), {0.5, 0.0, 0.5}), 0}, fn frame,
                                                                                          {body,
                                                                                           previous} ->
          target = div(frame * 50, rate)

          body =
            if target == previous,
              do: body,
              else:
                Enum.reduce((previous + 1)..target, body, fn _, acc ->
                  {prepared, query} = State.prepare(acc, input)
                  {:ok, [result]} = Native.sweep_bodies(chunks, [query])
                  State.finish(prepared, result)
                end)

          {body, target}
        end)

      body
    end

    assert replay.(30).position == replay.(60).position
    assert replay.(60).position == replay.(144).position
    assert replay.(30).grounded
    assert_in_delta elem(replay.(30).position, 2), -9.5, 1.0e-8
  end

  test "the Windows client lifecycle monitor retains an OS handle independently of the pipe" do
    if :os.type() == {:win32, :nt} do
      assert {:ok, watch} =
               Native.watch_process(:os.getpid() |> List.to_string() |> String.to_integer())

      assert {:ok, nil} = Native.process_status(watch)
      assert {:error, _} = Native.watch_process(0)
    end
  end
end
