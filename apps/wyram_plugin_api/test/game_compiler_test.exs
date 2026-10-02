defmodule Wyram.Plugin.GameCompilerTest do
  use ExUnit.Case, async: true

  alias Wyram.Block.Ref
  alias Wyram.Game.Config
  alias Wyram.Plugin.GameCompiler

  defmodule Game do
    @behaviour Wyram.Game.Provider
    @impl true
    def build,
      do:
        Config.new!(%{
          terrain: Map.new([:surface, :soil, :rock], &{&1, Ref.new!("game", "stone")})
        })
  end

  defmodule InvalidGame do
    def build, do: %{terrain: :invalid}
  end

  defmodule CrashingGame do
    def build, do: raise("bad game setup")
  end

  defmodule DependencyGame do
    def build,
      do:
        Config.new!(%{
          terrain: Map.new([:surface, :soil, :rock], &{&1, Ref.new!("base", "stone")})
        })
  end

  defp metadata(game, dependencies \\ []) do
    %{id: "game", entry: __MODULE__, game: game, dependencies: dependencies, modules: [game]}
  end

  defp catalog(id \\ "game"),
    do: %{blocks: [%{id: id <> ":stone", plugin_id: id, local_id: "stone", kind: :block}]}

  test "compiles explicit game builder output and allows content-only plugins" do
    assert {:ok, %Config{}} = GameCompiler.compile(metadata(Game), catalog(), %{})
    assert {:ok, nil} = GameCompiler.compile(metadata(nil), catalog(), %{})
  end

  test "missing terrain references and invalid game builders fail with diagnostics" do
    assert {:error, [%{code: :unresolved_game_reference}]} =
             GameCompiler.compile(metadata(Game), %{blocks: []}, %{})

    for game <- [InvalidGame, CrashingGame, __MODULE__] do
      assert {:error, [%{code: :invalid_game_config}]} =
               GameCompiler.compile(metadata(game), catalog(), %{})
    end
  end

  test "game terrain may reference only registered blocks in an explicit dependency" do
    interface = %{
      declarations: [%{plugin_id: "base", local_id: "stone", kind: :block, role: :registered}]
    }

    dependencies = %{"base" => %{plugin: interface}}

    assert {:ok, %Config{}} =
             GameCompiler.compile(metadata(DependencyGame, ["base"]), catalog(), dependencies)

    assert {:error, [%{code: :unresolved_game_reference}]} =
             GameCompiler.compile(metadata(DependencyGame), catalog(), dependencies)

    template =
      put_in(interface.declarations, [
        %{plugin_id: "base", local_id: nil, kind: :block, role: :template}
      ])

    assert {:error, [%{code: :unresolved_game_reference}]} =
             GameCompiler.compile(metadata(DependencyGame, ["base"]), catalog(), %{
               "base" => %{plugin: template}
             })
  end

  test "accepts discovered compiled dependency interfaces" do
    interface = %{
      declarations: [%{plugin_id: "base", local_id: "stone", kind: :block, role: :registered}]
    }

    dependencies = %{"base" => %{interface: interface, interface_fingerprint: "unused"}}

    assert {:ok, %Config{}} =
             GameCompiler.compile(metadata(DependencyGame, ["base"]), catalog(), dependencies)

    assert {:error, [%{code: :unresolved_game_reference}]} =
             GameCompiler.compile(metadata(DependencyGame), catalog(), dependencies)
  end

  test "own terrain catalog records must be canonical registered blocks owned by this plugin" do
    malformed_blocks = [
      [%{id: "base:stone", plugin_id: "base", local_id: "stone", kind: :block}],
      [%{id: "game:stone", plugin_id: "game", local_id: "stone", kind: :item}],
      [%{id: "game:stone", plugin_id: "game", local_id: "stone", kind: :block, role: :template}],
      [%{id: "game:other", plugin_id: "game", local_id: "stone", kind: :block}]
    ]

    for blocks <- malformed_blocks do
      assert {:error, [%{code: :unresolved_game_reference}]} =
               GameCompiler.compile(metadata(Game), %{blocks: blocks}, %{})
    end

    assert {:ok, %Config{}} =
             GameCompiler.compile(metadata(Game), catalog(), %{})
  end

  test "terrain references cannot resolve through only a transitive dependency" do
    addon_interface = %{
      declarations: [%{plugin_id: "base", local_id: "stone", kind: :block, role: :registered}]
    }

    dependencies = %{
      "addon" => %{plugin: addon_interface},
      "base" => %{plugin: %{declarations: []}}
    }

    assert {:error, [%{code: :unresolved_game_reference}]} =
             GameCompiler.compile(metadata(DependencyGame, ["addon"]), catalog(), dependencies)
  end

  test "game builder must be owned by the declaring plugin" do
    assert {:error, [%{code: :invalid_game_config}]} =
             GameCompiler.compile(%{metadata(Game) | modules: []}, catalog(), %{})
  end
end
