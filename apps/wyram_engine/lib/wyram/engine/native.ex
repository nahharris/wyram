defmodule Wyram.Engine.Native do
  @moduledoc "Packed voxel operations implemented in Rust."
  # Shared core changes must rebuild the NIF, even when its wrapper is unchanged.
  for path <-
        Path.wildcard(Path.expand("../../../../../native/crates/wyram_core/src/**/*.rs", __DIR__)) do
    @external_resource path
  end

  use Rustler, otp_app: :wyram_engine, crate: :wyram_nif, lib: false

  @on_load :load_native
  def load_native do
    :code.purge(__MODULE__)
    path = Application.app_dir(:wyram_engine, "priv/native/#{native_library()}")

    case :erlang.load_nif(String.to_charlist(path), 0) do
      :ok ->
        extension = if match?({:win32, _}, :os.type()), do: ".dll", else: ".so"
        :persistent_term.put({__MODULE__, :library_path}, path <> extension)
        :ok

      error ->
        error
    end
  end

  @doc "Path of the native library successfully loaded in this VM."
  def library_path, do: :persistent_term.get({__MODULE__, :library_path})

  defp native_library do
    case {Application.get_env(:wyram_engine, :native_development_selection, false),
          System.get_env("WYRAM_NATIVE_PROFILE")} do
      {true, profile} when profile in ["dev", "perf"] ->
        hash = System.fetch_env!("WYRAM_NATIVE_BUILD_HASH")
        library = "wyram_nif_#{profile}_#{hash}"

        unless Regex.match?(~r/\A[0-9a-f]{64}\z/, hash) and
                 System.get_env("WYRAM_NATIVE_LIBRARY") == library do
          raise ArgumentError, "invalid native build identity"
        end

        library

      {true, nil} ->
        "wyram_nif"

      {false, _} ->
        "wyram_nif"

      _ ->
        raise ArgumentError, "invalid native development profile"
    end
  end

  @doc "Compiled profile and optimization level of the loaded native library."
  def build_info, do: :erlang.nif_error(:nif_not_loaded)

  def scenery_cache_version, do: :erlang.nif_error(:nif_not_loaded)
  def validate_visual_tiles(_tiles), do: :erlang.nif_error(:nif_not_loaded)

  @spec generate_chunk(
          non_neg_integer(),
          integer(),
          integer(),
          integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: binary()
  def generate_chunk(_seed, _cx, _cy, _cz, _surface, _soil, _rock),
    do: :erlang.nif_error(:nif_not_loaded)

  @spec read_block(binary(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, String.t()}
  def read_block(_data, _x, _y, _z), do: :erlang.nif_error(:nif_not_loaded)

  @spec write_block(
          binary(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          {:ok, binary()} | {:error, String.t()}
  def write_block(_data, _x, _y, _z, _id), do: :erlang.nif_error(:nif_not_loaded)

  def compile_generator(_seed, _settings), do: :erlang.nif_error(:nif_not_loaded)
  def generate_world_chunks(_resource, _keys), do: :erlang.nif_error(:nif_not_loaded)
  def generate_scenic_tiles(_resource, _keys), do: :erlang.nif_error(:nif_not_loaded)
  def scenic_sample_chunks(_resource, _key), do: :erlang.nif_error(:nif_not_loaded)
  def extract_scenic_samples(_resource, _key, _chunks), do: :erlang.nif_error(:nif_not_loaded)
  def generate_edited_scenic_tiles(_resource, _tiles), do: :erlang.nif_error(:nif_not_loaded)
  def sample_world(_resource, _positions), do: :erlang.nif_error(:nif_not_loaded)
  def generator_spawn(_resource), do: :erlang.nif_error(:nif_not_loaded)
  def surface_heights(_resource, _positions), do: :erlang.nif_error(:nif_not_loaded)

  @spec import_visual_chunks([{{integer(), integer(), integer()}, binary()}]) ::
          {:ok, [binary()]} | {:error, String.t()}
  def import_visual_chunks(_chunks), do: :erlang.nif_error(:nif_not_loaded)

  @spec reduce_visual_tiles([[binary()]]) :: {:ok, [binary()]} | {:error, String.t()}
  def reduce_visual_tiles(_batches), do: :erlang.nif_error(:nif_not_loaded)

  def read_blocks(_data, _positions), do: :erlang.nif_error(:nif_not_loaded)
  def compare_write_blocks(_data, _edits), do: :erlang.nif_error(:nif_not_loaded)
  def liquid_positions(_data, _ids), do: :erlang.nif_error(:nif_not_loaded)

  @spec sweep_bodies([{{integer(), integer(), integer()}, binary()}], [
          Wyram.Character.State.query()
        ]) ::
          {:ok, [Wyram.Character.State.result()]} | {:error, String.t()}
  def sweep_bodies(chunks, queries), do: sweep_bodies(chunks, queries, [])
  def sweep_bodies(_chunks, _queries, _noncolliding), do: :erlang.nif_error(:nif_not_loaded)
  @spec watch_process(non_neg_integer()) :: {:ok, reference()} | {:error, String.t()}
  def watch_process(_pid), do: :erlang.nif_error(:nif_not_loaded)
  @spec process_status(reference()) :: {:ok, nil | non_neg_integer()} | {:error, String.t()}
  def process_status(_watch), do: :erlang.nif_error(:nif_not_loaded)
end
