defmodule Minted.Version do
  @moduledoc """
  Build-time version information.

  Captures git commit hash at compile time by reading directly from
  .git files, avoiding System.cmd calls.
  """

  @external_resource ".git/refs/heads/main"

  @git_sha (case File.read(".git/refs/heads/main") do
              {:ok, sha} ->
                String.slice(String.trim(sha), 0, 7)

              _error ->
                case File.read(".git/HEAD") do
                  {:ok, "ref: " <> ref} ->
                    ref_path = Path.join(".git", String.trim(ref))
                    safe_path = Path.expand(ref_path)
                    base_path = Path.expand(".git")

                    if String.starts_with?(safe_path, base_path <> "/") do
                      case File.read(safe_path) do
                        {:ok, sha} -> String.slice(String.trim(sha), 0, 7)
                        _error -> "dev"
                      end
                    else
                      "dev"
                    end

                  _error ->
                    "dev"
                end
            end)

  @doc "Returns the short git commit hash from build time"
  @spec git_sha() :: String.t()
  def git_sha, do: @git_sha
end
