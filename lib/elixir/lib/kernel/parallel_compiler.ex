defmodule Kernel.ParallelCompiler do
  @moduledoc """
  A module responsible for compiling files in parallel.
  """

  @doc """
  Compiles the given files.

  Those files are compiled in parallel and can automatically
  detect dependencies between them. Once a dependency is found,
  the current file stops being compiled until the dependency is
  resolved.

  If there is an error during compilation or if `warnings_as_errors`
  is set to `true` and there is a warning, this function will fail
  with an exception.

  This function accepts the following options:

    * `:each_file` - for each file compiled, invokes the callback passing the
      file

    * `:each_long_compilation` - for each file that takes more than a given
      timeout (see the `:long_compilation_threshold` option) to compile, invoke
      this callback passing the file as its argument

    * `:long_compilation_threshold` - the timeout (in milliseconds) after the
      `:each_long_compilation` callback is invoked; defaults to `5000`

    * `:each_module` - for each module compiled, invokes the callback passing
      the file, module and the module bytecode

    * `:dest` - the destination directory for the beam files. When using `files/2`,
      this information is only used to properly annotate the beam files before
      they are loaded into memory. If you want a file to actually be written to
      `dest`, use `files_to_path/3` instead.

  Returns the modules generated by each compiled file.
  """
  def files(files, options \\ [])

  def files(files, options) when is_list(options) do
    spawn_compilers(files, nil, options)
  end

  @doc """
  Compiles the given files to the given path.
  Read `files/2` for more information.
  """
  def files_to_path(files, path, options \\ [])

  def files_to_path(files, path, options) when is_binary(path) and is_list(options) do
    spawn_compilers(files, path, options)
  end

  defp spawn_compilers(files, path, options) do
    true = Code.ensure_loaded?(Kernel.ErrorHandler)
    compiler_pid = self()
    :elixir_code_server.cast({:reset_warnings, compiler_pid})
    schedulers = max(:erlang.system_info(:schedulers_online), 2)

    result = spawn_compilers(files, files, path, options, [], [], schedulers, [])

    # In case --warning-as-errors is enabled and there was a warning,
    # compilation status will be set to error.
    case :elixir_code_server.call({:compilation_status, compiler_pid}) do
      :ok ->
        result
      :error ->
        IO.puts :stderr, "Compilation failed due to warnings while using the --warnings-as-errors option"
        exit({:shutdown, 1})
    end
  end

  # We already have n=schedulers currently running, don't spawn new ones
  defp spawn_compilers(entries, original, output, options, waiting, queued, schedulers, result) when
      length(queued) - length(waiting) >= schedulers do
    wait_for_messages(entries, original, output, options, waiting, queued, schedulers, result)
  end

  # Release waiting processes
  defp spawn_compilers([{h, kind} | t], original, output, options, waiting, queued, schedulers, result) when is_pid(h) do
    waiting =
      case List.keytake(waiting, h, 1) do
        {{_kind, ^h, ref, _module, _defining}, waiting} ->
          send h, {ref, kind}
          waiting
        nil ->
          waiting
      end
    spawn_compilers(t, original, output, options, waiting, queued, schedulers, result)
  end

  # Spawn a compiler for each file in the list until we reach the limit
  defp spawn_compilers([h | t], original, output, options, waiting, queued, schedulers, result) do
    parent = self()

    {pid, ref} =
      :erlang.spawn_monitor fn ->
        # Set the elixir_compiler_pid used by our custom Kernel.ErrorHandler.
        :erlang.put(:elixir_compiler_pid, parent)
        :erlang.process_flag(:error_handler, Kernel.ErrorHandler)

        exit(try do
          _ = if output do
            :elixir_compiler.file_to_path(h, output)
          else
            :elixir_compiler.file(h, Keyword.get(options, :dest))
          end
          {:shutdown, h}
        catch
          kind, reason ->
            {:failure, kind, reason, System.stacktrace}
        end)
      end

    timeout = Keyword.get(options, :long_compilation_threshold, 5_000)
    timer_ref = Process.send_after(self(), {:timed_out, pid}, timeout)

    new_queued = [{pid, ref, h, timer_ref} | queued]
    spawn_compilers(t, original, output, options, waiting, new_queued, schedulers, result)
  end

  # No more files, nothing waiting, queue is empty, we are done
  defp spawn_compilers([], _original, _output, _options, [], [], _schedulers, result) do
    for {:module, mod} <- result, do: mod
  end

  # Queued x, waiting for x: POSSIBLE ERROR! Release processes so we get the failures
  defp spawn_compilers([], original, output, options, waiting, queued, schedulers, result) when length(waiting) == length(queued) do
    entries = for {pid, _, _, _} <- queued,
                  waiting_on_is_not_being_defined?(waiting, pid),
                  do: {pid, :not_found}

    case entries do
      [] -> handle_deadlock(waiting, queued)
      _  -> spawn_compilers(entries, original, output, options, waiting, queued, schedulers, result)
    end
  end

  # No more files, but queue and waiting are not full or do not match
  defp spawn_compilers([], original, output, options, waiting, queued, schedulers, result) do
    wait_for_messages([], original, output, options, waiting, queued, schedulers, result)
  end

  defp waiting_on_is_not_being_defined?(waiting, pid) do
    {_kind, ^pid, _, on, _defining} = List.keyfind(waiting, pid, 1)
    List.keyfind(waiting, on, 4) == nil
  end

  # Wait for messages from child processes
  defp wait_for_messages(entries, original, output, options, waiting, queued, schedulers, result) do
    receive do
      {:struct_available, module} ->
        available = for {:struct, pid, _, waiting_module, _defining} <- waiting,
                        module == waiting_module,
                        do: {pid, :found}

        spawn_compilers(available ++ entries, original, output, options,
                        waiting, queued, schedulers, [{:struct, module} | result])

      {:module_available, child, ref, file, module, binary} ->
        if callback = Keyword.get(options, :each_module) do
          callback.(file, module, binary)
        end

        # Release the module loader which is waiting for an ack
        send child, {ref, :ack}

        available = for {_kind, pid, _, waiting_module, _defining} <- waiting,
                        module == waiting_module,
                        do: {pid, :found}

        cancel_waiting_timer(queued, child)

        spawn_compilers(available ++ entries, original, output, options,
                        waiting, queued, schedulers, [{:module, module} | result])

      {:waiting, kind, child, ref, on, defining} ->
        defined = fn {k, m} -> on == m and k in [kind, :module] end

        # Oops, we already got it, do not put it on waiting.
        waiting =
          if :lists.any(defined, result) do
            send child, {ref, :found}
            waiting
          else
            [{kind, child, ref, on, defining} | waiting]
          end

        spawn_compilers(entries, original, output, options, waiting, queued, schedulers, result)

      {:timed_out, child} ->
        if callback = Keyword.get(options, :each_long_compilation) do
          {^child, _, file, _} = List.keyfind(queued, child, 0)
          callback.(file)
        end
        spawn_compilers(entries, original, output, options, waiting, queued, schedulers, result)

      {:DOWN, _down_ref, :process, down_pid, {:shutdown, file}} ->
        if callback = Keyword.get(options, :each_file) do
          callback.(file)
        end

        cancel_waiting_timer(queued, down_pid)

        # Sometimes we may have spurious entries in the waiting
        # list because someone invoked try/rescue UndefinedFunctionError
        new_entries = List.delete(entries, down_pid)
        new_queued  = List.keydelete(queued, down_pid, 0)
        new_waiting = List.keydelete(waiting, down_pid, 1)
        spawn_compilers(new_entries, original, output, options, new_waiting, new_queued, schedulers, result)

      {:DOWN, down_ref, :process, _down_pid, reason} ->
        handle_failure(down_ref, reason, queued)
        wait_for_messages(entries, original, output, options, waiting, queued, schedulers, result)
    end
  end

  defp handle_deadlock(waiting, queued) do
    deadlock =
      for {pid, _, file, _} <- queued do
        {:current_stacktrace, stacktrace} = Process.info(pid, :current_stacktrace)
        Process.exit(pid, :kill)

        {_kind, ^pid, _, on, _} = List.keyfind(waiting, pid, 1)
        error = CompileError.exception(description: "deadlocked waiting on module #{inspect on}")
        print_failure(file, {:failure, :error, error, stacktrace})

        {file, on}
      end

    IO.puts """

    Compilation failed because of a deadlock between files.
    The following files depended on the following modules:
    """

    max =
      deadlock
      |> Enum.map(& &1 |> elem(0) |> String.length)
      |> Enum.max

    for {file, mod} <- deadlock do
      IO.puts "  " <> String.rjust(file, max) <> " => " <> inspect(mod)
    end

    IO.puts ""
    exit({:shutdown, 1})
  end

  defp handle_failure(ref, reason, queued) do
    if file = find_failure(ref, queued) do
      print_failure(file, reason)
      for {pid, _, _, _} <- queued do
        Process.exit(pid, :kill)
      end
      exit({:shutdown, 1})
    end
  end

  defp find_failure(ref, queued) do
    case List.keyfind(queued, ref, 1) do
      {_child, ^ref, file, _timer_ref} -> file
      _ -> nil
    end
  end

  defp print_failure(_file, {:shutdown, _}) do
    :ok
  end

  defp print_failure(file, {:failure, kind, reason, stacktrace}) do
    IO.puts "\n== Compilation error on file #{Path.relative_to_cwd(file)} =="
    IO.puts Exception.format(kind, reason, prune_stacktrace(stacktrace))
  end

  defp print_failure(file, reason) do
    IO.puts "\n== Compilation error on file #{Path.relative_to_cwd(file)} =="
    IO.puts Exception.format(:exit, reason, [])
  end

  @elixir_internals [:elixir, :elixir_exp, :elixir_compiler, :elixir_module, :elixir_clauses,
                     :elixir_translator, :elixir_expand, :elixir_lexical, :elixir_exp_clauses,
                     :elixir_def, :elixir_map, Kernel.ErrorHandler]

  defp prune_stacktrace([{mod, _, _, _} | t]) when mod in @elixir_internals do
    prune_stacktrace(t)
  end

  defp prune_stacktrace([h | t]) do
    [h | prune_stacktrace(t)]
  end

  defp prune_stacktrace([]) do
    []
  end

  defp cancel_waiting_timer(queued, child_pid) do
    case List.keyfind(queued, child_pid, 0) do
      {^child_pid, _ref, _file, timer_ref} ->
        Process.cancel_timer(timer_ref)
        # Let's flush the message in case it arrived before we canceled the
        # timeout.
        receive do
          {:timed_out, ^child_pid} -> :ok
        after
          0 -> :ok
        end
      nil ->
        :ok
    end
  end
end
