defmodule Wyram.Engine.Scenery.StoreFiles do
  @moduledoc false
  alias Wyram.Engine.Scenery.Wire
  @max_payload 40_980
  @header_bytes 72
  @max_slots 16_384

  def scan_bound(directory, current) do
    case read_bounded(Path.join(directory, "slots"), 8) do
      {:ok, <<"WCS1", previous::32>>} when previous in 1..@max_slots -> max(previous, current)
      {:error, :enoent} -> current
      _ -> @max_slots
    end
  end

  def write_slots(directory, count),
    do: File.write(Path.join(directory, "slots"), <<"WCS1", count::32>>)

  def header(directory, slot) do
    file = path(directory, slot)

    with {:ok, %{type: :regular, size: size, mtime: modified}}
         when size >= @header_bytes + 20 and size <= @header_bytes + @max_payload <-
           File.lstat(file, time: :posix),
         {:ok, <<"WSC1", identity::binary-32, length::32, _checksum::binary-32>>} <-
           read_prefix(file, @header_bytes),
         true <- size == @header_bytes + length do
      {:ok, %{identity: identity, slot: slot, size: size, used: modified}}
    else
      {:error, :enoent} -> :missing
      _ -> :invalid
    end
  end

  def read(directory, slot, {identity, key}) do
    with {:ok, data} <- read_bounded(path(directory, slot), @header_bytes + @max_payload),
         <<"WSC1", ^identity::binary-32, length::32, checksum::binary-32, bytes::binary>> <- data,
         true <- byte_size(bytes) == length,
         true <- checksum == checksum(identity, bytes),
         true <- Wire.valid_tile?({key, bytes}) do
      {:ok, bytes}
    else
      _ -> :miss
    end
  end

  def write(directory, slot, {identity, _key, bytes}) do
    header =
      <<"WSC1", identity::binary-32, byte_size(bytes)::32, checksum(identity, bytes)::binary>>

    File.write(path(directory, slot), [header, bytes])
  end

  def size(bytes), do: @header_bytes + byte_size(bytes)

  def remove(directory, slot) do
    case File.rm(path(directory, slot)) do
      {:error, :enoent} -> :ok
      result -> result
    end
  end

  defp path(directory, slot),
    do: Path.join(directory, String.pad_leading(Integer.to_string(slot), 5, "0") <> ".tile")

  defp checksum(identity, bytes),
    do: :crypto.hash(:sha256, [identity, <<byte_size(bytes)::32>>, bytes])

  defp read_bounded(path, maximum) do
    with {:ok, %{type: :regular, size: size}} when size <= maximum <- File.lstat(path),
         {:ok, data} when byte_size(data) == size <- read_prefix(path, maximum + 1) do
      {:ok, data}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_cache_file}
    end
  end

  defp read_prefix(path, count) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        try do
          case IO.binread(file, count) do
            bytes when is_binary(bytes) -> {:ok, bytes}
            _ -> {:error, :invalid_cache_file}
          end
        after
          File.close(file)
        end

      error ->
        error
    end
  end
end
