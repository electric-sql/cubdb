defmodule CubDB do
  @moduledoc """
  `CubDB` is an embedded key-value database written in the Elixir language. It
  runs locally, it is schema-less, and backed by a single file.

  ## Fetaures

    - Both keys and values can be any arbitrary Elixir (or Erlang) term.

    - Simple `get/3`, `put/3`, and `delete/2` operations

    - Arbitrary selection of entries and transformation with `select/3`

    - Atomic transactions with `get_and_update_multi/4`

    - Concurrent read operations, that do not block nor are blocked by writes

    - Unexpected shutdowns won't corrupt the database or break atomicity

    - Manual or automatic compaction to optimize space usage

  To ensure consistency, performance, and robustness to data corruption, `CubDB`
  database file uses an append-only, immutable B-tree data structure. Entries
  are never changed in-place, and read operations are performend on immutable
  snapshots.

  ## Usage

  Start `CubDB` by specifying a directory for its database file (if not existing,
  it will be created):

      {:ok, db} = CubDB.start_link("my/data/directory")

  `CubDB` functions can be called concurrently from different processes, but it
  is important that only one `CubDB` process is started on the same data
  directory.

  The `get/2`, `put/3`, and `delete/2` functions work as you probably expect:

      CubDB.put(db, :foo, "some value")
      #=> :ok

      CubDB.get(db, :foo)
      #=> "some value"

      CubDB.delete(db, :foo)
      #=> :ok

      CubDB.get(db, :foo)
      #=> nil

  Range of keys are retrieved using `select/3`:

      for {key, value} <- [a: 1, b: 2, c: 3, d: 4, e: 5, f: 6, g: 7, h: 8] do
        CubDB.put(db, key, value)
      end

      CubDB.select(db, min_key: :b, max_key: :e)
      #=> {:ok, [b: 2, c: 3, d: 4, e: 5]}

  But `select/3` can do much more than that. It can apply a pipeline of operations
  (`map`, `filter`, `take`, `drop` and more) to the selected entries, it can
  select the entries in normal or reverse order, and it can `reduce` the result
  using an arbitrary function:

      # Take the sum of the last 3 even values:
      CubDB.select(db,
        # select entries in reverse order
        reverse: true,

        # apply a pipeline of operations to the entries
        pipe: [
          # map each entry discarding the key and keeping only the value
          map: fn {_key, value} -> value end,

          # filter only even integers
          filter: fn value -> is_integer(value) && Integer.is_even(value) end,

          # take the first 3 values
          take: 3
        ],

        # reduce the result to a sum
        reduce: fn n, sum -> sum + n end
      )
      #=> {:ok, 18}

  Because `CubDB` uses an immutable data structure, write operations cause the
  data file to grow. Occasionally, it is adviseable to run a compaction to
  optimize the file size and reclaim disk space. Compaction can be started
  manually by calling `compact/1`, and runs in the background, without blocking
  other operations:

      CubDB.compact(db)
      #=> :ok

  Alternatively, automatic compaction can be enabled, either passing an option
  to `start_link/3`, or by calling `set_auto_compact/2`.
  """

  @doc """
  Returns a specification to start this module under a supervisor.

  The default options listed in `Supervisor` are used.
  """
  use GenServer

  alias CubDB.Btree
  alias CubDB.Store
  alias CubDB.Reader
  alias CubDB.Compactor
  alias CubDB.CatchUp
  alias CubDB.CleanUp

  @db_file_extension ".cub"
  @compaction_file_extension ".compact"
  @auto_compact_defaults {100, 0.25}

  @type key :: any
  @type value :: any
  @type entry :: {key, value}

  defmodule State do
    @moduledoc false

    @type t :: %CubDB.State{
            btree: Btree.t(),
            data_dir: binary,
            compactor: pid | nil,
            clean_up: pid,
            clean_up_pending: boolean,
            busy_files: %{required(binary) => pos_integer},
            auto_compact: {pos_integer, pos_integer} | false,
            subs: list(pid)
          }

    @enforce_keys [:btree, :data_dir, :clean_up]
    defstruct btree: nil,
              data_dir: nil,
              compactor: nil,
              clean_up: nil,
              clean_up_pending: false,
              busy_files: %{},
              auto_compact: false,
              subs: []
  end

  @spec start_link(binary, Keyword.t(), GenServer.options()) :: GenServer.on_start()

  @doc """
  Starts the `CubDB` database process linked to the current process.

  The `data_dir` argument is the directory path where the database files will be
  stored. If it does not exist, it will be created. Only one `CubDB` instance
  can run per directory, so if you run several databases, they should each use
  their own separate data directory.

  The optional `options` argument is a keywork list that specifies configuration
  options. The valid options are:

    - `auto_compact`: whether to perform auto-compaction. It defaults to false.
    See `set_auto_compact/2` for the possible values

  The `gen_server_options` are passed to `GenServer.start_link/3`.
  """
  def start_link(data_dir, options \\ [], gen_server_options \\ []) do
    GenServer.start_link(__MODULE__, [data_dir, options], gen_server_options)
  end

  @spec start(binary, Keyword.t(), GenServer.options()) :: GenServer.on_start()

  @doc """
  Starts the `CubDB` database without a link.

  See `start_link/2` for more informations.
  """
  def start(data_dir, options \\ [], gen_server_options \\ []) do
    GenServer.start(__MODULE__, [data_dir, options], gen_server_options)
  end

  @spec get(GenServer.server(), key, value) :: value

  @doc """
  Gets the value associated to `key` from the database.

  If no value is associated with `key`, `default` is returned (which is `nil`,
  unless specified otherwise).
  """
  def get(db, key, default \\ nil) do
    GenServer.call(db, {:get, key, default})
  end

  @spec fetch(GenServer.server(), key) :: {:ok, value} | :error

  @doc """
  Fetches the value for the given `key` in the database, or return `:error` if `key` is not present.

  If the database contains an entry with the given `key` and value `value`, it
  returns `{:ok, value}`. If `key` is not found, it returns `:error`.
  """
  def fetch(db, key) do
    GenServer.call(db, {:fetch, key})
  end

  @spec has_key?(GenServer.server(), key) :: boolean

  @doc """
  Returns whether an entry with the given `key` exists in the database.
  """
  def has_key?(db, key) do
    GenServer.call(db, {:has_key?, key})
  end

  @spec select(GenServer.server(), Keyword.t(), timeout) ::
          {:ok, any} | {:error, Exception.t()}

  @doc """
  Selects a range of entries from the database, and optionally performs a
  pipeline of operations on them.

  It returns `{:ok, result}` if successful, or `{:error, exception}` if an
  exception is raised.

  ## Options

  The `min_key` and `max_key` specify the range of entries that are selected. By
  default, the range is inclusive, so all entries that have a key greater or
  equal than `min_key` and less or equal then `max_key` are selected:

      # Select all entries where `"a" <= key <= "d"`
      CubDB.select(db, min_key: "b", max_key: "d")

  The range boundaries can be excluded by setting `min_key` or `max_key` to
  `{key, :excluded}`:

      # Select all entries where `"a" <= key < "d"`
      CubDB.select(db, min_key: "b", max_key: {"d", :excluded})

  Any of `:min_key` and `:max_key` can be omitted or set to `nil`, to leave the
  range open-ended.

      # Select entries where `key <= "a"
      CubDB.select(db, max_key: "a")

      # Or, equivalently:
      CubDB.select(db, min_key: nil, max_key: "a")

  In case the key boundary is the literal value `nil`, the longer form must be used:

      # Select entries where `nil <= key <= "a"`
      CubDB.select(db, min_key: {nil, :included}, max_key: "a")

  The `reverse` option, when set to true, causes the entries to be selected and
  traversed in reverse order.

  The `pipe` option specifies an optional list of operations performed
  sequentially on the selected entries. The given order of operations is
  respected. The available operations, specified as tuples, are:

    - `{:filter, fun}` filters entries for which `fun` returns a truthy value

    - `{:map, fun}` maps each entry to the value returned by the function `fun`

    - `{:take, n}` takes the first `n` entries

    - `{:drop, n}` skips the first `n` entries

    - `{:take_while, fun}` takes entries while `fun` returns a truthy value

    - `{:drop_while, fun}` skips entries while `fun` returns a truthy value

  Note that, when selecting a key range, specifying `min_key` and/or `max_key`
  is more performant than using `{:filter, fun}` or `{:take_while | :drop_while,
  fun}`, because `min_key` and `max_key` avoid loading unnecessary entries from
  disk entirely.

  The `reduce` option specifies how the selected entries are aggregated. If
  `reduce` is omitted, the entries are returned as a list. If `reduce` is a
  function, it is used to reduce the collection of entries. If `reduce` is a
  tuple, the first element is the starting value of the reduction, and the
  second is the reducing function.

  ## Examples

  To select all entries with keys between `:a` and `:c` as a list of `{key,
  value}` entries we can do:

      {:ok, entries} = CubDB.select(db, min_key: :a, max_key: :c)

  If we want to get all entries with keys between `:a` and `:c`, with `:c`
  exluded, we can do:

      {:ok, entries} = CubDB.select(db, min_key: :a, max_key: {:c, :excluded})

  To select the last 3 entries, we can do:

      {:ok, entries} = CubDB.select(db, reverse: true, pipe: [take: 3])

  If we want to obtain the sum of the first 10 positive numeric values
  associated to keys from `:a` to `:f`, we can do:

      {:ok, sum} = CubDB.select(db,
        min_key: :a,
        max_key: :f,
        pipe: [
          map: fn {_key, value} -> value end, # map values
          filter: fn n -> is_number(n) and n > 0 end # only positive numbers
          take: 10, # take only the first 10 entries in the range
        ],
        reduce: fn n, sum -> sum + n end # reduce to the sum of selected values
      )
  """
  def select(db, options \\ [], timeout \\ 5000) when is_list(options) do
    GenServer.call(db, {:select, options}, timeout)
  end

  @spec size(GenServer.server()) :: pos_integer

  @doc """
  Returns the number of entries present in the database.
  """
  def size(db) do
    GenServer.call(db, :size)
  end

  @spec dirt_factor(GenServer.server()) :: float

  @doc """
  Returns the dirt factor.

  The dirt factor is a number, ranging from 0 to 1, giving an indication about
  the amount of overhead storage (or "dirt") that can be cleaned up with a
  compaction operation. A value of 0 means that there is no overhead, so a
  compaction would have no benefit. The closer to 1 the dirt factor is, the more
  can be cleaned up in a compaction operation.
  """
  def dirt_factor(db) do
    GenServer.call(db, :dirt_factor)
  end

  @spec put(GenServer.server(), key, value) :: :ok

  @doc """
  Writes an entry in the database, associating `key` to `value`.

  If `key` was already present, it is overwritten.
  """
  def put(db, key, value) do
    GenServer.call(db, {:put, key, value})
  end

  @spec delete(GenServer.server(), key) :: :ok

  @doc """
  Deletes the entry associated to `key` from the database.

  If `key` was not present in the database, nothing is done.
  """
  def delete(db, key) do
    GenServer.call(db, {:delete, key})
  end

  @spec update(GenServer.server(), key, value, (value -> value)) :: :ok

  @doc """
  Updates the entry corresponding to `key` using the given function.

  If `key` is present in the database, `fun` is invoked with the corresponding
  `value`, and the result is set as the new value of `key`. If `key` is not
  found, `initial` is inserted as the value of `key`.

  The return value is `:ok`, or `{:error, reason}` in case an error occurs.
  """
  def update(db, key, initial, fun) do
    with {:ok, nil} <-
           get_and_update_multi(db, [key], fn entries ->
             case Map.fetch(entries, key) do
               :error ->
                 {nil, %{key => initial}, []}

               {:ok, value} ->
                 {nil, %{key => fun.(value)}, []}
             end
           end),
         do: :ok
  end

  @spec get_and_update(GenServer.server(), key, (value -> {any, value} | :pop)) :: {:ok, any}

  @doc """
  Gets the value corresponding to `key` and updates it, in one atomic transaction.

  `fun` is called with the current value associated to `key` (or `nil` if not
  present), and must return a two element tuple: the result value to be
  returned, and the new value to be associated to `key`. `fun` mayalso return
  `:pop`, in which case the current value is deleted and returned.

  The return value is `{:ok, result}`, or `{:error, reason}` in case an error occurs.
  """
  def get_and_update(db, key, fun) do
    with {:ok, result} <-
           get_and_update_multi(db, [key], fn entries ->
             value = Map.get(entries, key, nil)

             case fun.(value) do
               {result, new_value} -> {result, %{key => new_value}, []}
               :pop -> {value, %{}, [key]}
             end
           end),
         do: {:ok, result}
  end

  @spec get_and_update_multi(
          GenServer.server(),
          list(key),
          (%{optional(key) => value} -> {any, %{optional(key) => value} | nil, list(key) | nil}),
          timeout
        ) :: {:ok, any} | {:error, any}

  @doc """
  Gets and updates or deletes multiple entries in an atomic transaction.

  Gets all values associated with keys in `keys_to_get`, and passes them as a
  map of `%{key => value}` entries to `fun`. If a key is not found, it won't be
  added to the map passed to `fun`. Updates the database and returns a result
  according to the return value of `fun`. Returns {`:ok`, return_value} in case
  of success, `{:error, reason}` otherwise.

  The function `fun` should return a tuple of three elements: `{return_value,
  entries_to_put, keys_to_delete}`, where `return_value` is an arbitrary value
  to be returned, `entries_to_put` is a map of `%{key => value}` entries to be
  written to the database, and `keys_to_delete` is a list of keys to be deleted.

  The optional `timeout` argument specifies a timeout in milliseconds, which is
  `5000` (5 seconds) by default.

  The read and write operations are executed as an atomic transaction, so they
  will either all succeed, or all fail. Note that `get_and_update_multi/4`
  blocks other write operations until it completes.

  ## Example

  Assuming a database of names as keys, and integer monetary balances as values,
  and we want to transfer 10 units from `"Anna"` to `"Joy"`, returning their
  updated balance:

      {:ok, {anna, joy}} = CubDB.get_and_update_multi(db, ["Anna", "Joy"], fn entries ->
        anna = Map.get(entries, "Anna", 0)
        joy = Map.get(entries, "Joy", 0)

        if anna < 10, do: raise(RuntimeError, message: "Anna's balance is too low")

        anna = anna - 10
        joy = joy + 10

        {{anna, joy}, %{"Anna" => anna, "Joy" => joy}, []}
      end)

  Or, if we want to transfer all of the balance from `"Anna"` to `"Joy"`,
  deleting `"Anna"`'s entry, and returning `"Joy"`'s resulting balance:

      {:ok, joy} = CubDB.get_and_update_multi(db, ["Anna", "Joy"], fn entries ->
        anna = Map.get(entries, "Anna", 0)
        joy = Map.get(entries, "Joy", 0)

        joy = joy + anna

        {joy, %{"Joy" => joy}, ["Anna"]}
      end)
  """
  def get_and_update_multi(db, keys_to_get, fun, timeout \\ 5000) do
    GenServer.call(db, {:get_and_update_multi, keys_to_get, fun}, timeout)
  end

  @spec compact(GenServer.server()) :: :ok | {:error, binary}

  @doc """
  Runs a database compaction.

  As write operations are performed on a database, its file grows. Occasionally,
  a compaction operation can be run to shrink the file to its optimal size.
  Compaction runs in the background and does not block operations.

  Only one compaction operation can run at any time, therefore if this function
  is called when a compaction is already running, it returns `{:error,
  :pending_compaction}`.

  When compacting, `CubDB` will create a new data file, and eventually switch to
  it and remove the old one as the compaction succeeds. For this reason, during
  a compaction, there should be enough disk space for a second copy of the
  database file.

  Compaction can create disk contention, so it should not be performed
  unnecessarily often.
  """
  def compact(db) do
    GenServer.call(db, :compact)
  end

  @spec set_auto_compact(GenServer.server(), boolean | {integer, integer | float}) ::
          :ok | {:error, binary}

  @doc """
  Set whether to perform automatic compaction, and how.

  If set to `false`, no automatic compaction is performed. If set to `true`,
  auto-compaction is performed, following a write operation, if at least 100
  write operations occurred since the last compaction, and the dirt factor is at
  least 0.2. These values can be customized by setting the `auto_compact` option
  to `{min_writes, min_dirt_factor}`.

  It returns `:ok`, or `{:error, reason}` if `setting` is invalid.

  Compaction is performed in the background and does not block other operations,
  but can create disk contention, so it should not be performed unnecessarily
  often. When writing a lot into the database, such as when importing data from
  an external source, it is adviseable to turn off auto compaction, and manually
  run compaction at the end of the import.
  """
  def set_auto_compact(db, setting) do
    GenServer.call(db, {:set_auto_compact, setting})
  end

  @spec cubdb_file?(binary) :: boolean

  @doc false
  def cubdb_file?(file_name) do
    file_extensions = [@db_file_extension, @compaction_file_extension]
    Enum.member?(file_extensions, Path.extname(file_name))
  end

  @spec db_file?(binary) :: boolean

  @doc false
  def db_file?(file_name) do
    Path.extname(file_name) == @db_file_extension
  end

  @spec compaction_file?(binary) :: boolean

  @doc false
  def compaction_file?(file_name) do
    Path.extname(file_name) == @compaction_file_extension
  end

  @doc false
  def subscribe(db) do
    GenServer.call(db, {:subscribe, self()})
  end

  # OTP callbacks

  @doc false
  def init([data_dir, options]) do
    auto_compact = parse_auto_compact!(Keyword.get(options, :auto_compact, false))

    case find_db_file(data_dir) do
      file_name when is_binary(file_name) or is_nil(file_name) ->
        store = Store.File.new(Path.join(data_dir, file_name || "0#{@db_file_extension}"))
        {:ok, clean_up} = CleanUp.start_link(data_dir)

        {:ok,
         %State{
           btree: Btree.new(store),
           data_dir: data_dir,
           clean_up: clean_up,
           auto_compact: auto_compact
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  def handle_call(operation = {:get, _, _}, from, state = %State{btree: btree}) do
    state = read(from, btree, operation, state)
    {:noreply, state}
  end

  def handle_call(operation = {:fetch, _}, from, state = %State{btree: btree}) do
    state = read(from, btree, operation, state)
    {:noreply, state}
  end

  def handle_call(operation = {:has_key?, _}, from, state = %State{btree: btree}) do
    state = read(from, btree, operation, state)
    {:noreply, state}
  end

  def handle_call(operation = {:select, _}, from, state = %State{btree: btree}) do
    state = read(from, btree, operation, state)
    {:noreply, state}
  end

  def handle_call(:size, _, state = %State{btree: btree}) do
    {:reply, Enum.count(btree), state}
  end

  def handle_call(:dirt_factor, _, state = %State{btree: btree}) do
    {:reply, Btree.dirt_factor(btree), state}
  end

  def handle_call({:put, key, value}, _, state = %State{btree: btree}) do
    btree = Btree.insert(btree, key, value)
    {:reply, :ok, maybe_auto_compact(%State{state | btree: btree})}
  end

  def handle_call({:delete, key}, _, state = %State{btree: btree, compactor: compactor}) do
    btree =
      case compactor do
        nil -> Btree.delete(btree, key)
        _ -> Btree.mark_deleted(btree, key)
      end

    {:reply, :ok, maybe_auto_compact(%State{state | btree: btree})}
  end

  def handle_call({:get_and_update_multi, keys_to_get, fun}, _, state) do
    %State{btree: btree, compactor: compactor} = state

    key_values =
      Enum.reduce(keys_to_get, %{}, fn key, map ->
        case Btree.has_key?(btree, key) do
          {true, value} -> Map.put(map, key, value)
          {false, _} -> map
        end
      end)

    {result, entries_to_put, keys_to_delete} = fun.(key_values)

    btree =
      Enum.reduce(entries_to_put || [], btree, fn {key, value}, btree ->
        Btree.insert(btree, key, value, false)
      end)

    btree =
      Enum.reduce(keys_to_delete || [], btree, fn key, btree ->
        case compactor do
          nil -> Btree.delete(btree, key)
          _ -> Btree.mark_deleted(btree, key)
        end
      end)

    state = %State{state | btree: Btree.commit(btree)}

    {:reply, {:ok, result}, maybe_auto_compact(state)}
  rescue
    error -> {:reply, {:error, error}, state}
  end

  def handle_call(:compact, _, state) do
    reply = trigger_compaction(state)

    case reply do
      {:ok, compactor} -> {:reply, :ok, %State{state | compactor: compactor}}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:set_auto_compact, setting}, _, state) do
    case parse_auto_compact(setting) do
      {:ok, setting} -> {:reply, :ok, %State{state | auto_compact: setting}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:subscribe, pid}, _, state = %State{subs: subs}) do
    {:reply, :ok, %State{state | subs: [pid | subs]}}
  end

  def handle_info({:compaction_completed, original_btree, compacted_btree}, state) do
    for pid <- state.subs, do: send(pid, :compaction_completed)
    send(self(), {:catch_up, compacted_btree, original_btree})
    {:noreply, state}
  end

  def handle_info({:catch_up, compacted_btree, original_btree}, state) do
    %State{btree: latest_btree} = state

    if latest_btree == original_btree do
      compacted_btree = finalize_compaction(compacted_btree)
      state = %State{state | btree: compacted_btree, compactor: nil}
      for pid <- state.subs, do: send(pid, :catch_up_completed)
      {:noreply, trigger_clean_up(state)}
    else
      CatchUp.start_link(self(), compacted_btree, original_btree, latest_btree)
      {:noreply, state}
    end
  end

  def handle_info({:check_out_reader, btree}, state = %State{clean_up_pending: clean_up_pending}) do
    state = check_out_reader(btree, state)

    state =
      if clean_up_pending == true,
        do: trigger_clean_up(state),
        else: state

    {:noreply, state}
  end

  defp read(from, btree, operation, state) do
    Reader.start_link(from, self(), btree, operation)
    check_in_reader(btree, state)
  end

  defp find_db_file(data_dir) do
    with :ok <- File.mkdir_p(data_dir),
         {:ok, files} <- File.ls(data_dir) do
      files
      |> Enum.filter(&String.ends_with?(&1, @db_file_extension))
      |> Enum.sort()
      |> List.last()
    end
  end

  defp trigger_compaction(state = %State{btree: btree, data_dir: data_dir, clean_up: clean_up}) do
    case can_compact?(state) do
      true ->
        for pid <- state.subs, do: send(pid, :compaction_started)
        {:ok, store} = new_compaction_store(data_dir)
        CleanUp.clean_up_old_compaction_files(clean_up, store)
        Compactor.start_link(self(), btree, store)

      {false, reason} ->
        {:error, reason}
    end
  end

  defp finalize_compaction(%Btree{store: %Store.File{file_path: file_path}}) do
    new_path = String.replace_suffix(file_path, @compaction_file_extension, @db_file_extension)
    :ok = File.rename(file_path, new_path)

    store = Store.File.new(new_path)
    Btree.new(store)
  end

  defp new_compaction_store(data_dir) do
    with {:ok, file_names} <- File.ls(data_dir) do
      new_filename =
        file_names
        |> Enum.filter(&cubdb_file?/1)
        |> Enum.map(fn file_name -> Path.basename(file_name, Path.extname(file_name)) end)
        |> Enum.sort()
        |> List.last()
        |> String.to_integer(16)
        |> (&(&1 + 1)).()
        |> Integer.to_string(16)
        |> (&(&1 <> @compaction_file_extension)).()

      store = Store.File.new(Path.join(data_dir, new_filename))
      {:ok, store}
    end
  end

  defp can_compact?(%State{compactor: compactor}) do
    case compactor do
      nil -> true
      _ -> {false, :pending_compaction}
    end
  end

  defp check_in_reader(%Btree{store: store}, state = %State{busy_files: busy_files}) do
    %Store.File{file_path: file_path} = store
    busy_files = Map.update(busy_files, file_path, 1, &(&1 + 1))
    %State{state | busy_files: busy_files}
  end

  defp check_out_reader(%Btree{store: store}, state = %State{busy_files: busy_files}) do
    %Store.File{file_path: file_path} = store

    busy_files =
      case Map.get(busy_files, file_path) do
        n when n > 1 -> Map.update!(busy_files, file_path, &(&1 - 1))
        _ -> Map.delete(busy_files, file_path)
      end

    %State{state | busy_files: busy_files}
  end

  defp trigger_clean_up(state) do
    if can_clean_up?(state),
      do: clean_up_now(state),
      else: clean_up_when_possible(state)
  end

  defp can_clean_up?(%State{btree: %Btree{store: store}, busy_files: busy_files}) do
    %Store.File{file_path: file_path} = store
    Enum.any?(busy_files, fn {file, _} -> file != file_path end) == false
  end

  defp clean_up_now(state = %State{btree: btree, clean_up: clean_up}) do
    :ok = CleanUp.clean_up(clean_up, btree)
    %State{state | clean_up_pending: false}
  end

  defp clean_up_when_possible(state) do
    %State{state | clean_up_pending: true}
  end

  defp maybe_auto_compact(state) do
    if should_auto_compact?(state) do
      case trigger_compaction(state) do
        {:ok, compactor} -> %State{state | compactor: compactor}
        {:error, _} -> state
      end
    else
      state
    end
  end

  defp should_auto_compact?(%State{auto_compact: false}), do: false

  defp should_auto_compact?(%State{btree: btree, auto_compact: auto_compact}) do
    {min_writes, min_dirt_factor} = auto_compact
    %Btree{dirt: dirt} = btree
    dirt_factor = Btree.dirt_factor(btree)
    dirt >= min_writes and dirt_factor >= min_dirt_factor
  end

  defp parse_auto_compact(setting) do
    case setting do
      false ->
        {:ok, false}

      true ->
        {:ok, @auto_compact_defaults}

      {min_writes, min_dirt_factor} when is_integer(min_writes) and is_number(min_dirt_factor) ->
        if min_writes >= 0 and min_dirt_factor >= 0 and min_dirt_factor <= 1,
          do: {:ok, {min_writes, min_dirt_factor}},
          else: {:error, "invalid auto compact setting"}

      _ ->
        {:error, "invalid auto compact setting"}
    end
  end

  defp parse_auto_compact!(setting) do
    case parse_auto_compact(setting) do
      {:ok, setting} -> setting
      {:error, reason} -> raise(ArgumentError, message: reason)
    end
  end
end
