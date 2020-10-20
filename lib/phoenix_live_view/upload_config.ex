defmodule Phoenix.LiveView.UploadEntry do
  @moduledoc """
  The struct representing an upload entry.
  """

  alias Phoenix.LiveView.UploadEntry

  defstruct progress: 0,
            upload_config: nil,
            upload_ref: nil,
            ref: nil,
            valid?: false,
            done?: false,
            cancelled?: false,
            client_name: nil,
            client_size: nil,
            client_type: nil,
            client_last_modified: nil

  @type t :: %__MODULE__{
          progress: integer(),
          upload_config: String.t() | :atom,
          upload_ref: String.t(),
          ref: String.t() | nil,
          valid?: boolean(),
          done?: boolean(),
          cancelled?: boolean(),
          client_name: String.t() | nil,
          client_size: integer() | nil,
          client_type: String.t() | nil,
          client_last_modified: integer() | nil
        }

  @doc false
  def put_progress(%UploadEntry{} = entry, 100) do
    %UploadEntry{entry | progress: 100, done?: true}
  end

  def put_progress(%UploadEntry{} = entry, progress) do
    %UploadEntry{entry | progress: progress}
  end
end

defmodule Phoenix.LiveView.UploadConfig do
  @moduledoc """
  The struct representing an upload.
  """

  alias Phoenix.LiveView.UploadConfig
  alias Phoenix.LiveView.UploadEntry

  @default_max_file_size 8_000_000
  @default_chunk_size 64_000
  @default_chunk_timeout 10_000

  @unregistered :unregistered
  @invalid :invalid

  @too_many_files :too_many_files

  if Version.match?(System.version(), ">= 1.8.0") do
    @derive {Inspect,
             only: [:name, :ref, :entries, :max_entries, :max_file_size, :accept, :errors]}
  end

  defstruct name: nil,
            client_key: nil,
            max_entries: 1,
            max_file_size: @default_max_file_size,
            chunk_size: @default_chunk_size,
            chunk_timeout: @default_chunk_timeout,
            entries: [],
            entry_refs_to_pids: %{},
            entry_refs_to_metas: %{},
            accept: [],
            acceptable_types: MapSet.new(),
            acceptable_exts: MapSet.new(),
            external: false,
            allowed?: false,
            ref: nil,
            errors: []

  @type t :: %__MODULE__{
          name: atom(),
          client_key: String.t(),
          max_entries: pos_integer(),
          max_file_size: pos_integer(),
          entries: list(),
          entry_refs_to_pids: %{String.t() => pid() | :unregistered | :done},
          entry_refs_to_metas: %{String.t() => map()},
          accept: list() | :any,
          acceptable_types: MapSet.t(),
          acceptable_exts: MapSet.t(),
          external: (Socket.t() -> Socket.t()) | false,
          allowed?: boolean,
          errors: list(),
          ref: String.t()
        }

  @doc false
  # we require a random_ref in order to ensure unique calls to `allow_upload`
  # invalidate old uploads on the client and expire old tokens for the same
  # upload name
  def build(name, random_ref, [_ | _] = opts) when is_atom(name) do
    {raw_accept, acceptable_types, acceptable_exts} =
      case Keyword.fetch(opts, :accept) do
        {:ok, [_ | _] = accept} ->
          {types, exts} = validate_accept_option(accept)
          {accept, types, exts}

        {:ok, :any} ->
          {:any, MapSet.new(), MapSet.new()}

        {:ok, other} ->
          raise ArgumentError, """
          invalid accept filter provided to allow_upload.

          A list of the following unique file type specifiers are supported:

            * A valid case-insensitive filename extension, starting with a period (".") character.
              For example: .jpg, .pdf, or .doc.

            * A valid MIME type string, with no extensions.

          Alternately, you can provide the atom :any to allow any kind of file. Got:

          #{inspect(other)}
          """

        :error ->
          raise ArgumentError, """
          the :accept option is required when allowing uploads.

          Provide a list of unique file type specifiers or the atom :any to allow any kind of file.
          """
      end

    external =
      case Keyword.fetch(opts, :external) do
        {:ok, func} when is_function(func, 2) ->
          func

        {:ok, other} ->
          raise ArgumentError, """
          invalid :external value provided to allow_upload.

          Only an anymous function receiving the socket as an argument is supported. Got:

          #{inspect(other)}
          """

        :error ->
          false
      end

    max_file_size =
      case Keyword.fetch(opts, :max_file_size) do
        {:ok, pos_integer} when is_integer(pos_integer) and pos_integer > 0 ->
          pos_integer

        {:ok, other} ->
          raise ArgumentError, """
          invalid :max_file_size value provided to allow_upload.

          Only a positive integer is supported (Defaults to #{@default_max_file_size} bytes). Got:

          #{inspect(other)}
          """

        :error ->
          @default_max_file_size
      end

    chunk_size =
      case Keyword.fetch(opts, :chunk_size) do
        {:ok, pos_integer} when is_integer(pos_integer) and pos_integer > 0 ->
          pos_integer

        {:ok, other} ->
          raise ArgumentError, """
          invalid :chunk_size value provided to allow_upload.

          Only a positive integer is supported (Defaults to #{@default_chunk_size} bytes). Got:

          #{inspect(other)}
          """

        :error ->
          @default_chunk_size
      end

    chunk_timeout =
      case Keyword.fetch(opts, :chunk_timeout) do
        {:ok, pos_integer} when is_integer(pos_integer) and pos_integer > 0 ->
          pos_integer

        {:ok, other} ->
          raise ArgumentError, """
          invalid :chunk_timeout value provided to allow_upload.

          Only a positive integer in milliseconds is supported (Defaults to #{
            @default_chunk_timeout
          } ms). Got:

          #{inspect(other)}
          """

        :error ->
          @default_chunk_timeout
      end

    %UploadConfig{
      ref: random_ref,
      name: name,
      max_entries: opts[:max_entries] || 1,
      max_file_size: max_file_size,
      entry_refs_to_pids: %{},
      entry_refs_to_metas: %{},
      accept: raw_accept,
      acceptable_types: acceptable_types,
      acceptable_exts: acceptable_exts,
      external: external,
      chunk_size: chunk_size,
      chunk_timeout: chunk_timeout,
      allowed?: true
    }
  end

  @doc false
  def entry_pid(%UploadConfig{} = conf, %UploadEntry{} = entry) do
    case Map.fetch(conf.entry_refs_to_pids, entry.ref) do
      {:ok, pid} when is_pid(pid) -> pid
      {:ok, status} when status in [@unregistered, @invalid] -> nil
    end
  end

  @doc false
  def get_entry_by_pid(%UploadConfig{} = conf, channel_pid) when is_pid(channel_pid) do
    Enum.find_value(conf.entry_refs_to_pids, fn {ref, pid} ->
      if channel_pid == pid do
        get_entry_by_ref(conf, ref)
      end
    end)
  end

  @doc false
  def get_entry_by_ref(%UploadConfig{} = conf, ref) do
    Enum.find(conf.entries, fn %UploadEntry{} = entry -> entry.ref === ref end)
  end

  @doc false
  def unregister_completed_external_entry(%UploadConfig{} = conf, entry_ref) do
    %UploadEntry{} = entry = get_entry_by_ref(conf, entry_ref)

    drop_entry(conf, entry)
  end

  @doc false
  def unregister_completed_entry(%UploadConfig{} = conf, channel_pid) when is_pid(channel_pid) do
    %UploadEntry{} = entry = get_entry_by_pid(conf, channel_pid)

    drop_entry(conf, entry)
  end

  @doc false
  def registered?(%UploadConfig{} = conf) do
    Enum.find(conf.entry_refs_to_pids, fn {_ref, maybe_pid} -> is_pid(maybe_pid) end)
  end

  @doc false
  def register_entry_upload(%UploadConfig{} = conf, channel_pid, entry_ref)
      when is_pid(channel_pid) do
    case Map.fetch(conf.entry_refs_to_pids, entry_ref) do
      {:ok, @unregistered} ->
        {:ok,
         %UploadConfig{
           conf
           | entry_refs_to_pids: Map.put(conf.entry_refs_to_pids, entry_ref, channel_pid)
         }}

      {:ok, existing_pid} when is_pid(existing_pid) ->
        {:error, :already_registered}

      :error ->
        {:error, :disallowed}
    end
  end

  # specifics on the `accept` attribute are illuminated in the spec:
  # https://html.spec.whatwg.org/multipage/input.html#attr-input-accept
  @accept_wildcards ~w(audio/* image/* video/*)

  defp validate_accept_option(accept) do
    {types, exts} =
      Enum.reduce(accept, {[], []}, fn opt, {types_acc, exts_acc} ->
        {type, exts} = accept_option!(opt)
        {[type | types_acc], exts ++ exts_acc}
      end)

    {MapSet.new(types), MapSet.new(exts)}
  end

  # wildcards for media files
  defp accept_option!(key) when key in @accept_wildcards, do: {key, []}

  defp accept_option!(<<"." <> extname::binary>> = ext) do
    if MIME.has_type?(extname) do
      {MIME.type(extname), [ext]}
    else
      raise ArgumentError, """
        invalid accept filter provided to allow_upload.

        Expected a file extension with a known MIME type.

        MIME types can be extended in your application configuration as follows:

        config :mime, :types, %{
          "application/vnd.api+json" => ["json-api"]
        }

        Got:

        #{inspect(extname)}
      """
    end
  end

  defp accept_option!(filter) when is_binary(filter) do
    if MIME.valid?(filter) do
      {filter, []}
    else
      raise ArgumentError, """
        invalid accept filter provided to allow_upload.

        Expected a known MIME type without parameters.

        MIME types can be extended in your application configuration as follows:

        config :mime, :types, %{
          "application/vnd.api+json" => ["json-api"]
        }

        Got:

        #{inspect(filter)}
      """
    end
  end

  @doc false
  def disallow(%UploadConfig{} = conf), do: %UploadConfig{conf | allowed?: false}

  @doc false
  def uploaded_entries(%UploadConfig{} = conf) do
    Enum.filter(conf.entries, fn %UploadEntry{} = entry -> entry.progress == 100 end)
  end

  @doc false
  def update_entry(%UploadConfig{} = conf, entry_ref, func) do
    new_entries =
      Enum.map(conf.entries, fn
        %UploadEntry{ref: ^entry_ref} = entry -> func.(entry)
        %UploadEntry{ref: _ef} = entry -> entry
      end)

    recalculate_computed_fields(%UploadConfig{conf | entries: new_entries})
  end

  @doc false
  def update_progress(%UploadConfig{} = conf, entry_ref, progress)
      when is_integer(progress) and progress >= 0 and progress <= 100 do
    update_entry(conf, entry_ref, fn entry -> UploadEntry.put_progress(entry, progress) end)
  end

  @doc false
  def update_entry_meta(%UploadConfig{} = conf, entry_ref, %{} = meta) do
    case Map.fetch(meta, :uploader) do
      {:ok, _} ->
        :noop

      :error ->
        raise ArgumentError,
              "external uploader metadata requires an :uploader key. Got: #{inspect(meta)}"
    end

    new_metas = Map.put(conf.entry_refs_to_metas, entry_ref, meta)
    %UploadConfig{conf | entry_refs_to_metas: new_metas}
  end

  @doc false
  def put_entries(%UploadConfig{} = conf, entries) do
    if registered?(conf) do
      raise ArgumentError, "cannot overwrite entries for an active upload"
    else
      do_put_entries(conf, entries)
    end
  end

  defp do_put_entries(%UploadConfig{} = conf, entries) do
    cleared_conf = clear_entries(conf)

    new_conf =
      Enum.reduce(entries, cleared_conf, fn client_entry, acc ->
        case cast_and_validate_entry(acc, client_entry) do
          {:ok, new_conf} -> new_conf
          {:error, new_conf} -> new_conf
        end
      end)

    if too_many_files?(new_conf) do
      {:error, put_error(new_conf, new_conf.ref, @too_many_files)}
    else
      case new_conf do
        %UploadConfig{errors: []} = new_conf ->
          {:ok, new_conf}

        %UploadConfig{errors: [_ | _]} = new_conf ->
          {:error, new_conf}
      end
    end
  end

  defp too_many_files?(%UploadConfig{entries: entries, max_entries: max}) do
    length(entries) > max
  end

  defp clear_entries(%UploadConfig{} = conf) do
    if registered?(conf),
      do: raise(ArgumentError, "an upload with active entries cannot be cleared")

    recalculate_computed_fields(%UploadConfig{conf | entries: [], errors: []})
  end

  defp cast_and_validate_entry(%UploadConfig{} = conf, %{"ref" => ref} = client_entry) do
    entry = %UploadEntry{
      ref: ref,
      upload_ref: conf.ref,
      upload_config: conf.name,
      client_name: Map.fetch!(client_entry, "name"),
      client_size: Map.fetch!(client_entry, "size"),
      client_type: Map.fetch!(client_entry, "type"),
      client_last_modified: Map.get(client_entry, "last_modified")
    }

    {:ok, entry}
    |> validate_max_file_size(conf)
    |> validate_accepted(conf)
    |> case do
      {:ok, entry} ->
        {:ok, put_valid_entry(conf, entry)}

      {:error, reason} ->
        {:error, put_invalid_entry(conf, entry, reason)}
    end
  end

  defp put_valid_entry(conf, entry) do
    entry = %UploadEntry{entry | valid?: true}
    new_pids = Map.put(conf.entry_refs_to_pids, entry.ref, @unregistered)
    new_metas = Map.put(conf.entry_refs_to_metas, entry.ref, %{})

    %UploadConfig{
      conf
      | entries: conf.entries ++ [entry],
        entry_refs_to_pids: new_pids,
        entry_refs_to_metas: new_metas
    }
  end

  defp put_invalid_entry(conf, entry, reason) do
    entry = %UploadEntry{entry | valid?: false}
    new_pids = Map.put(conf.entry_refs_to_pids, entry.ref, @invalid)
    new_metas = Map.put(conf.entry_refs_to_metas, entry.ref, %{})

    new_conf = %UploadConfig{
      conf
      | entries: conf.entries ++ [entry],
        entry_refs_to_pids: new_pids,
        entry_refs_to_metas: new_metas
    }

    put_error(new_conf, entry.ref, reason)
  end

  defp validate_max_file_size({:ok, %UploadEntry{client_size: size}}, %UploadConfig{
         max_file_size: max
       })
       when size > max or not is_integer(size),
       do: {:error, :too_large}

  defp validate_max_file_size({:ok, entry}, _conf), do: {:ok, entry}

  defp validate_accepted({:ok, %UploadEntry{} = entry}, conf) do
    if accepted?(conf, entry) do
      {:ok, entry}
    else
      {:error, :not_accepted}
    end
  end

  defp validate_accepted({:error, _} = error, _conf), do: error

  defp accepted?(%UploadConfig{accept: :any}, %UploadEntry{}), do: true

  defp accepted?(
         %UploadConfig{acceptable_types: acceptable_types} = conf,
         %UploadEntry{client_type: client_type} = entry
       ) do
    cond do
      # wildcard
      String.starts_with?(client_type, "image/") and "image/*" in acceptable_types -> true
      String.starts_with?(client_type, "audio/") and "audio/*" in acceptable_types -> true
      String.starts_with?(client_type, "video/") and "video/*" in acceptable_types -> true
      # strict
      client_type in acceptable_types -> true
      Path.extname(entry.client_name) in conf.acceptable_exts -> true
      true -> false
    end
  end

  defp recalculate_computed_fields(%UploadConfig{} = conf) do
    recalculate_errors(conf)
  end

  defp recalculate_errors(%UploadConfig{ref: ref} = conf) do
    if too_many_files?(conf) do
      conf
    else
      new_errors =
        Enum.filter(conf.errors, fn
          {^ref, @too_many_files} -> false
          _ -> true
        end)

      %UploadConfig{conf | errors: new_errors}
    end
  end

  @doc false
  def put_error(%UploadConfig{} = conf, _entry_ref, @too_many_files = reason) do
    %UploadConfig{conf | errors: Enum.uniq(conf.errors ++ [{conf.ref, reason}])}
  end

  def put_error(%UploadConfig{} = conf, entry_ref, reason) do
    %UploadConfig{conf | errors: conf.errors ++ [{entry_ref, reason}]}
  end

  @doc false
  def cancel_entry(%UploadConfig{} = conf, %UploadEntry{} = entry) do
    case entry_pid(conf, entry) do
      channel_pid when is_pid(channel_pid) ->
        Phoenix.LiveView.UploadChannel.cancel(channel_pid)

        update_entry(conf, entry.ref, fn entry -> %UploadEntry{entry | cancelled?: true} end)

      _ ->
        drop_entry(conf, entry)
    end
  end

  @doc false
  def drop_entry(%UploadConfig{} = conf, %UploadEntry{ref: ref}) do
    new_entries = for entry <- conf.entries, entry.ref != ref, do: entry
    new_errors = Enum.filter(conf.errors, fn {error_ref, _} -> error_ref != ref end)
    new_refs = Map.delete(conf.entry_refs_to_pids, ref)
    new_metas = Map.delete(conf.entry_refs_to_metas, ref)

    new_conf = %UploadConfig{
      conf
      | entries: new_entries,
        errors: new_errors,
        entry_refs_to_pids: new_refs,
        entry_refs_to_metas: new_metas
    }

    recalculate_computed_fields(new_conf)
  end
end
