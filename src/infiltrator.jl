# This file contains a lot of duplication from repl.jl, however, factoring things out
# is likely to do more harm than good.
struct InfiltratorState
    line::Int
    file::Symbol
    locals::Dict{Symbol, Any}
    backtrace::Vector{Union{Ptr{Nothing}, Base.InterpreterIP}}
end

macro infiltrate(arg)
    quote
        run_infiltrator(InfiltratorState(@__LINE__, @__FILE__, Base.@locals, backtrace())
    end
end

function RunInfiltrator(state::InfiltratorState, repl = nothing, terminal = nothing)
    if repl === nothing
        if !isdefined(Base, :active_repl)
            error("Debugger.jl needs to be run in a Julia REPL")
        end
        repl = Base.active_repl
    end
    if !isa(repl, REPL.LineEditREPL)
        error("Debugger.jl requires a LineEditREPL type of REPL")
    end

    if terminal === nothing
        terminal = Base.active_repl.t
    end

    # Setup debug panel
    normal_prefix = Sys.iswindows() ? "\e[33m" : "\e[38;5;166m"
    panel = LineEdit.Prompt(promptname("infiltrate>");
        prompt_prefix = Sys.iswindows() ? "\e[33m" : "\e[38;5;166m",
        prompt_suffix = Base.text_colors[:normal],
        on_enter = s->true)

    panel.hist = REPL.REPLHistoryProvider(Dict{Symbol,Any}(:infiltrate => panel))
    REPL.history_reset_state(panel.hist)

    search_prompt, skeymap = LineEdit.setup_search_keymap(panel.hist)
    search_prompt.complete = REPL.LatexCompletions()

    state.main_mode = panel

    panel.on_done = (s,buf,ok)->begin
        line = String(take!(buf))
        old_level = state.level
        if !ok || strip(line) == "q"
            LineEdit.transition(s, :abort)
            LineEdit.reset_state(s)
            return false
        end
        if length(panel.hist.history) == 0
            printstyled(stderr, "no previous command executed\n"; color=Base.error_color())
            return false
        end
        if isempty(strip(line))
            command = panel.hist.history[end]
        else
            command = strip(line)
        end
        do_print_status = true
        cmd1 = split(command,' ')[1]
        do_print_status = try
            execute_command(state, Val{Symbol(cmd1)}(), command)
        catch err
            # This will only show the stacktrae up to the current frame because
            # currently, the unwinding in JuliaInterpreter unlinks the frames to
            # where the error is thrown

            # Buffer error printing
            io = IOContext(IOBuffer(), Base.pipe_writer(terminal))
            Base.display_error(io, err, JuliaInterpreter.leaf(state.frame))
            print(Base.pipe_writer(terminal), String(take!(io.io)))
            # Comment below out if you are debugging the Debugger
            #Base.display_error(Base.pipe_writer(terminal), err, catch_backtrace())
            LineEdit.transition(s, :abort)
            LineEdit.reset_state(s)
           return false
        end
        LineEdit.reset_state(s)
        if state.frame === nothing
            LineEdit.transition(s, :abort)
            LineEdit.reset_state(s)
            return false
        end
        if do_print_status
            print_status(Base.pipe_writer(terminal), active_frame(state); force_lowered = state.lowered_status)
        end
        return true
    end

    repl_switch = Dict{Any,Any}(
        '`' => function (s,args...)
            if isempty(s) || position(LineEdit.buffer(s)) == 0
                prompt = julia_prompt(state)
                buf = copy(LineEdit.buffer(s))
                LineEdit.transition(s, prompt) do
                    LineEdit.state(s, prompt).input_buffer = buf
                end
            else
                LineEdit.edit_insert(s, '`')
            end
        end,
        '+' => function (s, args...)
            if isempty(s) || position(LineEdit.buffer(s)) == 0
                NUM_SOURCE_LINES_UP_DOWN[] += 1
                println(Base.pipe_writer(terminal))
                print_status(Base.pipe_writer(terminal), active_frame(state); force_lowered=state.lowered_status)
                LineEdit.write_prompt(state.terminal, panel)
            else
                LineEdit.edit_insert(s, "+")
            end
        end,
        '-' => function (s, args...)
            if isempty(s) || position(LineEdit.buffer(s)) == 0
                NUM_SOURCE_LINES_UP_DOWN[] = max(1, NUM_SOURCE_LINES_UP_DOWN[] - 1)
                println(Base.pipe_writer(terminal))
                print_status(Base.pipe_writer(terminal), active_frame(state); force_lowered=state.lowered_status)
                LineEdit.write_prompt(state.terminal, panel)
            else
                LineEdit.edit_insert(s, "-")
            end
        end
    )

    state.standard_keymap = Dict{Any,Any}[skeymap, LineEdit.history_keymap, LineEdit.default_keymap, LineEdit.escape_defaults]
    panel.keymap_dict = LineEdit.keymap([repl_switch;state.standard_keymap])

    if initial_continue
        try
            execute_command(state, Val(:c), "c")
        catch err
            # Buffer error printing
            io = IOContext(IOBuffer(), Base.pipe_writer(terminal))
            Base.display_error(io, err, JuliaInterpreter.leaf(state.frame))
            print(Base.pipe_writer(terminal), String(take!(io.io)))
            return
        end
        state.frame === nothing && return state.overall_result
    end
    print_status(Base.pipe_writer(terminal), active_frame(state); force_lowered=state.lowered_status)
    REPL.run_interface(terminal, LineEdit.ModalInterface([panel,search_prompt]))

    return state.overall_result
end


function julia_prompt(state::AbstractDebuggerState)
    # Return early if this has already been called on the state
    isassigned(state.julia_prompt) && return state.julia_prompt[]

    julia_prompt = LineEdit.Prompt(() -> promptname(state.level, "julia");
        # Copy colors from the prompt object
        prompt_prefix = state.repl.prompt_color,
        prompt_suffix = (state.repl.envcolors ? Base.input_color : state.repl.input_color),
        complete = DebugCompletionProvider(state),
        on_enter = REPL.return_callback)
    julia_prompt.hist = state.main_mode.hist
    julia_prompt.hist.mode_mapping[:julia] = julia_prompt

    julia_prompt.on_done = (s,buf,ok)->begin
        if !ok
            LineEdit.transition(s, :abort)
            return false
        end
        xbuf = copy(buf)
        command = String(take!(buf))
        @static if VERSION >= v"1.2.0-DEV.253"
            response = _eval_code(active_frame(state), command)
            REPL.print_response(state.repl, response, true, true)
        else
            ok, result = _eval_code(active_frame(state), command)
            REPL.print_response(state.repl, ok ? result : result[1], ok ? nothing : result[2], true, true)
        end
        println(state.terminal)
        LineEdit.reset_state(s)
    end
    julia_prompt.keymap_dict = LineEdit.keymap([REPL.mode_keymap(state.main_mode); state.standard_keymap])
    state.julia_prompt[] = julia_prompt
    return julia_prompt
end