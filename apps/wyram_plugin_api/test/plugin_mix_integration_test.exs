defmodule Wyram.Plugin.MixIntegrationTest do
  use ExUnit.Case, async: false

  @fixture_root Path.expand("../fixtures/cross_plugin", __DIR__)

  test "Mix compiles a dependency template, tracks BEAM fingerprints, and clears stale outputs" do
    workspace = temp_path("mix-projects")
    build_path = temp_path("mix-build")
    File.mkdir_p!(workspace)
    {:ok, _} = File.cp_r(@fixture_root, workspace)

    on_exit(fn ->
      File.rm_rf(workspace)
      File.rm_rf(build_path)
    end)

    base_dir = Path.join(workspace, "base")
    addon_dir = Path.join(workspace, "addon")
    api_path = Path.expand("..", __DIR__)

    assert {output1, 0} =
             run_mix(addon_dir, build_path, api_path, ["compile", "--warnings-as-errors"])

    assert output1 =~ "wyram_cross_plugin_base"
    assert output1 =~ "wyram_cross_plugin_addon"

    base_catalog = catalog_path(build_path, "wyram_cross_plugin_base")
    addon_catalog = catalog_path(build_path, "wyram_cross_plugin_addon")
    first_base_bytes = File.read!(base_catalog)
    first_addon_bytes = File.read!(addon_catalog)

    {first_observation, 0} =
      run_mix(addon_dir, build_path, api_path, [
        "run",
        "--no-compile",
        "scripts/assert_catalog.exs"
      ])

    first_base_fingerprint = fingerprint_line(first_observation, "BASE_FP")
    first_dependency_fingerprint = fingerprint_line(first_observation, "ADDON_DEP_FP")
    assert first_dependency_fingerprint == first_base_fingerprint

    assert {_, 0} = run_mix(addon_dir, build_path, api_path, ["compile", "--warnings-as-errors"])
    assert File.read!(base_catalog) == first_base_bytes
    assert File.read!(addon_catalog) == first_addon_bytes

    helper_path = Path.join(base_dir, "lib/provider_helper.ex")
    helper_source = File.read!(helper_path)
    File.write!(helper_path, String.replace(helper_source, "{20, 30, 40}", "{20, 30, 41}"))

    assert {_, 0} = run_mix(addon_dir, build_path, api_path, ["compile", "--warnings-as-errors"])

    {changed_observation, 0} =
      run_mix(addon_dir, build_path, api_path, [
        "run",
        "--no-compile",
        "scripts/assert_catalog.exs"
      ])

    changed_base_fingerprint = fingerprint_line(changed_observation, "BASE_FP")
    changed_dependency_fingerprint = fingerprint_line(changed_observation, "ADDON_DEP_FP")
    refute changed_base_fingerprint == first_base_fingerprint
    assert changed_dependency_fingerprint == changed_base_fingerprint

    File.write!(Path.join(addon_dir, "lib/plugin.ex"), "defmodule BrokenPlugin do\n")
    assert {syntax_output, status} = run_mix(addon_dir, build_path, api_path, ["compile"])
    refute status == 0

    assert syntax_output =~ "SyntaxError" or syntax_output =~ "TokenMissingError" or
             syntax_output =~ "syntax error"

    refute File.exists?(addon_catalog)

    File.rm!(Path.join(base_dir, "lib/plugin.ex"))
    assert {_, status} = run_mix(base_dir, build_path, api_path, ["compile"])
    refute status == 0
    refute File.exists?(base_catalog)

    refute File.exists?(
             beam_path(
               build_path,
               "wyram_cross_plugin_base",
               "Elixir.WyramCrossPluginBase.Entry.Blocks.Stone"
             )
           )
  end

  defp run_mix(directory, build_path, api_path, args) do
    System.cmd(mix_executable(), args,
      cd: directory,
      env: [
        {"WYRAM_FIXTURE_BUILD_PATH", build_path},
        {"WYRAM_PLUGIN_API_PATH", api_path}
      ],
      stderr_to_stdout: true
    )
  end

  defp mix_executable do
    System.find_executable("mix") || raise "mix executable is not available in PATH"
  end

  defp catalog_path(build_path, app),
    do: Path.join([build_path, "dev", "lib", app, "priv", "wyram", "catalog.term"])

  defp beam_path(build_path, app, module),
    do: Path.join([build_path, "dev", "lib", app, "ebin", module <> ".beam"])

  defp fingerprint_line(output, name) do
    [_, value] = Regex.run(~r/#{name}=([0-9a-f]{64})/, output)
    value
  end

  defp temp_path(name),
    do: Path.join(System.tmp_dir!(), "wyram-#{name}-#{System.unique_integer([:positive])}")
end
