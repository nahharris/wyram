defmodule Wyram.Engine.LodCacheTest do
  use ExUnit.Case, async: true

  alias Wyram.Engine.LodCache

  test "cache keys include tile revision and every retained byte is accounted" do
    tile = {2, 0, 0, 0}
    cache = LodCache.new(8)
    {cache, :ok} = LodCache.put(cache, {tile, 1}, <<1, 2, 3>>)
    {cache, :ok} = LodCache.put(cache, {tile, 2}, <<4, 5>>)

    assert cache.bytes == 5
    assert {cache, {:ok, <<1, 2, 3>>}} = LodCache.get(cache, {tile, 1})
    assert {_cache, {:ok, <<4, 5>>}} = LodCache.get(cache, {tile, 2})
    assert {_cache, :miss} = LodCache.get(cache, {{2, 1, 0, 0}, 1})
  end

  test "least recently used entry is evicted to satisfy the byte limit" do
    cache = LodCache.new(5)
    {cache, :ok} = LodCache.put(cache, {{2, 0, 0, 0}, 1}, <<1, 2>>)
    {cache, :ok} = LodCache.put(cache, {{2, 1, 0, 0}, 1}, <<3, 4>>)
    {cache, {:ok, <<1, 2>>}} = LodCache.get(cache, {{2, 0, 0, 0}, 1})
    {cache, :ok} = LodCache.put(cache, {{2, 2, 0, 0}, 1}, <<5, 6, 7>>)

    assert cache.bytes == 5
    assert {_cache, {:ok, <<1, 2>>}} = LodCache.get(cache, {{2, 0, 0, 0}, 1})
    assert {_cache, :miss} = LodCache.get(cache, {{2, 1, 0, 0}, 1})
    assert {_cache, {:ok, <<5, 6, 7>>}} = LodCache.get(cache, {{2, 2, 0, 0}, 1})
  end

  test "oversized insert leaves an existing cache unchanged" do
    cache = LodCache.new(4)
    {cache, :ok} = LodCache.put(cache, {{2, 0, 0, 0}, 1}, <<1, 2>>)
    before = cache

    assert {^before, {:error, :oversized}} =
             LodCache.put(cache, {{2, 1, 0, 0}, 1}, <<3, 4, 5, 6, 7>>)

    assert cache.bytes == 2
    assert {_cache, {:ok, <<1, 2>>}} = LodCache.get(cache, {{2, 0, 0, 0}, 1})
  end

  test "replacement accounts both revisions and invalidation clears every tile revision" do
    first = {2, -1, 0, 0}
    second = {4, 0, 0, 0}
    cache = LodCache.new(16)
    {cache, :ok} = LodCache.put(cache, {first, 1}, <<1, 2, 3>>)
    {cache, :ok} = LodCache.put(cache, {first, 2}, <<4>>)
    {cache, :ok} = LodCache.put(cache, {second, 1}, <<5, 6>>)
    {cache, :ok} = LodCache.put(cache, {first, 1}, <<7>>)

    assert cache.bytes == 4
    invalidated = LodCache.invalidate(cache, [first])
    assert invalidated.bytes == 2
    assert {_cache, :miss} = LodCache.get(invalidated, {first, 1})
    assert {_cache, :miss} = LodCache.get(invalidated, {first, 2})
    assert {_cache, {:ok, <<5, 6>>}} = LodCache.get(invalidated, {second, 1})
  end

  test "empty tiles are cacheable and default capacity is 256 MiB" do
    cache = LodCache.new()
    {cache, :ok} = LodCache.put(cache, {{2, 0, 0, 0}, 0}, <<>>)

    assert cache.limit == 256 * 1024 * 1024
    assert cache.bytes == 0
    assert {_cache, {:ok, <<>>}} = LodCache.get(cache, {{2, 0, 0, 0}, 0})
    assert_raise ArgumentError, fn -> LodCache.new(-1) end
  end
end
