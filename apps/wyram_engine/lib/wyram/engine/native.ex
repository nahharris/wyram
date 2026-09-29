defmodule Wyram.Engine.Native do
  @moduledoc "Packed voxel operations implemented in Rust."
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
end
