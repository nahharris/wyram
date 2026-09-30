defmodule Wyram.Engine.ClientLifecycleTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias Wyram.Engine.ClientPort

  defp state(port) do
    %{
      port: port,
      sent: MapSet.new(),
      center: {0, 0},
      player: nil,
      exit_status: nil,
      exit_waiters: []
    }
  end

  test "normal close releases waiters without warning and retains status for late callers" do
    port = make_ref()
    tag = make_ref()
    assert {:noreply, waiting} = ClientPort.handle_call(:await_exit, {self(), tag}, state(port))

    log =
      capture_log(fn ->
        assert {:noreply, closed} = ClientPort.handle_info({port, {:exit_status, 0}}, waiting)
        assert_receive {^tag, {:ok, 0}}

        assert {:reply, {:ok, 0}, ^closed} =
                 ClientPort.handle_call(:await_exit, {self(), make_ref()}, closed)

        assert closed.port == nil
        assert closed.exit_waiters == []
      end)

    refute log =~ "warning"
  end

  test "failed close retains the native failure status" do
    port = make_ref()

    capture_log(fn ->
      assert {:noreply, closed} = ClientPort.handle_info({port, {:exit_status, 7}}, state(port))

      assert {:reply, {:ok, 7}, ^closed} =
               ClientPort.handle_call(:await_exit, {self(), make_ref()}, closed)
    end)
  end

  test "headless startup cannot wait forever for a nonexistent client" do
    missing = state(nil)

    assert {:reply, {:error, :client_unavailable}, ^missing} =
             ClientPort.handle_call(:await_exit, {self(), make_ref()}, missing)
  end
end
