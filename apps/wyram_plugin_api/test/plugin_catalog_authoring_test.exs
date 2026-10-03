defmodule Wyram.Plugin.CatalogAuthoringTest do
  use ExUnit.Case, async: false

  alias Wyram.Block.Ref
  alias Wyram.Plugin.Compiler

  defmodule Project do
    def project, do: Process.get(:catalog_test_project)
  end

  test "Mix owns catalog and composition metadata and symbols supply default IDs" do
    source = """
    defmodule Forest do
      use Wyram.Plugin
      catalog GroundFamily
      catalog Forest.ProfileFamily
      catalog Forest.ModelFamily
      catalog Forest.CharacterFamily
      game Forest.Startup
    end
    defmodule GroundFamily do
      use Wyram.Plugin.Catalog, kind: :block
      defblock Moss
      defblock HTTPStone
      defblock OldName, id: "stable_name"
      defblock Solid, template: true
    end
    defmodule Forest.ProfileFamily do
      use Wyram.Plugin.Catalog, kind: :profile
      defprofile Walker
    end
    defmodule Forest.ModelFamily do
      use Wyram.Plugin.Catalog, kind: :model
      defmodel Rig, build: {Forest.RigFactory, :build}
    end
    defmodule Forest.RigFactory do
      def build(id), do: %{Wyram.Character.Model.fallback() | id: id}
    end
    defmodule Forest.CharacterFamily do
      use Wyram.Plugin.Catalog, kind: :character
      defcharacter Hero do
        %{profile: Forest.Profiles.Walker, model: Forest.Models.Rig}
      end
    end
    defmodule Forest.Startup do
      use Wyram.Game
      palette surface: Forest.Blocks.Moss, soil: Forest.Blocks.Moss, rock: Forest.Blocks.Moss
      player Forest.Characters.Hero
    end
    """

    artifact = compile_plugin!(source)

    assert Enum.map(artifact.catalog.blocks, & &1.id) == [
             "forest:http_stone",
             "forest:moss",
             "forest:stable_name"
           ]

    assert Enum.any?(artifact.catalog.content, &(&1.id == "forest:walker"))
    assert invoke(GroundFamily, :__wyram_catalog__, []).plugin == Forest
    assert artifact.catalog.game.palette.surface == Ref.new!("forest", "moss")
  end

  test "worldgen composition does not repeat a biome palette" do
    artifact = compile_plugin!(content_source())
    assert is_nil(artifact.catalog.game.palette)
    assert hd(artifact.catalog.game.worldgen.biomes).surface == Ref.new!("forest", "moss")
  end

  test "catalog and game ownership comes only from the configured application entry" do
    for source <- [
          "defmodule Forest.Catalog do\nuse Wyram.Plugin.Catalog, kind: :block, plugin: Forest\nend",
          "defmodule Forest.Startup do\nuse Wyram.Game, plugin: Forest\nend",
          "defmodule OtherEntry do\nuse Wyram.Plugin\nend"
        ] do
      assert_raise CompileError, fn -> compile_plugin(source) end
    end

    assert_raise CompileError, ~r/declare the plugin entry/, fn ->
      compile_plugin("defmodule Forest.Catalog do\nuse Wyram.Plugin.Catalog, kind: :block\nend",
        entry: nil
      )
    end
  end

  test "unregistered catalogs are not discovered through their namespace or files" do
    source = String.replace(content_source(), "  catalog Forest.Profiles\n", "")
    assert {:error, diagnostics} = compile_plugin(source)
    assert Enum.any?(diagnostics, &(&1.code == :unresolved_content_reference))
  end

  test "game generation and spawn options reject duplicated configuration" do
    both =
      String.replace(content_source(), "  worldgen Forest.WorldGen.Wilderness", """
        palette surface: Forest.Blocks.Moss, soil: Forest.Blocks.Moss, rock: Forest.Blocks.Moss
        worldgen Forest.WorldGen.Wilderness
      """)

    assert {:error, diagnostics} = compile_plugin(both)
    assert Enum.any?(diagnostics, &(&1.code == :invalid_game_config))

    source =
      String.replace(content_source(), "  spawn_policy :surface", """
        spawn Forest.Characters.Hero, id: "guest", id: "second_guest"
        spawn_policy :surface
      """)

    assert {:error, diagnostics} = compile_plugin(source)
    assert Enum.any?(diagnostics, &(&1.code == :invalid_game_config))
  end

  test "application identity and explicit family catalogs work with a developer namespace" do
    artifact =
      compile_plugin!("""
      defmodule Forest do
        use Wyram.Plugin
        catalog Forest.Blocks
      end
      defmodule Forest.Blocks do
        use Wyram.Plugin.Catalog, kind: :block
        include Forest.Blocks.Ground
      end
      defmodule Forest.Blocks.Ground do
        use Wyram.Plugin.Catalog, kind: :block
        defblock Moss, id: "moss" do
          capability %Wyram.Capability.Material{color: {75, 120, 60}}
        end
      end
      """)

    assert artifact.plugin.id == "forest"
    assert artifact.catalog.blocks |> hd() |> Map.fetch!(:id) == "forest:moss"
    assert invoke(Forest.Blocks.Moss, :ref, []) == Ref.new!("forest", "moss")
    assert "Elixir.Forest.Blocks.Ground" in artifact.plugin.owned_modules
  end

  test "catalog linking rejects cycles, repeated inclusion, wrong kinds, and foreign ownership" do
    for {body, family_kind, owner, expected} <- [
          {"include Forest.Blocks", :block, "Forest", :catalog_cycle},
          {"include Forest.Family\ninclude Forest.Family", :block, "Forest", :duplicate_catalog},
          {"include Forest.Family", :profile, "Forest", :catalog_kind_mismatch},
          {"include Forest.Family", :block, "Foreign", :catalog_ownership_mismatch}
        ] do
      source = """
      defmodule Forest do
        use Wyram.Plugin
        catalog Forest.Blocks
      end
      defmodule Forest.Blocks do
        use Wyram.Plugin.Catalog, kind: :block
        #{body}
      end
      defmodule Forest.Family do
        use Wyram.Plugin.Catalog, kind: #{inspect(family_kind)}
      end
      """

      source =
        if owner == "Foreign" do
          String.replace(source, "use Wyram.Plugin.Catalog, kind: :block\nend", """
          def __wyram_catalog__, do: %{plugin: Foreign, kind: :block, includes: [], declarations: []}
          def __wyram_declarations__, do: []
          end
          """)
        else
          source
        end

      assert {:error, diagnostics} = compile_plugin(source)
      assert Enum.any?(diagnostics, &(&1.code == expected))
    end
  end

  test "catalog kind and entry metadata mistakes fail module compilation" do
    for source <- [
          "defmodule Forest do\nuse Wyram.Plugin, id: \"forest\"\nend",
          "defmodule Forest.Catalog do\nuse Wyram.Plugin.Catalog, kind: :typo\nend",
          "defmodule Forest.Catalog do\nuse Wyram.Plugin.Catalog, kind: :profile\nrequire Wyram.Plugin.Declarations\nWyram.Plugin.Declarations.defblock Moss, id: \"moss\"\nend"
        ] do
      assert_raise CompileError, fn -> compile_plugin(source) end
    end
  end

  test "all existing content kinds link to a declarative game composition" do
    artifact = compile_plugin!(content_source())

    assert Enum.sort(Enum.map(artifact.catalog.content, & &1.kind)) ==
             [:biome, :character, :model, :profile, :shaping, :worldgen]

    game = artifact.catalog.game
    assert game.profile.fly_enabled
    assert game.spawn == :surface
    assert is_nil(game.palette)
    assert hd(game.worldgen.biomes).id == "forest:woodland"
    assert hd(game.models).id == "forest:dwarf"
    assert hd(game.characters).model == "forest:dwarf"
    assert hd(game.characters).id == "player"
  end

  test "content references reject missing declarations and wrong reference kinds" do
    for {replacement, expected} <- [
          {"Forest.Models.Missing", :unresolved_content_reference},
          {"Forest.Profiles.Walker", :content_reference_kind_mismatch}
        ] do
      source =
        String.replace(content_source(), "model: Forest.Models.Dwarf", "model: #{replacement}")

      assert {:error, diagnostics} = compile_plugin(source)
      assert Enum.any?(diagnostics, &(&1.code == expected))
    end
  end

  test "invalid unselected content is rejected and configuration expressions do not execute" do
    source =
      String.replace(content_source(), "fly_enabled: true", "fly_enabled: true, radius: -1")

    assert {:error, diagnostics} = compile_plugin(source)
    assert Enum.any?(diagnostics, &(&1.code == :invalid_content_configuration))

    source =
      String.replace(
        content_source(),
        "fly_enabled: true",
        "fly_enabled: send(self(), :executed)"
      )

    assert_raise CompileError, fn -> compile_plugin(source) end
    refute_received :executed
  end

  test "unit helpers are literal computations and model builders receive canonical identity" do
    source =
      content_source()
      |> String.replace(
        "%{fly_enabled: true}",
        "%{fly_enabled: true, radius: Wyram.Units.pixels(3)}"
      )
      |> String.replace(
        ~r/defmodel Dwarf, id: "dwarf" do.*?\n      end/s,
        "defmodel Dwarf, id: \"dwarf\", build: {Forest.RigBuilder, :build}"
      )

    source =
      source <>
        """
        defmodule Forest.RigBuilder do
          def build(id), do: %{Wyram.Character.Model.fallback() | id: id}
        end
        """

    artifact = compile_plugin!(source)
    assert artifact.catalog.game.profile.radius == 0.375
    assert hd(artifact.catalog.game.models).id == "forest:dwarf"
  end

  test "content symbol collisions are rejected" do
    source =
      String.replace(
        content_source(),
        "defprofile Walker, id: \"walker\" do",
        "defprofile Walker, id: \"another\"\n      defprofile Walker, id: \"walker\" do"
      )

    assert {:error, diagnostics} = compile_plugin(source)
    assert Enum.any?(diagnostics, &(&1.code == :duplicate_content_module))
  end

  test "missing generated content modules are rejected" do
    assert {:error, diagnostics} =
             compile_plugin(content_source(), missing_module: Forest.Profiles.Walker)

    assert Enum.any?(diagnostics, &(&1.code == :module_ownership_mismatch))
  end

  test "unknown nested model fields are rejected even for unselected models" do
    source =
      String.replace(content_source(), "defmodel Dwarf, id: \"dwarf\" do", """
      defmodel Unused, id: "unused" do
        %{bones: [%{name: "root", parent: nil, role: "root", pivot: [0.0, 0.0, 0.0], misspelled: true,
          boxes: [%{center: [0.0, 0.9, 0.0], size: [0.5, 1.8, 0.3], color: [180, 160, 120]}]}]}
      end
      defmodel Dwarf, id: "dwarf" do
      """)

    assert {:error, diagnostics} = compile_plugin(source)
    assert Enum.any?(diagnostics, &(&1.code == :invalid_content_configuration))
  end

  test "dependency content links across packages while transitive imports require a direct dependency" do
    base =
      compile_plugin!(String.replace(content_source(), "Forest", "CatalogBase"),
        app: :base,
        entry: CatalogBase
      )

    middle_source = """
    defmodule Middle do
      use Wyram.Plugin
      catalog Middle.Characters
    end
    defmodule Middle.Characters do
      use Wyram.Plugin.Catalog, kind: :character
      defcharacter Hero, id: "hero" do
        %{profile: CatalogBase.Profiles.Walker, model: CatalogBase.Models.Dwarf}
      end
    end
    """

    middle =
      compile_plugin!(middle_source,
        app: :middle,
        entry: Middle,
        dependencies: %{"base" => dependency(base)}
      )

    assert middle.plugin.dependencies == ["base"]

    addon_source = """
    defmodule Addon do
      use Wyram.Plugin
      catalog Addon.Blocks
      game Addon.Game
    end
    defmodule Addon.Blocks do
      use Wyram.Plugin.Catalog, kind: :block
      defblock Ground, id: "ground"
    end
    defmodule Addon.Game do
      use Wyram.Game
      palette surface: Addon.Blocks.Ground, soil: Addon.Blocks.Ground, rock: Addon.Blocks.Ground
      player Middle.Characters.Hero
    end
    """

    addon =
      compile_plugin!(addon_source,
        app: :addon,
        entry: Addon,
        dependencies: %{"middle" => dependency(middle)}
      )

    assert hd(addon.catalog.game.models).id == "base:dwarf"

    source =
      String.replace(
        addon_source,
        "player Middle.Characters.Hero",
        "player CatalogBase.Characters.Hero"
      )

    assert {:error, diagnostics} =
             compile_plugin(source,
               app: :addon,
               entry: Addon,
               dependencies: %{"middle" => dependency(middle)}
             )

    assert Enum.any?(diagnostics, &(&1.code == :undeclared_content_dependency))
  end

  defp dependency(artifact),
    do: %{interface: artifact.interface, interface_fingerprint: artifact.interface_fingerprint}

  defp invoke(module, function, args), do: apply(module, function, args)

  defp content_source do
    """
    defmodule Forest do
      use Wyram.Plugin
      catalog Forest.Blocks
      catalog Forest.Profiles
      catalog Forest.Models
      catalog Forest.Characters
      catalog Forest.Biomes
      catalog Forest.Shaping
      catalog Forest.WorldGen
      game Forest.Game
    end
    defmodule Forest.Blocks do
      use Wyram.Plugin.Catalog, kind: :block
      defblock Moss, id: "moss"
    end
    defmodule Forest.Profiles do
      use Wyram.Plugin.Catalog, kind: :profile
      defprofile Walker, id: "walker" do
        %{fly_enabled: true}
      end
    end
    defmodule Forest.Models do
      use Wyram.Plugin.Catalog, kind: :model
      defmodel Dwarf, id: "dwarf" do
        %{bones: [%{name: "root", parent: nil, role: "root", pivot: [0.0, 0.0, 0.0],
          boxes: [%{center: [0.0, 0.9, 0.0], size: [0.5, 1.8, 0.3], color: [180, 160, 120]}]}]}
      end
    end
    defmodule Forest.Characters do
      use Wyram.Plugin.Catalog, kind: :character
      defcharacter Hero, id: "hero" do
        %{profile: Forest.Profiles.Walker, model: Forest.Models.Dwarf}
      end
    end
    defmodule Forest.Biomes do
      use Wyram.Plugin.Catalog, kind: :biome
      defbiome Woodland, id: "woodland" do
        %{surface: Forest.Blocks.Moss, soil: Forest.Blocks.Moss, rock: Forest.Blocks.Moss}
      end
    end
    defmodule Forest.WorldGen do
      use Wyram.Plugin.Catalog, kind: :worldgen
      defworldgen Wilderness, id: "wilderness" do
        %{shaping: Forest.Shaping.Default, biomes: [Forest.Biomes.Woodland]}
      end
    end
    defmodule Forest.Shaping do
      use Wyram.Plugin.Catalog, kind: :shaping
      defshaping Default, id: "default"
    end
    defmodule Forest.Game do
      use Wyram.Game
      worldgen Forest.WorldGen.Wilderness
      player Forest.Characters.Hero
      spawn_policy :surface
    end
    """
  end

  defp compile_plugin!(source, options \\ []) do
    assert {:ok, artifact} = compile_plugin(source, options)
    artifact
  end

  defp compile_plugin(source, options \\ []) do
    directory =
      Path.join(System.tmp_dir!(), "wyram-catalog-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)

    Process.put(:catalog_test_project,
      app: Keyword.get(options, :app, :forest),
      version: "0.1.0",
      wyram_plugin: Keyword.get(options, :entry, Forest),
      deps: []
    )

    Mix.Project.push(Project)
    previous = Code.compiler_options(ignore_module_conflict: true)

    try do
      modules = Code.compile_string(source, "forest_catalog.ex")

      Enum.each(modules, fn {module, bytes} ->
        unless module == Keyword.get(options, :missing_module) do
          File.write!(Path.join(directory, Atom.to_string(module) <> ".beam"), bytes)
        end
      end)

      Compiler.compile_entry(Keyword.get(options, :entry, Forest),
        catalog_path: Path.join(directory, "catalog.term"),
        compile_path: directory,
        dependencies: Keyword.get(options, :dependencies, %{})
      )
    after
      Code.compiler_options(previous)
      Mix.Project.pop()
      Process.delete(:catalog_test_project)
      File.rm_rf!(directory)
    end
  end
end
