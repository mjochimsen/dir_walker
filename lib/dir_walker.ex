defmodule DirWalker do

  @moduledoc Path.join([__DIR__, "../README.md"]) |> File.read!

  require Logger

  use GenServer

  def start_link(path, opts \\ [])

  def start_link(list_of_paths, opts) when is_list(list_of_paths) do
    mappers = setup_mappers(opts)
    GenServer.start_link(__MODULE__, {list_of_paths, mappers})
  end

  def start_link(path, opts) when is_binary(path) do
    start_link([path], opts)
  end

  @doc """
  Return the next _n_ files from the lists of files, recursing into
  directories if necessary. Return `nil` when there are no files
  to return. (If there are fewer than _n_ files remaining, just those
  files are returned, and `nil` will be returned on the next call.

  ## Example

        iex> {:ok,d} = DirWalker.start_link "."
        {:ok, #PID<0.83.0>}
        iex> DirWalker.next(d)                 
        ["./.gitignore"]
        iex> DirWalker.next(d)
        ["./_build/dev/lib/dir_walter/.compile.elixir"]
        iex> DirWalker.next(d, 3)
        ["./_build/dev/lib/dir_walter/ebin/Elixir.DirWalker.beam",
         "./_build/dev/lib/dir_walter/ebin/dir_walter.app",
         "./_build/dev/lib/dir_walter/.compile.lock"]
        iex> 
  """
  def next(iterator, n \\ 1) do
    GenServer.call(iterator, { :get_next, n })
  end

  @doc """
   Stops the DirWalker
  """
  def stop(server) do
    GenServer.call(server, :stop)
  end

  @doc """
  Implement a stream interface that will return a lazy enumerable. 

  ## Example

    iex> first_file = DirWalker.stream("/") |> Enum.take(1)

  """

  def stream(path_list, opts \\ []) do
    Stream.resource( fn -> 
                      {:ok, dirw} = DirWalker.start_link(path_list, opts)
                      dirw
                    end ,
                    fn(dirw) -> 
                      case DirWalker.next(dirw,1) do
                        data when is_list(data) -> {data, dirw }
                        _ -> {:halt, dirw}
                      end
                    end,
                    fn(dirw) -> DirWalker.stop(dirw) end 
      )
  end 

  ##################
  # Implementation #
  ##################

  def init(path_list) do
    { :ok, path_list }
  end
  
  def handle_call({:get_next, _n}, _from, state = {[], _}) do
    { :reply, nil, state}
  end

  def handle_call({:get_next, n}, _from, {path_list, mappers}) do
    {result, new_path_list} = first_n(path_list, n, mappers, _result=[])
    { :reply, result, {new_path_list, mappers} }
  end

  def handle_call(:stop, from, state) do
      GenServer.reply(from, :ok )
      {:stop, :normal, state}
  end


  # If our count is zero, then we've pulled all the paths we need.
  defp first_n(path_list, 0, _mappers, result), do: {Enum.reverse(result), path_list}

  # If our pathname list is empty, we're done.
  defp first_n([], _n, _mappers, result),       do: {Enum.reverse(result), []}

  # If the first element is a function, then it represents an unvisited
  # subdirectory. Visit it and add the entries to the list of paths.
  defp first_n([ dirfn | rest], n, mappers, result) when is_function(dirfn) do
    first_n(dirfn.() ++ rest, n, mappers, result)
  end

  # Otherwise just a path as the first entry
  defp first_n([ path | rest ], n, mappers, result) do
    stat = File.stat!(path)
    if stat.type == :directory do
      rest = [get_files_for(path) | rest]
    end
    if mappers.filter.(path, stat) do
      first_n(rest, n-1, mappers, [ mappers.include_stat.(path, stat) | result ])
    else
      first_n(rest, n, mappers, result)
    end
  end

  defp get_files_for(path) do
    fn -> path
          |> :file.list_dir
          |> ignore_error(path)
          |> Enum.map(fn(rel) -> Path.join(path, rel) end)
    end
  end

  defp ignore_error({:error, type}, path) do
    Logger.info("Ignore folder #{path} (#{type})")
    []
  end

  defp ignore_error({:ok, list}, _path), do: list


  defp setup_mappers(opts) do
    _mappers = %{
      filter: create_filter(opts[:include_dir_names], opts[:matching]),

      include_stat:
        one_of(opts[:include_stat],
               fn (path, _stat) -> path end,    
               fn (path, stat)  -> {path, stat} end),
    }
  end


  defp create_filter(nil, nil) do
    fn _path, stat -> stat.type == :regular end
  end

  defp create_filter(true, nil) do
    fn _path, _stat -> true end
  end

  defp create_filter(nil, regex = %Regex{}) do
    fn path, stat -> stat.type == :regular && Regex.match?(regex, path) end
  end

  defp create_filter(true, regex = %Regex{}) do
    fn path, _stat -> Regex.match?(regex, path) end
  end


  defp one_of(bool, _if_false, if_true) when bool, do: if_true
  defp one_of(_bool, if_false, _if_true),          do: if_false
end
