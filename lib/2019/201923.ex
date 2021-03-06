defmodule Aoc201923 do
  alias __MODULE__.Intcode

  @nat_address 255

  def run do
    Aoc.output(&part1/0)
    Aoc.output(&part2/0)
  end

  defp part1 do
    initial_state()
    |> Stream.iterate(&run_next/1)
    |> Stream.map(& &1.nat)
    |> Stream.reject(&is_nil/1)
    |> Stream.map(fn [@nat_address, _x, y] -> y end)
    |> Enum.at(0)
  end

  defp part2 do
    initial_state()
    |> Stream.iterate(&run_next/1)
    |> Stream.map(& &1.y_delivered)
    |> Stream.reject(&is_nil/1)
    |> Aoc.EnumHelper.non_uniques()
    |> Enum.at(0)
  end

  defp initial_state() do
    %{
      nat: nil,
      computers: Enum.into(0..49, %{}, &{&1, new_computer(&1)}),
      current_computer: 0,
      y_delivered: nil
    }
  end

  defp new_computer(address), do: Intcode.new(__MODULE__) |> Intcode.run([address])

  defp run_next(state) do
    if not is_nil(state.nat) and idle?(state),
      do: throttle_power(state),
      else: run_next_computer(state)
  end

  defp run_next_computer(state) do
    computer = Map.fetch!(state.computers, state.current_computer)
    inputs = if mailbox_empty?(computer), do: [-1], else: []

    {outputs, computer} = Intcode.pop_outputs(Intcode.run(computer, inputs))
    {nat, outputs} = outputs |> Stream.chunk_every(3) |> Enum.split_with(&match?([@nat_address, _, _], &1))

    computers =
      Enum.reduce(
        outputs,
        Map.put(state.computers, state.current_computer, computer),
        fn [address, x, y], computers -> Map.update!(computers, address, &Intcode.push_inputs(&1, [x, y])) end
      )

    next_computer = rem(state.current_computer + 1, map_size(computers))
    %{state | nat: List.last(nat), computers: computers, current_computer: next_computer, y_delivered: nil}
  end

  defp throttle_power(state) do
    [@nat_address, x, y] = state.nat
    state = update_in(state.computers[0], &Intcode.push_inputs(&1, [x, y]))
    %{state | nat: nil, y_delivered: y, current_computer: 0}
  end

  defp idle?(state), do: Enum.all?(Map.values(state.computers), &mailbox_empty?/1)

  defp mailbox_empty?(computer), do: :queue.peek(computer.input) == :empty

  defmodule Intcode do
    # ------------------------------------------------------------------------
    # API
    # ------------------------------------------------------------------------

    def new(module) do
      %{
        state: :ready,
        ip: 0,
        relative_base: 0,
        memory: initial_memory(module),
        input: :queue.new(),
        output: []
      }
    end

    def run(%{state: state} = computer, inputs \\ []) when state in [:ready, :awaiting_input] do
      computer
      |> push_inputs(inputs)
      |> Stream.iterate(&execute_instruction/1)
      |> Enum.find(&(&1.state != :ready))
    end

    def push_inputs(computer, values), do: Enum.reduce(values, computer, &push_input(&2, &1))

    def outputs(computer), do: List.flatten(computer.output)

    def pop_outputs(computer), do: {outputs(computer), %{computer | output: []}}

    def write_mem(computer, address, value), do: put_in(computer.memory[address], value)

    # ------------------------------------------------------------------------
    # Instructions
    # ------------------------------------------------------------------------

    defp instruction_table() do
      %{
        1 => &add/4,
        2 => &mul/4,
        3 => &input/2,
        4 => &output/2,
        5 => &jump_if_true/3,
        6 => &jump_if_false/3,
        7 => &less_than/4,
        8 => &equals/4,
        9 => &adjust_relative_base/2,
        99 => &halt/1
      }
    end

    defp add(computer, param1, param2, param3),
      do: write(computer, param3, read(computer, param1) + read(computer, param2))

    defp mul(computer, param1, param2, param3),
      do: write(computer, param3, read(computer, param1) * read(computer, param2))

    defp input(computer, param) do
      case :queue.out(computer.input) do
        {:empty, _queue} ->
          %{computer | state: :awaiting_input}

        {{:value, value}, input} ->
          computer = %{computer | input: input}
          write(computer, param, value)
      end
    end

    defp output(computer, param) do
      output = read(computer, param)
      update_in(computer.output, &[&1, output])
    end

    defp jump_if_true(computer, param1, param2) do
      if read(computer, param1) != 0, do: jump(computer, read(computer, param2)), else: computer
    end

    defp jump_if_false(computer, param1, param2) do
      if read(computer, param1) == 0, do: jump(computer, read(computer, param2)), else: computer
    end

    defp less_than(computer, param1, param2, param3) do
      value = if read(computer, param1) < read(computer, param2), do: 1, else: 0
      write(computer, param3, value)
    end

    defp equals(computer, param1, param2, param3) do
      value = if read(computer, param1) == read(computer, param2), do: 1, else: 0
      write(computer, param3, value)
    end

    defp adjust_relative_base(computer, param),
      do: update_in(computer.relative_base, &(&1 + read(computer, param)))

    defp halt(computer), do: %{computer | state: :halted}

    # ------------------------------------------------------------------------
    # Private
    # ------------------------------------------------------------------------

    defp execute_instruction(%{ip: ip} = computer) do
      code = mem_read(computer, ip)
      {fun, arity} = fun_info(code)

      with %{state: :ready, ip: ^ip} = computer <- apply(fun, [computer | parameters(computer, code, arity)]),
           do: update_in(computer.ip, &(&1 + arity + 1))
    end

    defp fun_info(code) do
      opcode = rem(code, 100)
      fun = Map.fetch!(instruction_table(), opcode)
      {:arity, arity} = Function.info(fun, :arity)
      {fun, arity - 1}
    end

    defp parameters(computer, code, arity) do
      Stream.unfold(
        {1, div(code, 100)},
        fn {offset, mode_acc} ->
          value = mem_read(computer, computer.ip + offset)
          mode = param_mode(rem(mode_acc, 10))
          {{mode, value}, {offset + 1, div(mode_acc, 10)}}
        end
      )
      |> Enum.take(arity)
    end

    defp param_mode(0), do: :positional
    defp param_mode(1), do: :immediate
    defp param_mode(2), do: :relative

    defp jump(computer, where), do: %{computer | ip: where}

    defp push_input(computer, value), do: %{computer | input: :queue.in(value, computer.input), state: :ready}

    defp write(computer, address, value), do: put_in(computer.memory[param_addr(computer, address)], value)

    defp read(_computer, {:immediate, value}), do: value
    defp read(computer, address), do: mem_read(computer, param_addr(computer, address))

    defp param_addr(_computer, {:positional, address}), do: address
    defp param_addr(computer, {:relative, address}), do: computer.relative_base + address

    defp mem_read(computer, address) when address >= 0, do: Map.get(computer.memory, address, 0)

    defp initial_memory(module) do
      Aoc.input_file(module)
      |> File.read!()
      |> String.trim()
      |> String.split(",")
      |> Stream.with_index()
      |> Stream.map(fn {value, index} -> {index, String.to_integer(value)} end)
      |> Map.new()
    end
  end
end
