defmodule Lemieux.Scripts.TerminalNifCache do
  @moduledoc """
  Fills a CI-owned Rustler cache without httpc's response-header limit.

  GitHub release redirects exceeded OTP's 10 KiB response-header limit. Curl
  retains TLS verification, and the Hex package's checksum is checked here and
  again by Rustler before loading. This script uses only OTP and Elixir so it
  can run before dependencies compile and on the oldest supported toolchain.
  """

  @spec select(
          contents :: String.t(),
          nif :: String.t(),
          system :: String.t(),
          machine :: String.t(),
          abi :: String.t() | nil
        ) :: {String.t(), String.t(), String.t()}
  def select(contents, nif, system, machine, abi \\ nil) do
    target = target(system, architecture(machine), abi)
    limit = version(nif)

    compatible =
      ~r/"((?:lib)?ex_ratatui-v([0-9.]+)-nif-([0-9.]+)-[^"\/]+\.so\.tar\.gz)"\s*=>\s*"sha256:([a-f0-9]{64})"/
      |> Regex.scan(contents, capture: :all_but_first)
      |> Enum.filter(fn [name, _version, nif, _checksum] ->
        String.ends_with?(name, target <> ".so.tar.gz") and version(nif) <= limit
      end)

    if compatible == [] or compatible |> Enum.map(&Enum.at(&1, 1)) |> Enum.uniq() |> length() != 1 do
      raise ArgumentError, "missing or ambiguous compatible terminal NIF checksum"
    end

    [name, release, _nif, checksum] =
      Enum.max_by(compatible, fn entry -> version(Enum.at(entry, 2)) end)

    {if(String.starts_with?(name, "lib"), do: name, else: "lib" <> name), release, checksum}
  end

  @spec cache(
          directory :: Path.t(),
          selection :: {String.t(), String.t(), String.t()},
          fetch :: (String.t(), Path.t() -> term())
        ) :: Path.t()
  def cache(directory, {name, release, checksum}, fetch \\ &download/2) do
    File.mkdir_p!(directory)
    destination = Path.join(directory, name)

    if File.exists?(destination) do
      verify!(destination, checksum, "existing CI cache artifact")
    else
      temporary =
        Path.join(
          directory,
          "download-" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
        )

      File.write!(temporary, "", [:exclusive])

      try do
        fetch.(
          "https://github.com/mcass19/ex_ratatui/releases/download/v#{release}/#{name}",
          temporary
        )

        verify!(temporary, checksum, "downloaded terminal NIF")
        File.rename!(temporary, destination)
      after
        File.rm(temporary)
      end
    end

    destination
  end

  @spec main(argv :: [String.t()]) :: :ok
  def main(argv) do
    case OptionParser.parse(argv, strict: [nif_version: :string]) do
      {opts, [package, directory], []} ->
        nif = Keyword.get(opts, :nif_version, to_string(:erlang.system_info(:nif_version)))
        checksum = Path.join(package, "checksum-Elixir.ExRatatui.Native.exs")

        if File.regular?(checksum) do
          {system, machine} = platform()

          selection =
            select(File.read!(checksum), nif, system, machine, System.get_env("TARGET_ABI"))

          IO.puts("Verified CI terminal NIF: " <> Path.basename(cache(directory, selection)))
        end

        :ok

      _invalid ->
        raise ArgumentError,
              "usage: elixir scripts/cache_terminal_nif.exs PACKAGE CACHE [--nif-version VERSION]"
    end
  end

  defp verify!(path, checksum, context) do
    actual =
      path
      |> File.stream!(65_536, [])
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    if actual != checksum, do: raise(ArgumentError, "#{context} has the wrong checksum")
  end

  defp download(url, destination) do
    {_output, status} =
      System.cmd("curl", [
        "--fail",
        "--location",
        "--silent",
        "--show-error",
        "--retry",
        "3",
        "--connect-timeout",
        "15",
        "--max-time",
        "120",
        "--max-filesize",
        "104857600",
        "--proto",
        "=https",
        "--proto-redir",
        "=https",
        "--output",
        destination,
        url
      ])

    if status != 0, do: raise("terminal NIF download failed (curl exit #{status})")
  end

  defp platform do
    machine =
      :erlang.system_info(:system_architecture) |> to_string() |> String.split("-") |> hd()

    system =
      case :os.type() do
        {:unix, :darwin} -> "Darwin"
        {:unix, :linux} -> "Linux"
        _unsupported -> raise ArgumentError, "unsupported CI native platform"
      end

    {system, machine}
  end

  defp architecture(machine) when machine in ~w(arm64 aarch64), do: "aarch64"
  defp architecture(machine) when machine in ~w(x86_64 AMD64), do: "x86_64"
  defp architecture(_machine), do: raise(ArgumentError, "unsupported CI native architecture")
  defp target("Darwin", arch, _abi), do: arch <> "-apple-darwin"
  defp target("Linux", arch, "musl"), do: arch <> "-unknown-linux-musl"
  defp target("Linux", arch, _abi), do: arch <> "-unknown-linux-gnu"
  defp target(_system, _arch, _abi), do: raise(ArgumentError, "unsupported CI native platform")
  defp version(value), do: value |> String.split(".") |> Enum.map(&String.to_integer/1)
end
