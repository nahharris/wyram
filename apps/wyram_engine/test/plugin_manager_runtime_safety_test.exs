defmodule Wyram.Engine.PluginManagerRuntimeSafetyTest do
  use ExUnit.Case, async: true

  alias Wyram.Engine.PluginManager

  test "rejects individually bounded package atom counts whose aggregate exceeds the limit" do
    counts = [60_000, 40_001]

    assert Enum.all?(counts, &(&1 < 100_000))
    assert {:error, :beam_atom_budget_exceeded} = PluginManager.validate_atom_budget(counts)
    assert {:error, :beam_atom_budget_exceeded} = PluginManager.validate_atom_budget([:invalid])
  end

  test "rolls back earlier modules when a later on_load fails and permits retry" do
    suffix = System.unique_integer([:positive])
    first = Module.concat([WyramMods, PluginManagerRollbackFixture, "First#{suffix}"])
    second = Module.concat([WyramMods, PluginManagerRollbackFixture, "Second#{suffix}"])
    failure_env = "WYRAM_ON_LOAD_FAIL_#{suffix}"

    first_beam =
      compile_module(
        first,
        quote do
          def value, do: :loaded
        end
      )

    second_beam =
      compile_module(
        second,
        quote do
          @on_load :check_environment

          def check_environment do
            if System.get_env(unquote(failure_env)) == "1",
              do: {:error, :requested_failure},
              else: :ok
          end

          def value, do: :loaded
        end
      )

    Enum.each([first, second], &:code.delete/1)
    Enum.each([first, second], &:code.purge/1)
    System.put_env(failure_env, "1")

    on_exit(fn ->
      System.delete_env(failure_env)
      Enum.each([first, second], &:code.delete/1)
      Enum.each([first, second], &:code.purge/1)
    end)

    modules = Enum.sort_by([first, second], &Atom.to_string/1)

    contents = [
      {String.to_charlist("ebin/#{Atom.to_string(first)}.beam"), first_beam},
      {String.to_charlist("ebin/#{Atom.to_string(second)}.beam"), second_beam}
    ]

    package = %{
      manifest: %{"id" => "rollback", "modules" => Enum.map(modules, &Atom.to_string/1)},
      contents: contents
    }

    assert {:error, {:beam_load_failed, failed, _}} =
             PluginManager.load_packages([package], ["rollback"])

    assert failed == Atom.to_string(second)
    assert :code.is_loaded(first) == false

    System.delete_env(failure_env)
    assert :ok = PluginManager.load_packages([package], ["rollback"])
    assert :code.is_loaded(first)
    assert :code.is_loaded(second)
  end

  test "rejects stale BEAM hashes without executing their on_load callback" do
    marker_env = "WYRAM_ON_LOAD_MARKER_#{System.unique_integer([:positive])}"

    module =
      Module.concat([
        WyramMods,
        PluginManagerHashFixture,
        "Marker#{System.unique_integer([:positive])}"
      ])

    marker_path =
      Path.join(System.tmp_dir!(), "wyram-on-load-marker-#{System.unique_integer([:positive])}")

    System.put_env(marker_env, marker_path)

    beam =
      compile_module(
        module,
        quote do
          @on_load :write_marker

          def write_marker do
            File.write!(System.fetch_env!(unquote(marker_env)), "executed")
            :ok
          end
        end
      )

    on_exit(fn ->
      System.delete_env(marker_env)
      File.rm(marker_path)
      :code.delete(module)
      :code.purge(module)
    end)

    assert File.exists?(marker_path)
    :code.delete(module)
    :code.purge(module)
    File.rm!(marker_path)

    name = Atom.to_string(module)
    artifact = %{interface: %{module_hashes: %{name => String.duplicate("0", 64)}}}
    manifest = %{"modules" => [name]}
    contents = [{String.to_charlist("ebin/#{name}.beam"), beam}]

    assert {:error, {:module_hash_mismatch, ^name}} =
             PluginManager.verify_beam_modules(manifest, artifact, contents)

    refute File.exists?(marker_path)
    refute :code.is_loaded(module)
  end

  test "rejects a module already available on the code path before loading it" do
    module =
      Module.concat([
        AvailablePluginCollisionFixture,
        "Module#{System.unique_integer([:positive])}"
      ])

    beam = compile_module(module, quote(do: def(value, do: :original)))
    :code.delete(module)
    :code.purge(module)

    directory =
      Path.join(
        System.tmp_dir!(),
        "wyram-available-collision-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)
    name = Atom.to_string(module)
    File.write!(Path.join(directory, name <> ".beam"), beam)
    :code.add_patha(String.to_charlist(directory))

    on_exit(fn ->
      :code.del_path(String.to_charlist(directory))
      :code.delete(module)
      :code.purge(module)
      File.rm_rf(directory)
    end)

    refute :code.is_loaded(module)

    package = %{
      manifest: %{"id" => "collision", "modules" => [name]},
      contents: [{String.to_charlist("ebin/#{name}.beam"), beam}]
    }

    assert {:error, :module_collision} = PluginManager.load_packages([package], ["collision"])
    refute :code.is_loaded(module)
  end

  defp compile_module(module, body) do
    quoted =
      quote do
        defmodule unquote(module) do
          unquote(body)
        end
      end

    [{^module, beam}] = Code.compile_quoted(quoted)
    beam
  end
end
