defmodule RPlugin do
  use NVim.Plugin
  require Logger
  alias RPlugin.Doc

  defp format_bindings(bindings) do
    bindings |> Enum.map(fn {k,v}->"#{k} = #{inspect(v,pretty: true, limit: :infinity)}" end) |> Enum.join("\n")
  end

  def init(_) do
    spawn fn-> RPlugin.Mix.mix_load(System.cwd) end
    {:ok,%{current_bindings: [], file_envs: HashDict.new}}
  end

  defcommand mix_start(app,_), async: true do
    Application.ensure_all_started(app && :"#{app}" || Mix.Project.config[:app])
  end

  defcommand mix_stop(app,_), async: true do
    Application.stop(app && :"#{app}" || Mix.Project.config[:app])
  end

  defcommand mix_load(file_dir,state), eval: "expand('%:p:h')", async: true do
    RPlugin.Mix.mix_load(file_dir)
  end

  defcommand elixir_buildenv(ends,cur_file,state), eval: "line('$')", eval: "expand('%:p:h')", async: true do
    {:ok,buffer} = NVim.vim_get_current_buffer
    {:ok,text} = NVim.buffer_get_line_slice(buffer,0,ends-1,true,true)
    envs = RPlugin.Env.env_map(Enum.join(text,"\n"))
    {:ok,nil,%{state|file_envs: Dict.put(state.file_envs,cur_file,envs)}}
  end

  defcommand elixir_exec(bang,[starts,ends],state), bang: true, range: :default_all do
    {:ok,buffer} = NVim.vim_get_current_buffer
    {:ok,text} = NVim.buffer_get_line_slice(buffer,starts-1,ends-1,true,true)
    tmp_dir = System.tmp_dir || "."
    current_bindings = if bang == 0, do: state.current_bindings, else: []
    bindings = try do
      {res,bindings} = Code.eval_string(Enum.join(text,"\n"),current_bindings)
      File.write!("#{tmp_dir}/preview.ex","#{inspect(res,pretty: true, limit: :infinity)}\n\n#{format_bindings bindings}")
      bindings
    catch
      kind,err->
        format_err = Exception.format(kind,err,System.stacktrace)
        File.write! "#{tmp_dir}/preview.ex","#{format_err}\n\n#{format_bindings current_bindings}"
        current_bindings
    end
    NVim.vim_command("pedit! #{tmp_dir}/preview.ex")
    {:ok,nil,%{state| current_bindings: bindings}}
  end

  deffunc docex_get_body(_q,cursor,line,cur_file,numline,state), eval: "col('.')", eval: "getline('.')",
                                                eval: "expand('%:p:h')", eval: "line('.')" do
    env = RPlugin.Env.env_for_line(numline,Dict.get(state.file_envs,cur_file,[])) || __ENV__
    [start_query] = Regex.run(~r"[\w\.:]*$",String.slice(line,0..cursor-1))
    [end_query] = Regex.run(~r"^[\w!?]*",String.slice(line,cursor..-1))
    Doc.get({:q_doc,env,start_query <> end_query}) |> to_string
  end

  deffunc elixir_complete(mode,_,cursor,line,_,_,_,_,state) when mode in ["1",1], eval: "col('.')", eval: "getline('.')",
      eval: "get(g:,'elixir_docpreview',0)", eval: "get(g:,'elixir_maxmenu',70)", 
      eval: "expand('%:p:h')", eval: "line('.')" do
    cursor = cursor - 1 # because we are in insert mode
    [tomatch] = Regex.run(~r"[\w\.:]*$",String.slice(line,0..cursor-1))
    cursor - String.length(tomatch)
  end
  deffunc elixir_complete(_,base,_,_,preview?,maxmenu,cur_file,numline,state), eval: "col('.')", eval: "getline('.')",
      eval: "get(g:,'elixir_docpreview',0)", eval: "get(g:,'elixir_maxmenu',70)", 
      eval: "expand('%:p:h')", eval: "line('.')" do
    if env=RPlugin.Env.env_for_line(numline,Dict.get(state.file_envs,cur_file,[])), do:
      Application.put_env(:iex, :autocomplete_server, %{current_env: env})
    env = env || __ENV__
    case (base |> to_char_list |> Enum.reverse |> IEx.Autocomplete.expand) do
      {:no,_,_}-> [base] # no expand
      {:yes,comp,[]}->["#{base}#{comp}"] #simple expand, no choices
      {:yes,_,alts}-> # multiple choices
        Enum.map(alts,fn comp->
          {base,comp} = {String.replace(base,~r"[^.]*$",""), to_string(comp)}
          case Regex.run(~r"^(.*)/([0-9]+)$",comp) do # first see if these choices are module or function
            [_,function,arity]-> # it is a function completion
              replace = base<>function
              menu = Doc.get({:q_fun_preview,env,{base,function,arity}}) |> to_string |> String.slice(0..maxmenu)
              if(preview?==1 && (doc=Doc.get({:q_doc,env,replace})), do: [{"info",doc}], else: [])
              |> Enum.into(%{"word"=>replace, "abbr"=>comp, "menu"=>menu, "dup"=>1})
            nil-> # it is a module completion
              replace = base<>comp
              menu = Doc.get({:q_mod_preview,env,replace}) |> to_string |> String.slice(0..maxmenu)
              if(preview?==1 && (doc=Doc.get({:q_doc,env,replace})), do: [{"info",doc}], else: [])
              |> Enum.into(%{"word"=>replace, "menu"=>menu})
          end
        end)
    end
  end
end
