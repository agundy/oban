defmodule Oban.Queue.Producer do
  @moduledoc false

  use GenServer

  alias Oban.{Breaker, Config, Notifier, Query}
  alias Oban.Queue.Executor

  @type option ::
          {:name, module()}
          | {:conf, Config.t()}
          | {:foreman, GenServer.name()}
          | {:limit, pos_integer()}
          | {:queue, binary()}

  defmodule State do
    @moduledoc false

    @enforce_keys [:conf, :foreman, :limit, :nonce, :queue]
    defstruct [
      :conf,
      :debounce_timer,
      :dispatched_at,
      :foreman,
      :limit,
      :name,
      :nonce,
      :queue,
      :started_at,
      dispatch_cooldown: 1,
      paused: false,
      running: %{}
    ]
  end

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @spec check(GenServer.name()) :: Oban.queue_state()
  def check(producer) do
    GenServer.call(producer, :check)
  end

  @spec pause(GenServer.name()) :: :ok
  def pause(producer) do
    GenServer.call(producer, :pause)
  end

  # Callbacks

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    opts =
      opts
      |> Keyword.put(:nonce, nonce())
      |> Keyword.put(:started_at, DateTime.utc_now())

    state =
      State
      |> struct!(opts)
      |> start_listener()

    {:ok, state}
  end

  @impl GenServer
  def handle_info({ref, _val}, %State{running: running} = state) do
    Process.demonitor(ref, [:flush])

    debounce_dispatch(%{state | running: Map.delete(running, ref)})
  end

  def handle_info({:DOWN, ref, :process, _pid, :shutdown}, %State{running: running} = state) do
    Process.demonitor(ref, [:flush])

    debounce_dispatch(%{state | running: Map.delete(running, ref)})
  end

  # This message is only received when the job's task doesn't exit cleanly. This should be rare,
  # but it can happen when nested processes crash.
  def handle_info({:DOWN, ref, :process, _pid, {reason, stack}}, %State{} = state) do
    %State{foreman: foreman, running: running} = state

    {{exec, _pid}, running} = Map.pop(running, ref)

    # Without this we may crash the producer if there are any db errors. Alternatively, we would
    # block the producer while awaiting a retry.
    Task.Supervisor.async_nolink(foreman, fn ->
      Breaker.with_retry(fn ->
        %{exec | kind: :error, error: reason, stacktrace: stack, state: :failure}
        |> Executor.record_finished()
        |> Executor.report_finished()
      end)
    end)

    debounce_dispatch(%{state | running: running})
  end

  def handle_info(:dispatch, %State{} = state) do
    {:noreply, %{dispatch(state) | debounce_timer: nil}}
  end

  def handle_info({:notification, :insert, %{"queue" => queue}}, %State{queue: queue} = state) do
    debounce_dispatch(state)
  end

  def handle_info({:notification, :signal, payload}, %State{queue: queue} = state) do
    state =
      case payload do
        %{"action" => "pause", "queue" => ^queue} ->
          %{state | paused: true}

        %{"action" => "resume", "queue" => ^queue} ->
          %{state | paused: false}

        %{"action" => "scale", "queue" => ^queue, "limit" => limit} ->
          %{state | limit: limit}

        %{"action" => "pkill", "job_id" => jid} ->
          for {ref, {exec, pid}} <- state.running, exec.job.id == jid do
            pkill(ref, pid, state)
          end

          state

        _ ->
          state
      end

    debounce_dispatch(state)
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:check, _from, %State{conf: conf, running: running} = state) do
    running_ids = for {_ref, {exec, _pid}} <- running, do: exec.job.id

    args =
      state
      |> Map.take([:limit, :nonce, :paused, :queue, :started_at])
      |> Map.put(:node, conf.node)
      |> Map.put(:running, running_ids)

    {:reply, args, state}
  end

  def handle_call(:pause, _from, state) do
    {:reply, :ok, %{state | paused: true}}
  end

  # Start Handlers

  defp nonce(size \\ 8) when size > 0 do
    size
    |> :crypto.strong_rand_bytes()
    |> Base.hex_encode32(case: :lower)
    |> String.slice(0..(size - 1))
  end

  defp start_listener(%State{conf: conf} = state) do
    Notifier.listen(conf.name, [:insert, :signal])

    state
  end

  # Dispatching

  defp debounce_dispatch(%State{} = state) do
    if is_reference(state.debounce_timer) do
      {:noreply, state}
    else
      debounce_timer = Process.send_after(self(), :dispatch, state.dispatch_cooldown)

      {:noreply, %{state | debounce_timer: debounce_timer}}
    end
  end

  defp dispatch(%State{paused: true} = state) do
    state
  end

  defp dispatch(%State{limit: limit, running: running} = state) when map_size(running) >= limit do
    state
  end

  defp dispatch(%State{} = state) do
    meta = Map.take(state, [:conf, :queue])

    running =
      :telemetry.span([:oban, :producer], meta, fn ->
        dispatched =
          state
          |> fetch_jobs()
          |> start_jobs(state)

        stop_meta = Map.put(meta, :dispatched_count, map_size(dispatched))

        {Map.merge(dispatched, state.running), stop_meta}
      end)

    %{state | running: running}
  end

  defp fetch_jobs(%State{} = state) do
    queue_meta = %{
      queue: state.queue,
      nonce: state.nonce,
      limit: state.limit - map_size(state.running)
    }

    {:ok, jobs} = Query.fetch_jobs(state.conf, queue_meta)

    jobs
  end

  defp start_jobs(jobs, %State{conf: conf, foreman: foreman}) do
    for job <- jobs, into: %{} do
      exec = Executor.new(conf, job)

      %{pid: pid, ref: ref} = Task.Supervisor.async_nolink(foreman, Executor, :call, [exec])

      {ref, {exec, pid}}
    end
  end

  # Killing

  defp pkill(ref, pid, state) do
    %State{foreman: foreman, running: running} = state

    case DynamicSupervisor.terminate_child(foreman, pid) do
      :ok ->
        state

      {:error, :not_found} ->
        Process.demonitor(ref, [:flush])

        %{state | running: Map.delete(running, ref)}
    end
  end
end
