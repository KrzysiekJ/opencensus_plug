defmodule Opencensus.Plug.Trace do
  @moduledoc """
  Template method for creating `Plug` to trace your `Plug` requests.

  ## Usage

  1. Create your own `Plug` module:

    ```elixir
    defmodule MyApp.TracingPlug do
      use Opencensus.Plug.Trace
    end
    ```

  2. Add it to your pipeline, ex. for Phoenix:

    ```elixir
    defmodule MyAppWeb.Endpoint do
      use Phoenix.Endpoint, otp_app: :my_app

      plug MyApp.TracingPlug
    end
    ```

  ## Configuration

  This module creates 2 callback modules, which allows you to configure your
  span and also provides a way to add custom attributes assigned to span.

  - `c:span_name/1` - defaults to request path
  - `c:span_status/1` - defaults to mapping of reponse code to OpenCensus span
    value, see `:opencensus.http_status_to_trace_status/1`.

  And also you can use `attributes` argument in `use` which must be either list
  of attributes which are names of 1-argument functions in current module that
  must return string value of the attribute, or map/keyword list of one of:

  - `atom` - which is name of the called function
  - `{module, function}` - which will call `apply(module, function, [conn])`
  - `{module, function, args}` - which will prepend `conn` to the given arguments
    and call `apply(module, function, [conn | args])`


  Example:

  ```elixir
  defmodule MyAppWeb.TraceWithCustomAttribute do
    use Opencensus.Plug.Trace, attributes: [:method]

    def method(conn), do: conn.method
  end
  ```
  """

  @enforce_keys [:span_name, :tags, :conn_fields]
  defstruct @enforce_keys

  @doc """
  Return name for current span. By defaut returns `"plug"`
  """
  @callback span_name(Plug.Conn.t()) :: String.t()

  @doc """
  Return tuple containing span status and message. By default return value
  status assigned by [default mapping](https://opencensus.io/tracing/span/status/)
  and empty message.
  """
  @callback span_status(Plug.Conn.t()) :: {integer(), String.t()}

  defmacro __using__(opts) do
    attributes = Keyword.get(opts, :attributes, [])

    quote do
      @behaviour Plug
      @behaviour unquote(__MODULE__)

      def init(opts), do: opts

      def call(conn, _opts) do
        header = :oc_span_ctx_header.field_name()
        :ok = unquote(__MODULE__).load_ctx(conn, header)
        attributes = Opencensus.Plug.get_tags(conn, __MODULE__, unquote(attributes))

        _ = :ocp.with_child_span(span_name(conn), attributes)
        ctx = :ocp.current_span_ctx()

        :ok = unquote(__MODULE__).set_logger_metadata(ctx)

        conn
        |> unquote(__MODULE__).put_ctx_resp_header(header, ctx)
        |> Plug.Conn.register_before_send(fn conn ->
          {status, msg} = span_status(conn)

          :oc_trace.set_status(ctx, status, msg)
          :oc_trace.finish_span(ctx)

          conn
        end)
      end

      def span_name(conn), do: conn.request_path

      def span_status(conn),
        do: {:opencensus.http_status_to_trace_status(conn.status), ""}

      defoverridable span_name: 1, span_status: 1
    end
  end

  ## PRIVATE

  require Record

  Record.defrecordp(
    :ctx,
    Record.extract(:span_ctx, from_lib: "opencensus/include/opencensus.hrl")
  )

  @doc false
  def set_logger_metadata(span) do
    trace_id = List.to_string(:io_lib.format("~32.16.0b", [ctx(span, :trace_id)]))
    span_id = List.to_string(:io_lib.format("~16.16.0b", [ctx(span, :span_id)]))

    Logger.metadata(
      trace_id: trace_id,
      span_id: span_id,
      trace_options: ctx(span, :trace_options)
    )

    :ok
  end

  @doc false
  def put_ctx_resp_header(conn, header, ctx) do
    encoded =
      ctx
      |> :oc_span_ctx_header.encode()
      |> List.to_string()

    Plug.Conn.put_resp_header(conn, String.downcase(header), encoded)
  end

  @doc false
  def load_ctx(conn, header) do
    with [val] <- Plug.Conn.get_req_header(conn, header),
         ctx when ctx != :undefined <- :oc_span_ctx_header.decode(val) do
      require Logger
      :ocp.with_span_ctx(ctx)
    end

    :ok
  end
end
