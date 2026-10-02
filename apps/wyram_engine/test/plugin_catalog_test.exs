defmodule Wyram.Engine.PluginCatalogTest do
  use ExUnit.Case, async: true

  alias Wyram.Block.Ref
  alias Wyram.Engine.PluginCatalog
  alias Wyram.Game.Config
  alias Wyram.Plugin.{Declaration, SourceLocation}

  test "builds current block and color tables from compiled descriptors" do
    package =
      package(
        "test_game",
        [block("test_game", "grass", {12, 34, 56})],
        [],
        game_config("test_game")
      )

    assert {:ok, registry} = PluginCatalog.build([package])
    assert registry.blocks == %{"test_game:grass" => 1}
    assert registry.colors == %{1 => [12, 34, 56]}
    assert registry.palette == [1, 1, 1]
    assert registry.player_profile == Config.new!(%{terrain: terrain("test_game")}).profile
  end

  test "requires explicit game selection when multiple compiled game configs are installed" do
    one =
      package("game_one", [block("game_one", "grass", {1, 2, 3})], [], game_config("game_one"))

    two =
      package("game_two", [block("game_two", "grass", {4, 5, 6})], [], game_config("game_two"))

    assert {:error, :ambiguous_game_configuration} = PluginCatalog.build([one, two])
    assert {:ok, registry} = PluginCatalog.build([one, two], game: "game_two")
    assert registry.palette == [2, 2, 2]
  end

  test "checks missing, self, duplicate, and cyclic installed dependencies" do
    a =
      package("game_a", [block("game_a", "stone", {1, 2, 3})], ["game_b"], game_config("game_a"))

    b = package("game_b", [block("game_b", "stone", {1, 2, 3})], ["game_a"])

    assert {:error, :cyclic_plugin_dependencies} = PluginCatalog.build([a, b], game: "game_a")

    assert {:error, :missing_dependency} =
             PluginCatalog.build([package("game_a", [], ["absent"], game_config("game_a"))])

    assert {:error, :self_dependency} =
             PluginCatalog.build([package("game_a", [], ["game_a"], game_config("game_a"))])

    duplicate = package("game_a", [], [], game_config("game_a"))

    assert {:error, :duplicate_plugin_id} =
             PluginCatalog.build([package("game_a", [], [], game_config("game_a")), duplicate])

    assert {:error, :duplicate_dependency} =
             PluginCatalog.build([
               package("game_a", [], ["game_b", "game_b"], game_config("game_a")),
               package("game_b", [], [])
             ])
  end

  test "dependency order is dependency-first and shared owned modules are rejected" do
    base = package("base", [block("base", "grass", {8, 9, 10})], [], game_config("base"))
    addon = package("addon", [block("addon", "gem", {11, 12, 13})], ["base"])
    addon = with_owned_module(addon, hd(base.catalog.catalog.blocks).module)

    addon =
      put_in(addon.catalog.dependency_interfaces["base"], fingerprint(base.catalog.interface))

    assert {:error, :module_ownership_collision} =
             PluginCatalog.build([addon, base], game: "base")

    addon = package("addon", [block("addon", "gem", {11, 12, 13})], ["base"])

    addon =
      put_in(addon.catalog.dependency_interfaces["base"], fingerprint(base.catalog.interface))

    assert {:ok, registry} = PluginCatalog.build([addon, base], game: "base")
    assert registry.package_order == ["base", "addon"]
  end

  test "rejects stale dependency interface fingerprints" do
    dependency = package("base", [block("base", "stone", {8, 9, 10})], [], game_config("base"))
    addon = package("addon", [block("addon", "gem", {11, 12, 13})], ["base"])

    addon =
      put_in(
        addon.catalog.dependency_interfaces["base"],
        fingerprint(dependency.catalog.interface)
      )

    stale = put_in(addon.catalog.dependency_interfaces["base"], String.duplicate("0", 64))

    assert {:error, :stale_dependency_interface} =
             PluginCatalog.build([dependency, stale], game: "base")
  end

  test "validates artifact identity, module ownership, and backend descriptors" do
    valid = package("game", [block("game", "grass", {2, 3, 4})], [], game_config("game"))
    bad_magic = put_in(valid.catalog.magic, :other)
    assert {:error, :invalid_plugin_catalog} = PluginCatalog.build([bad_magic])

    bad_fingerprint = put_in(valid.catalog.interface_fingerprint, String.duplicate("0", 64))
    assert {:error, :stale_plugin_interface} = PluginCatalog.build([bad_fingerprint])

    bad_identity = put_in(valid.catalog.plugin.id, "other")
    assert {:error, :catalog_identity_mismatch} = PluginCatalog.build([bad_identity])

    bad_module =
      update_in(valid.catalog.catalog.blocks, fn [block | rest] ->
        [%{block | module: "Elixir.WyramMods.Other.Block"} | rest]
      end)

    bad_module =
      put_in(bad_module.catalog.interface.compiled_blocks, bad_module.catalog.catalog.blocks)

    bad_module = refresh_fingerprint(bad_module)

    assert {:error, :invalid_catalog_ownership} = PluginCatalog.build([bad_module])

    unsupported =
      update_in(valid.catalog.catalog.blocks, fn [block | rest] ->
        descriptor = put_in(block.descriptor.geometry.primitive, :slab)
        [%{block | descriptor: descriptor} | rest]
      end)

    unsupported =
      put_in(unsupported.catalog.interface.compiled_blocks, unsupported.catalog.catalog.blocks)

    unsupported = refresh_fingerprint(unsupported)

    assert {:error, :unsupported_block_descriptor} = PluginCatalog.build([unsupported])

    wrong_kind =
      update_in(valid.catalog.catalog.blocks, fn [block | rest] ->
        [%{block | kind: :item} | rest]
      end)

    wrong_kind =
      put_in(wrong_kind.catalog.interface.compiled_blocks, wrong_kind.catalog.catalog.blocks)

    wrong_kind = refresh_fingerprint(wrong_kind)

    assert {:error, :invalid_catalog_ownership} = PluginCatalog.build([wrong_kind])
  end

  test "requires the fingerprinted compiled blocks to match the catalog blocks" do
    valid = package("game", [block("game", "grass", {2, 3, 4})], [], game_config("game"))

    changed =
      update_in(valid.catalog.interface.compiled_blocks, fn [block | rest] ->
        [%{block | descriptor: put_in(block.descriptor.material.color, {9, 8, 7})} | rest]
      end)

    changed =
      put_in(changed.catalog.interface_fingerprint, fingerprint(changed.catalog.interface))

    assert {:error, :invalid_catalog_interface} = PluginCatalog.build([changed])
  end

  test "treats authored declaration data as opaque compiler output" do
    package = package("game", [block("game", "grass", {12, 34, 56})], [], game_config("game"))

    opaque_data =
      Base.decode64!(
        "g2gCdxlvcGFxdWVfY29tcGlsZV9kYXRhX2FscGhhdxhvcGFxdWVfY29tcGlsZV9kYXRhX2JldGE="
      )

    package = put_in(package.catalog.interface.compile_data, opaque_data)
    refute Map.has_key?(package.catalog.interface, :plugins)

    package =
      put_in(package.catalog.interface_fingerprint, fingerprint(package.catalog.interface))

    assert {:ok, registry} = PluginCatalog.build([package])
    assert registry.colors == %{1 => [12, 34, 56]}
  end

  test "requires declaration summaries to match each registered block identity" do
    valid = package("game", [block("game", "grass", {2, 3, 4})], [], game_config("game"))

    wrong_id =
      update_in(valid.catalog.interface.declarations, fn [declaration] ->
        [%{declaration | local_id: "another_block"}]
      end)
      |> refresh_fingerprint()

    assert {:error, :invalid_catalog_ownership} = PluginCatalog.build([wrong_id])

    wrong_role =
      update_in(valid.catalog.interface.declarations, fn [declaration] ->
        [%{declaration | role: :template}]
      end)
      |> refresh_fingerprint()

    assert {:error, :invalid_catalog_interface} = PluginCatalog.build([wrong_role])

    wrong_source =
      update_in(valid.catalog.interface.declarations, fn [declaration] ->
        [%{declaration | source: %SourceLocation{file: "", line: 0}}]
      end)
      |> refresh_fingerprint()

    assert {:error, :invalid_catalog_interface} = PluginCatalog.build([wrong_source])

    wrong_module =
      update_in(valid.catalog.interface.declarations, fn [declaration] ->
        [%{declaration | module: Module.concat([WyramMods, Game, Game])}]
      end)
      |> refresh_fingerprint()

    assert {:error, :invalid_catalog_ownership} = PluginCatalog.build([wrong_module])
  end

  test "requires one unique registered declaration per compiled block" do
    valid = package("game", [block("game", "grass", {2, 3, 4})], [], game_config("game"))
    other_module = Module.concat([WyramMods, Game, Game])
    assert Atom.to_string(other_module) in valid.catalog.interface.modules
    assert Map.has_key?(valid.catalog.interface.module_hashes, Atom.to_string(other_module))

    extra = %Declaration{
      plugin_id: "game",
      local_id: "orphan",
      module: other_module,
      kind: :block,
      role: :registered,
      source: %SourceLocation{file: "extra.ex", line: 2, column: 1},
      entries: []
    }

    extra_summary =
      update_in(valid.catalog.interface.declarations, &(&1 ++ [extra]))
      |> refresh_fingerprint()

    assert {:error, :invalid_catalog_ownership} = PluginCatalog.build([extra_summary])

    duplicate_id = %{extra | local_id: "grass"}

    duplicate_summary =
      update_in(valid.catalog.interface.declarations, &(&1 ++ [duplicate_id]))
      |> refresh_fingerprint()

    assert {:error, :invalid_catalog_ownership} = PluginCatalog.build([duplicate_summary])
  end

  test "requires compile data to be bounded uncompressed ETF bytes" do
    valid = package("game", [block("game", "grass", {2, 3, 4})], [], game_config("game"))

    for compile_data <- [nil, <<131, 80, 0>>, <<0, 1>>] do
      invalid =
        put_in(valid.catalog.interface.compile_data, compile_data) |> refresh_fingerprint()

      assert {:error, :invalid_catalog_interface} = PluginCatalog.build([invalid])
    end

    oversized =
      put_in(
        valid.catalog.interface.compile_data,
        :binary.copy(<<131, 106>>, 8 * 1024 * 1024 + 1)
      )
      |> refresh_fingerprint()

    assert {:error, :invalid_catalog_interface} = PluginCatalog.build([oversized])
  end

  test "rejects a changed compiled game that no longer matches its interface fingerprint" do
    valid = package("game", [block("game", "grass", {2, 3, 4})], [], game_config("game"))
    game_config = valid.catalog.catalog.game
    changed_game = put_in(game_config.profile.run_speed, 9.5)
    assert :ok = Config.validate(changed_game)
    changed = put_in(valid.catalog.catalog.game, changed_game)

    assert {:error, :invalid_catalog_interface} = PluginCatalog.build([changed])
  end

  test "game terrain references must resolve to registered block identities" do
    valid = package("game", [block("game", "grass", {1, 2, 3})], [], game_config("game"))
    missing_ref = Ref.new!("game", "missing")
    game = put_in(valid.catalog.catalog.game.terrain.surface, missing_ref)
    invalid_game = with_compiled_game(valid, game)
    assert {:error, :invalid_game_configuration} = PluginCatalog.build([invalid_game])
  end

  test "game terrain references require a direct declared plugin dependency" do
    game = package("game", [block("game", "grass", {1, 2, 3})], [], game_config("game"))
    addon = package("addon", [block("addon", "grass", {4, 5, 6})], [])
    ref = Ref.new!("addon", "grass")
    external_config = game.catalog.catalog.game
    external_config = put_in(external_config.terrain.surface, ref)
    external_config = put_in(external_config.terrain.soil, ref)
    external_config = put_in(external_config.terrain.rock, ref)
    external = with_compiled_game(game, external_config)

    assert {:error, :invalid_game_configuration} =
             PluginCatalog.build([external, addon], game: "game")
  end

  test "all installed game configurations are validated and stale saved names are rejected" do
    selected =
      package("selected", [block("selected", "grass", {1, 2, 3})], [], game_config("selected"))

    invalid_other =
      package("other", [block("other", "grass", {4, 5, 6})], [], game_config("other"))

    missing = Ref.new!("missing", "grass")
    invalid_config = invalid_other.catalog.catalog.game
    invalid_config = put_in(invalid_config.terrain.surface, missing)
    invalid_config = put_in(invalid_config.terrain.soil, missing)
    invalid_config = put_in(invalid_config.terrain.rock, missing)
    invalid_other = with_compiled_game(invalid_other, invalid_config)

    assert {:error, :invalid_game_configuration} =
             PluginCatalog.build([selected, invalid_other], game: "selected")

    assert {:error, :invalid_saved_block_ids} =
             PluginCatalog.build([selected],
               game: "selected",
               saved_block_ids: %{"stale:grass" => 9}
             )
  end

  test "preserves valid saved IDs and rejects malformed or exhausted mappings" do
    package =
      package(
        "game",
        [
          block("game", "dirt", {1, 1, 1}),
          block("game", "grass", {2, 2, 2}),
          block("game", "stone", {3, 3, 3})
        ],
        [],
        game_config("game")
      )

    assert {:ok, registry} =
             PluginCatalog.build([package], saved_block_ids: %{"game:stone" => 17})

    assert registry.blocks == %{"game:dirt" => 18, "game:grass" => 19, "game:stone" => 17}

    assert {:error, :invalid_saved_block_ids} =
             PluginCatalog.build([package],
               saved_block_ids: %{"game:dirt" => 1, "game:stone" => 1}
             )

    assert {:error, :invalid_saved_block_ids} =
             PluginCatalog.build([package], saved_block_ids: %{"game:dirt" => 0})

    assert {:error, :block_id_capacity_exceeded} =
             PluginCatalog.build([package], saved_block_ids: %{"game:stone" => 65_535})
  end

  test "binds the fingerprinted interface entry to the package entry" do
    valid =
      package(
        "entry_test",
        [block("entry_test", "grass", {1, 2, 3})],
        [],
        game_config("entry_test")
      )

    changed =
      valid
      |> put_in([:catalog, :interface, :entry], "Elixir.WyramMods.Other")
      |> refresh_fingerprint()

    assert {:error, :catalog_identity_mismatch} = PluginCatalog.build([changed])
  end

  defp package(id, blocks, dependencies, game_config \\ nil) do
    entry = "Elixir.WyramMods.#{Macro.camelize(id)}"
    block_modules = Enum.map(blocks, & &1.module)
    game_provider = if game_config, do: entry <> ".Game", else: nil

    modules =
      Enum.sort(
        Enum.uniq([entry | block_modules] ++ if(game_provider, do: [game_provider], else: []))
      )

    interface = %{
      id: id,
      entry: entry,
      dependencies: dependencies,
      compile_data:
        Base.decode64!(
          "g2gCdxlvcGFxdWVfY29tcGlsZV9kYXRhX2FscGhhdxhvcGFxdWVfY29tcGlsZV9kYXRhX2JldGE="
        ),
      declarations:
        Enum.map(blocks, fn block ->
          %Declaration{
            plugin_id: id,
            local_id: block.local_id,
            module: String.to_atom(block.module),
            kind: :block,
            role: :registered,
            source: %SourceLocation{file: block.source.file, line: block.source.line},
            entries: []
          }
        end),
      providers: if(game_provider, do: [game_provider], else: []),
      modules: modules,
      game: game_provider,
      compiled_game: game_config,
      compiled_blocks: blocks,
      module_hashes: Map.new(modules, &{&1, String.duplicate("a", 64)})
    }

    artifact = %{
      magic: :wyram_plugin_catalog,
      plugin: %{
        id: id,
        entry: entry,
        dependencies: dependencies,
        owned_modules: modules,
        provider_modules: if(game_provider, do: [game_provider], else: []),
        game: game_provider
      },
      catalog: %{id: id, dependencies: dependencies, blocks: blocks, game: game_config},
      interface: interface,
      interface_fingerprint: fingerprint(interface),
      dependency_interfaces: %{}
    }

    manifest = %{
      "id" => id,
      "version" => "0.1.0",
      "otp" => System.otp_release(),
      "elixir" => "1.20",
      "entry" => entry,
      "modules" => modules,
      "dependencies" => dependencies,
      "catalog" => "catalog.term",
      "catalog_sha256" => String.duplicate("b", 64)
    }

    %{path: id <> ".wyrplug", manifest: manifest, catalog: artifact}
  end

  defp block(plugin_id, local_id, color) do
    module = "Elixir.WyramMods.#{Macro.camelize(plugin_id)}.Blocks.#{Macro.camelize(local_id)}"

    %{
      id: plugin_id <> ":" <> local_id,
      plugin_id: plugin_id,
      local_id: local_id,
      module: module,
      kind: :block,
      descriptor: %{
        geometry: %{primitive: :cube},
        collision: %{primitive: :cube},
        material: %{color: color, mode: :opaque}
      },
      source: %{file: "blocks.ex", line: 2, column: 1, module: nil}
    }
  end

  defp game_config(plugin_id) do
    Config.new!(%{
      terrain: terrain(plugin_id)
    })
  end

  defp fingerprint(interface) do
    interface
    |> then(&:erlang.term_to_binary(&1, [:deterministic]))
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp refresh_fingerprint(package),
    do: put_in(package.catalog.interface_fingerprint, fingerprint(package.catalog.interface))

  defp with_compiled_game(package, game_config) do
    package
    |> put_in([:catalog, :catalog, :game], game_config)
    |> put_in([:catalog, :interface, :compiled_game], game_config)
    |> refresh_fingerprint()
  end

  defp with_owned_module(package, module) do
    modules = Enum.sort([module | package.manifest["modules"]])
    package = put_in(package.manifest["modules"], modules)
    package = put_in(package.catalog.plugin.owned_modules, modules)
    package = put_in(package.catalog.interface.modules, modules)
    package = put_in(package.catalog.interface.module_hashes[module], String.duplicate("c", 64))
    put_in(package.catalog.interface_fingerprint, fingerprint(package.catalog.interface))
  end

  defp terrain(plugin_id) do
    %{
      surface: Ref.new!(plugin_id, "grass"),
      soil: Ref.new!(plugin_id, "grass"),
      rock: Ref.new!(plugin_id, "grass")
    }
  end
end
