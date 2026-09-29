defmodule Wyram.Engine.Paths do
  @moduledoc "User data and native executable locations."

  def data_dir do
    System.get_env("WYRAM_DATA_DIR") ||
      Path.join(System.get_env("LOCALAPPDATA") || System.user_home!(), "Wyram")
  end

  def client_executable do
    System.get_env("WYRAM_CLIENT") ||
      Path.expand("native/target/debug/wyram_client.exe", File.cwd!())
  end
end
