defmodule Bandit.HTTP2.Handler do
  @moduledoc """
  An HTTP/2 handler. Responsible for:

  * Coordinating the parsing of frames & attendant error handling
  * Tracking connection state as represented by `Bandit.HTTP2.Connection` structs
  * Marshalling send requests from child streams into the parent connection for processing
  """

  use ThousandIsland.Handler

  alias Bandit.HTTP2.{Connection, Frame}

  @impl ThousandIsland.Handler
  def handle_connection(socket, state) do
    case Connection.init(socket, state.plug) do
      {:ok, connection} ->
        {:ok, :continue, state |> Map.merge(%{buffer: <<>>, connection: connection})}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @impl ThousandIsland.Handler
  def handle_data(data, socket, state) do
    (state.buffer <> data)
    |> Stream.unfold(&Frame.deserialize/1)
    |> Enum.reduce_while({:ok, :continue, state}, fn
      {:ok, nil}, {:ok, :continue, state} ->
        {:cont, {:ok, :continue, state}}

      {:ok, frame}, {:ok, :continue, state} ->
        case Connection.handle_frame(frame, socket, state.connection) do
          {:ok, :continue, connection} ->
            {:cont, {:ok, :continue, %{state | connection: connection}}}

          {:ok, :close, connection} ->
            {:halt, {:ok, :close, %{state | connection: connection}}}

          {:error, reason} ->
            {:halt, {:error, reason, state}}
        end

      {:more, rest}, {:ok, :continue, state} ->
        {:halt, {:ok, :continue, %{state | buffer: rest}}}

      {:error, stream_id, code, reason}, {:ok, :continue, state} ->
        case Connection.handle_error(stream_id, code, reason, socket, state.connection) do
          {:ok, :close, connection} ->
            {:halt, {:error, reason, %{state | connection: connection}}}
        end
    end)
  end

  def handle_info({:EXIT, pid, reason}, {socket, state}) do
    {:ok, connection} = Connection.stream_terminated(pid, reason, socket, state.connection)

    {:noreply, {socket, %{state | connection: connection}}}
  end
end
