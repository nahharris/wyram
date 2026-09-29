defmodule Wyram.Engine.Control do
  @moduledoc "Opt-in loopback JSON command socket for local automation."
  use GenServer

  alias Wyram.Engine.{ClientPort, PluginManager, World}

  @max_radius 3
  @coordinate_limit 2_147_483_647

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init(options) do
    directory = Keyword.fetch!(options, :directory)
    port = Keyword.fetch!(options, :port)

    {:ok, listener} =
      :gen_tcp.listen(port, [
        :binary,
        packet: :line,
        packet_size: 16_384,
        active: false,
        ip: {127, 0, 0, 1}
      ])

    {:ok, {_address, bound_port}} = :inet.sockname(listener)
    token = :crypto.strong_rand_bytes(24) |> Base.encode16(case: :lower)
    endpoint = Path.join(directory, "control.json")
    File.write!(endpoint, Jason.encode!(%{host: "127.0.0.1", port: bound_port, token: token}))
    {:ok, %{listener: listener, endpoint: endpoint, token: token}, {:continue, :accept}}
  end

  @impl true
  def handle_continue(:accept, state) do
    {:ok, _pid} = Task.start_link(fn -> accept_loop(state.listener, state.token) end)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listener)
    File.rm(state.endpoint)
    :ok
  end

  defp accept_loop(listener, token) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        response =
          case :gen_tcp.recv(socket, 0, 5_000) do
            {:ok, line} -> handle_request(line, token)
            _ -> error("invalid_request")
          end

        :gen_tcp.send(socket, Jason.encode!(response) <> "\n")
        :gen_tcp.close(socket)
        accept_loop(listener, token)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        raise "control socket failed: #{inspect(reason)}"
    end
  end

  defp handle_request(line, token) do
    case Jason.decode(line) do
      {:ok, %{"token" => ^token} = request} -> dispatch(request)
      {:ok, _} -> error("unauthorized")
      _ -> error("invalid_request")
    end
  end

  defp dispatch(%{"op" => "status"}) do
    client = ClientPort.snapshot()

    %{
      ok: true,
      client_connected: client.connected,
      player: client.player,
      plugins: PluginManager.plugin_versions(),
      blocks: PluginManager.blocks(),
      regions: Registry.count(Wyram.Engine.RegionRegistry),
      beam_processes: :erlang.system_info(:process_count),
      beam_memory_bytes: :erlang.memory(:total)
    }
  end

  defp dispatch(%{"op" => "inspect"} = request) do
    radius = Map.get(request, "radius", 1)
    player = ClientPort.snapshot().player
    at = Map.get(request, "at") || player_position(player)

    if valid_radius?(radius) and valid_position?(at, radius) do
      inspect_blocks(at, radius) |> Map.put(:ok, true)
    else
      error(if(is_nil(at), do: "no_player", else: "invalid_request"))
    end
  end

  defp dispatch(%{"op" => "set_block", "x" => x, "y" => y, "z" => z, "block" => block}) do
    id = if is_binary(block), do: PluginManager.blocks()[block], else: block

    if valid_position?([x, y, z]) and is_integer(id) and id in 0..65_535 do
      case World.set_block(x, y, z, id) do
        {:ok, revision} -> %{ok: true, revision: revision}
        {:error, reason} -> error(Atom.to_string(reason))
      end
    else
      error("invalid_request")
    end
  end

  defp dispatch(%{"op" => "teleport", "x" => x, "y" => y, "z" => z} = request) do
    yaw = Map.get(request, "yaw", 0.0)
    pitch = Map.get(request, "pitch", 0.0)

    if valid_vector?([x, y, z]) and valid_vector?([yaw, pitch]) and
         abs(yaw) <= 1_000 and abs(pitch) <= 1.55 do
      case ClientPort.teleport(x, y, z, yaw, pitch) do
        :ok -> %{ok: true, accepted: true}
        {:error, reason} -> error(Atom.to_string(reason))
      end
    else
      error("invalid_request")
    end
  end

  defp dispatch(_), do: error("invalid_request")

  defp inspect_blocks([cx, cy, cz], radius) do
    positions =
      for x <- (cx - radius)..(cx + radius),
          y <- (cy - radius)..(cy + radius),
          z <- (cz - radius)..(cz + radius),
          do: {x, y, z}

    chunks =
      positions
      |> Enum.map(fn {x, y, z} -> chunk_key(x, y, z) end)
      |> Enum.uniq()
      |> Map.new(fn {x, y, z} = key -> {key, World.get_chunk(x, y, z).data} end)

    names = Map.new(PluginManager.blocks(), fn {name, id} -> {id, name} end)

    blocks =
      Enum.flat_map(positions, fn {x, y, z} ->
        data = Map.fetch!(chunks, chunk_key(x, y, z))
        index = (Integer.mod(y, 16) * 16 + Integer.mod(z, 16)) * 16 + Integer.mod(x, 16)
        id = data |> binary_part(index * 2, 2) |> :binary.decode_unsigned(:little)

        if id == 0 do
          []
        else
          [%{x: x, y: y, z: z, id: id, name: Map.get(names, id, "unknown")}]
        end
      end)

    %{
      center: [cx, cy, cz],
      radius: radius,
      blocks: blocks,
      air_count: length(positions) - length(blocks)
    }
  end

  defp chunk_key(x, y, z),
    do: {Integer.floor_div(x, 16), Integer.floor_div(y, 16), Integer.floor_div(z, 16)}

  defp player_position(nil), do: nil
  defp player_position(%{x: x, y: y, z: z}), do: [floor(x), floor(y), floor(z)]

  defp valid_radius?(radius), do: is_integer(radius) and radius in 0..@max_radius

  defp valid_position?(position, margin \\ 0),
    do:
      is_list(position) and length(position) == 3 and
        Enum.all?(position, &(is_integer(&1) and abs(&1) <= @coordinate_limit - margin))

  defp valid_vector?(vector), do: Enum.all?(vector, &(is_number(&1) and abs(&1) <= 1_000_000))
  defp error(reason), do: %{ok: false, error: reason}
end
