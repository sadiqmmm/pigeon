defmodule Pigeon.FCM.Config do
  @moduledoc false

  defstruct key: nil,
            uri: 'fcm.googleapis.com',
            port: 443,
            name: nil

  @type t :: %__MODULE__{
    key: binary,
    name: term,
    port: pos_integer,
    uri: charlist,
  }

  @doc ~S"""
  Returns a new `FCM.Config` with given `opts`.

  ## Examples

      iex> Pigeon.FCM.Config.new(
      ...>   name: :test,
      ...>   key: "fcm_key",
      ...>   uri: 'test.server.example.com',
      ...>   port: 5228
      ...> )
      %Pigeon.FCM.Config{key: "fcm_key", name: :test,
      port: 5228, uri: 'test.server.example.com'}
  """
  def new(opts) when is_list(opts) do
    %__MODULE__{
      name: opts[:name],
      key: opts[:key],
      uri: Keyword.get(opts, :uri, 'fcm.googleapis.com'),
      port: Keyword.get(opts, :port, 443)
    }
  end
  def new(name) when is_atom(name) do
    Application.get_env(:pigeon, :fcm)[name]
    |> Map.to_list
    |> Keyword.put(:name, name)
    |> new()
  end
end

defimpl Pigeon.Configurable, for: Pigeon.FCM.Config do
  @moduledoc false

  require Logger

  alias Pigeon.FCM.{Config, ResultParser, NotificationResponse}

  @type sock :: {:sslsocket, any, pid | {any, any}}

  # Configurable Callbacks

  @spec worker_name(any) :: atom | nil
  def worker_name(%Config{name: name}), do: name

  @spec connect(any) :: {:ok, sock} | {:error, String.t}
  def connect(%Config{uri: uri} = config) do
    case connect_socket_options(config) do
      {:ok, options} ->
        Pigeon.Http2.Client.default().connect(uri, :https, options)
    end
  end

  def connect_socket_options(config) do
    opts = [
      {:active, :once},
      {:packet, :raw},
      {:reuseaddr, true},
      {:alpn_advertised_protocols, [<<"h2">>]},
      {:reconnect, false},
      :binary
    ]
    |> add_port(config)

    {:ok, opts}
  end

  def add_port(opts, %Config{port: 443}), do: opts
  def add_port(opts, %Config{port: port}), do: [{:port, port} | opts]

  def push_headers(%Config{key: key}, _notification, opts) do
    [
      {":method", "POST"},
      {":path", "/fcm/send"},
      {"authorization", "key=#{opts[:key] || key}"},
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]
  end

  def push_payload(_config, {_registration_ids, payload}, _opts) do
    payload
  end

  def handle_end_stream(_config,
                        %{body: body, status: status, error: nil},
                        {registration_ids, _payload},
                        on_response) do
    case status do
      200 ->
        result = Poison.decode!(body)
        parse_result(registration_ids, result, on_response)
      401 ->
        log_error("401", "Unauthorized")
        unless on_response == nil do on_response.({:error, :unauthorized}) end
      400 ->
        log_error("400", "Malformed JSON")
        unless on_response == nil do on_response.({:error, :malformed_json}) end
      code ->
        reason = parse_error(body)
        log_error(code, reason)
        unless on_response == nil do on_response.({:error, reason}) end
    end
  end
  def handle_end_stream(_config, %{error: _error}, _notif, nil), do: :ok
  def handle_end_stream(_config, %{error: _error}, _notif, on_response) do
    on_response.({:error, :unavailable})
  end

  @spec schedule_ping(any) :: no_return
  def schedule_ping(_config), do: :ok

  @spec reconnect?(any) :: boolean
  def reconnect?(_config), do: false

  def close(_config) do
  end

  # no on_response callback, ignore
  def parse_result(_, _, nil), do: :ok

  def parse_result(ids, %{"results" => results}, on_response) do
    ResultParser.parse(ids, results, on_response, %NotificationResponse{})
  end

  defp parse_error(data) do
    {:ok, response} = Poison.decode(data)
    response["reason"] |> Macro.underscore |> String.to_existing_atom
  end

  defp log_error(code, reason) do
    if Pigeon.debug_log?, do: Logger.error("#{reason}: #{code}")
  end
end
