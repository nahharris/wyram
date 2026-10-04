defmodule Wyram.Engine.Native do
  @moduledoc "Packed voxel operations implemented in Rust."
  # Shared core changes must rebuild the NIF, even when its wrapper is unchanged.
  for path <-
        Path.wildcard(Path.expand("../../../../../native/crates/wyram_core/src/**/*.rs", __DIR__)) do
    @external_resource path
  end

  use Rustler, otp_app: :wyram_engine, crate: :wyram_nif

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
