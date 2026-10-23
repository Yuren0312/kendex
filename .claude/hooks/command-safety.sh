#!/usr/bin/env bash
# ---
# name: command-safety
# event: PreToolUse
# matcher: Bash
# description: On harnesses that execute hooks, refuse cat reads of the known ~/.fleet/env spellings. Refuse recognized whole-environment reads unless a proven direct pipe filters named variables. Refuse expanded executable heads and possibly executed written scripts with dump evidence or unread contents within one submission. This fixed check runs outside Git and before project policy. Nested dumps and unsupported routing can refuse conservatively. It reads submitted text, not existing files or unseen programs. COMMAND_SAFETY_DENY_PATTERN replaces only the default systemd-run memory-cap pattern; `^$` disables only that project-pattern check.
# summary: Refuses cat reads of the known private environment file and offers the named non-secret settings reader. Refuses recognized whole-environment command text and gives a filter that names a variable. Also applies the project deny pattern or the default systemd-run memory-cap rule. Unreadable payloads warn and allow the call; unreadable policy support affects only the pattern check.
# safety: One command record retains executable, word and redirect roles through substitutions; actual child commands are checked independently. Classify producers and receivers once before recursive source checks. Shells retain shell parsing, known interpreters use language-specific whole-environment evidence, literal cat bodies retain their data contract, and unknown receivers retain conservative shell-word detection. Within one submission, distinct shell references and unresolved executable contexts trigger shell judgment of recorded writes; matched unread contents refuse, and readable bodies stay independent. No file is read and no cross-submission registry exists. Unquoted body expansions are checked independently, and unsupported forwarded contexts retain conservative refusal. Known private-file cat reads cannot be filtered into permission. Only proven direct named-variable filters grant environment-producer dump permission; project-pattern matching remains independent and reads the submitted text. Unreadable payloads or policy support warn and allow their affected check. Every diagnostic starts with command-safety: <key>=<value>.
# timeout: 10
# requires-skills: [commit-guards]
# ---

set -euo pipefail
environment_registry_active=""
environment_refusal=(environment-read)

# The reported private file is checked as text, without opening it or
# evaluating submitted expansions. Filtering cannot make that read safe.
environment_private_path() {
  local path
  for path in "$@"; do
    case "$path" in '~/.fleet/env' | '$HOME/.fleet/env' | '${HOME}/.fleet/env') return 0 ;; esac
    if [ -n "${HOME:-}" ] && [ "$path" = "$HOME/.fleet/env" ]; then return 0; fi
  done
  return 1
}

# This rule belongs to this hook, not the replaceable project pattern. No
# harness output-rewrite interface can remove secrets before the transcript.
# Only a proven direct pipe grants permission. Nested syntax is detection
# evidence, never proof of routing; unseen program semantics are not judged.
# The selector uses environment_dump's stage words and their kinds. Both
# direct commands and unsupported suffixes need the same launcher decision.
environment_producer() { # command kind, optional unsupported context and command-head proof
    local env_head named_removal
    # Other is unresolved. An existing arm's proof must establish clean.
    mode=other
    # Only these literal forwarding forms are part of the input contract.
    # Unsupported executable-string arguments get conservative detection.
    while [ "$program" != opaque ] && [ "$pos" -lt "${#args[@]}" ]; do
      # ANSI-C escapes in a head have no decoder in this input contract.
      # Refuse rather than permit an encoded environment producer.
      [ "${arg_kinds[$pos]}" != ansi-escaped ] || { mode=dump-unknown; return; }
      [ "${arg_kinds[$pos]}" != dollar-literal ] || arg_kinds[pos]=literal
      [ "${arg_kinds[$pos]}" = literal ] || { program_pos=$pos; program=""; break; }
      program_pos=$pos; program=${args[$pos]##*/}; pos=$((pos + 1))
      case "$program" in
        exec | builtin)
          if [ "$1" = shell ] && [ "${args[$((pos - 1))]}" = "$program" ]; then
            [ -n "$unsupported" ] || main_start=$pos
            program=opaque; unsupported=1; compound=1
          fi
          break ;;
        command)
          case "${args[$pos]:-}" in -v | -V) pos=${#args[@]}; break ;; -p) pos=$((pos + 1)) ;; esac
          [ "${args[$pos]:-}" != -- ] || pos=$((pos + 1))
          continue ;;
        sudo)
          while [ "$pos" -lt "${#args[@]}" ]; do
            case "${args[$pos]}" in
              -u | -g | --user | --group) pos=$((pos + 2)) ;;
              --user=* | --group=* | -n | -E | -H) pos=$((pos + 1)) ;;
              --) pos=$((pos + 1)); break ;;
              *) break ;;
            esac
          done
          continue ;;
        env)
          options_ended=""; null_output=""; env_head=$program_pos; named_removal=""
          while [ "$pos" -lt "${#args[@]}" ]; do
            value=${args[$pos]}
            case "${arg_kinds[$pos]}" in dollar-literal | ansi-escaped) break ;; esac
            [ -z "${2:-}" ] || [ "${2:-}" = conservative ] || [ "${arg_kinds[$pos]}" = literal ] || { mode=dump-unknown; return; }
            # -- ends options, not the following assignment operands.
            if [[ $value =~ $name_re ]] && [[ $value == *=* ]]; then pos=$((pos + 1)); continue; fi
            [ -z "$options_ended" ] || break
            case "$value" in
              -i | --ignore-environment)
                [ -z "${2:-}" ] || [ "${2:-}" = conservative ] || { mode=dump-unknown; return; }
                pos=$((pos + 1)) ;;
              -0 | --null)
                [ -z "${2:-}" ] || [ "${2:-}" = conservative ] || { mode=dump-unknown; return; }
                null_output=1; pos=$((pos + 1)) ;;
              -u | --unset | -C | --chdir)
                # A command-head removal selects a program even with redirected
                # output. Shell-script argument forwarding keeps its own bound.
                [ -z "${2:-}" ] || [ "${2:-}" = conservative ] || { [ "$value" = -u ] && { [ -z "$output" ] || [ "${3:-}" = command-head ]; }; } || { mode=dump-unknown; return; }
                # New suffix and nested permissions require a literal operand.
                # Direct heads retain main's existing option selection.
                [ -z "${2:-}" ] || [ "${arg_kinds[$((pos + 1))]:-}" = literal ] || { mode=dump-unknown; return; }
                [ "$value" != -u ] || named_removal=1
                pos=$((pos + 2)) ;;
              --unset=* | --chdir=*)
                [ -z "${2:-}" ] || [ "${2:-}" = conservative ] || { mode=dump-unknown; return; }
                pos=$((pos + 1)) ;;
              --help | --version)
                [ -z "${2:-}" ] || [ "${2:-}" = conservative ] || { mode=dump-unknown; return; }
                pos=${#args[@]}; program=""; break ;;
              --)
                [ -z "${2:-}" ] || [ "${2:-}" = conservative ] || { mode=dump-unknown; return; }
                options_ended=1; pos=$((pos + 1)); continue ;;
              -S | --split-string | --split-string=*)
                [ -z "${2:-}" ] || [ "${2:-}" = conservative ] || { mode=dump-unknown; return; }
                program=opaque; break ;;
              -*) mode=dump-unknown; break ;;
              *) break ;;
            esac
          done
          if [ "$program" = env ] && [ "$pos" -ge "${#args[@]}" ]; then
            mode=dump-lines; [ -z "$null_output" ] || mode=dump-nul
          fi
          if [ "$program" = env ] && [ "${arg_kinds[$pos]:-literal}" != literal ]; then mode=dump-unknown; fi
          [ "$program" = env ] && [ "$mode" = other ] || break
          # Keep this launcher role through conservative suffix scanning. Its
          # explicit target is still selected and checked by this producer.
          if [ "${3:-}" = command-head ] && [ -n "$named_removal" ]; then arg_roles[env_head]=unset-launcher; fi
          continue ;;
        *) break ;;
      esac
    done
    producer_end=$pos
    # Bash expands ANSI-C escapes after the harness submits command text.
    # These producer operands cannot prove a safe name, flag or input path.
    case "${program:-}" in
      printenv | export | declare | typeset | set | systemctl | cat | tr | strings | xargs)
        for ((j=pos; j<${#args[@]}; j++)); do
          [ "${arg_kinds[$j]}" != ansi-escaped ] || { mode=dump-unknown; return; }
        done ;;
    esac
    case "${program:-}" in
      cat | tr | strings | xargs) [ -z "$input_escaped" ] || { mode=dump-unknown; return; } ;;
    esac
    case "${program:-}" in
      printenv)
        named=""; options_ended=""; null_output=""; mode=dump-lines
        for ((j=pos; j<${#args[@]}; j++)); do
          value=${args[$j]}
          [ "${arg_kinds[$j]}" = literal ] || mode=dump-unknown
          if [ -z "$options_ended" ]; then
            case "$value" in
              --help | --version) named=1; continue ;;
              -0 | --null) null_output=1; continue ;;
              --) options_ended=1; continue ;;
              -*) mode=dump-unknown; continue ;;
            esac
          fi
          [ "${arg_kinds[$j]}" != literal ] || [[ ! $value =~ $name_re ]] || named=1
        done
        if [ "$mode" != dump-unknown ]; then
          if [ -n "$named" ]; then mode=clean; elif [ -n "$null_output" ]; then mode=dump-nul; fi
        fi ;;
      export | declare | typeset)
        named=""; flags=""
        for ((j=pos; j<${#args[@]}; j++)); do
          value=${args[$j]}
          case "$value" in -*) flags=$flags$value ;; *)
            [ "${arg_kinds[$j]}" != literal ] || [[ ! $value =~ $name_re ]] || named=1 ;;
          esac
        done
        if [ -z "$named" ]; then
          case "$program:$flags" in export:* | *:*p* | *:*x*) mode=dump-lines ;; esac
          if [ "$mode" = dump-lines ]; then
            for ((j=pos; j<${#args[@]}; j++)); do
              value=${args[$j]}
              case "$value" in --) ;; -*) [[ $value =~ ^-[px]+$ ]] || mode=dump-unknown ;; *) mode=dump-unknown ;; esac
            done
          fi
        else
          mode=clean
        fi ;;
      set)
        named=""
        for ((j=pos; j<${#args[@]}; j++)); do [ "${arg_kinds[$j]}" != literal ] || named=1; done
        if [ -z "$named" ]; then
          if [ "$pos" -lt "${#args[@]}" ]; then mode=dump-unknown; else mode=dump-lines; fi
        elif [ -n "${2:-}" ] && [ "${2:-}" != conservative ]; then
          # The producer's clean result is retained only in the recorded
          # receipt context. Stage and file-write facts stay at their owners.
          if [ "${2:-}" != 1 ] || [ "$stage" -ne 1 ] || [ "${#starts[@]}" -ne 6 ] || [ -z "$pipeline" ] ||
             [ "${file_outputs[0]:-}" != 1 ] || [ "${separators[0]}:${separators[1]}:${separators[2]}" != ';:;:|' ] ||
             [ "$((${#args[@]} - pos))" -ne 2 ] || [ "${args[$pos]}:${args[$((pos + 1))]}" != -o:pipefail ] ||
             [ "${arg_kinds[$pos]}:${arg_kinds[$((pos + 1))]}" != literal:literal ]; then mode=dump-unknown; fi
        fi
        [ -z "$named" ] || [ "$mode" != other ] || mode=clean ;;
      systemctl)
        for ((j=pos; j<${#args[@]}; j++)); do [ "${args[$j]}" != show-environment ] || mode=dump-lines; done
        if [ "$mode" = dump-lines ]; then
          for ((j=pos; j<${#args[@]}; j++)); do
            case "${args[$j]}" in --user | --system | -- | show-environment) ;; *) mode=dump-unknown ;; esac
          done
        fi ;;
      cat | tr | strings | xargs)
        for ((j=pos; j<${#args[@]}; j++)); do [[ ${args[$j]} != /proc/*/environ ]] || proc=1; done
        if [ -n "$proc" ]; then
          case "$program" in
            cat | strings)
              mode=dump-nul; [ "$program" != strings ] || mode=dump-lines
              for ((j=pos; j<${#args[@]}; j++)); do
                [ "${args[$j]}" != -- ] || continue
                [ "${arg_kinds[$j]}" = literal ] || mode=dump-unknown
                [[ ${args[$j]} == /proc/*/environ ]] || mode=dump-unknown
              done ;;
            tr | xargs) mode=dump-unknown ;;
          esac
        fi
        # Only this literal conversion proves separate newline records.
        # Unknown transformations and flattened xargs output stay unknown.
        if [ "$program" = tr ] && [ -z "$output" ] && [ "$((${#args[@]} - pos))" -eq 2 ] &&
          [ "${arg_kinds[$pos]}:${arg_kinds[$((pos + 1))]}" = literal:literal ]; then
          case "${args[$pos]}:${args[$((pos + 1))]}" in
            '\0:\n' | '\000:\n')
              if [ -n "$proc" ]; then mode=dump-lines; elif [ -z "$input_redirect" ]; then mode=convert; fi ;;
          esac
        fi
        if [ "$program" = cat ] && environment_private_path ${private_inputs[@]+"${private_inputs[@]}"} "${args[@]:pos}"; then mode=dump-unknown; fi ;;
      grep)
        filter_ok=1; pattern_count=0; pattern=""
        for ((j=pos; j<${#args[@]}; j++)); do
          value=${args[$j]}
          [ "${arg_kinds[$j]}" = literal ] || filter_ok=""
          case "$value" in
            --) pos=$((j + 1)); break ;;
            -e) j=$((j + 1)); value=${args[$j]:-}; [ "${arg_kinds[$j]:-}" = literal ] || filter_ok="" ;;
            -*) [[ $value =~ ^-[EFq]+$ ]] || filter_ok=""; continue ;;
          esac
          pattern_count=$((pattern_count + 1)); pattern=$value
        done
        if [ "${value:-}" = -- ]; then
          for ((j=pos; j<${#args[@]}; j++)); do
            pattern_count=$((pattern_count + 1)); pattern=${args[$j]}; [ "${arg_kinds[$j]}" = literal ] || filter_ok=""
          done
        fi
        if [ -n "$filter_ok" ] && [ "$pattern_count" -eq 1 ] && [[ $pattern =~ $filter_re ]] && [ -z "$input_redirect" ]; then mode=filter; fi ;;
    esac
    if [ -n "${2:-}" ] && [ "${2:-}" != conservative ] && { [ "$mode" = other ] || [ "$mode" = clean ]; }; then
      case "$program" in printenv | export | declare | typeset) mode=dump-unknown ;; esac
    fi
    # No unresolved arm can discharge the forwarded classification check.
    if [ "$mode" = other ] && [ -n "${forwarded_argument:-}" ]; then mode=unclassified-forwarded; fi
    if { [ "$mode" = other ] || [ "$mode" = unclassified-forwarded ]; } &&
       [ -n "$program_pos" ] && [ "${arg_kinds[$program_pos]}" = literal ] &&
       environment_main_evidence --head "${arg_expansions[$program_pos]}"; then
      mode=dump-unknown
      environment_refusal=(expanded-head "${args[$program_pos]}")
    fi
}

# An argument role requires an executable head. Reserved-word syntax and
# assignment prefixes cannot turn a quoted executable into argument data.
environment_head() { # command kind; updates pos, syntax_head and arg_roles
  local cursor state=head value
  pos=${#args[@]}; syntax_head=""; head_start=0
  for ((cursor=0; cursor<${#args[@]}; cursor++)); do
    arg_roles[cursor]=unknown
  done
  if [ "$1" = argv ]; then pos=0; return; fi
  while [ "$head_start" -lt "${#args[@]}" ] && [[ ${args[$head_start]} =~ $name_re ]] && [[ ${args[$head_start]} == *=* ]]; do head_start=$((head_start + 1)); done
  for ((cursor=0; cursor<${#args[@]}; cursor++)); do
    value=${args[$cursor]}
    if [ -n "${arg_syntax[$cursor]:-}" ]; then syntax_head=1; arg_roles[cursor]=syntax; continue; fi
    case "$state" in
      name) arg_roles[cursor]=syntax; state=body; continue ;;
      body | loop | conditional)
        if [ "${arg_kinds[$cursor]}" = literal ] && [ -n "${arg_unquoted[$cursor]}" ]; then
          case "$value:$state" in '{:body' | do:loop) state=head; arg_roles[cursor]=syntax ;; esac
        fi
        continue ;;
      time)
        case "$value" in -*) arg_roles[cursor]=syntax; continue ;; esac
        state=head ;;
    esac
    if [[ $value =~ $name_re ]] && [[ $value == *=* ]]; then arg_roles[cursor]=syntax; continue; fi
    if [ "${arg_kinds[$cursor]}" = literal ] && [ -n "${arg_unquoted[$cursor]}" ]; then
      case "$value" in
        if | then | elif | else | while | until | do | '{' | '!')
          syntax_head=1; arg_roles[cursor]=syntax; continue ;;
        time) syntax_head=1; arg_roles[cursor]=syntax; state=time; continue ;;
        function) syntax_head=1; arg_roles[cursor]=syntax; state=name; continue ;;
        for | select) syntax_head=1; arg_roles[cursor]=syntax; state=loop; continue ;;
        case | '[[') syntax_head=1; arg_roles[cursor]=syntax; state=conditional; continue ;;
        'coproc')
          syntax_head=1; arg_roles[cursor]=syntax
          if [ "${args[$((cursor + 2))]:-}" = '{' ]; then state=name; fi
          continue ;;
        fi | done | 'esac' | '}' | ']]' | in)
          syntax_head=1; arg_roles[cursor]=syntax; continue ;;
      esac
    fi
    pos=$cursor
    return
  done
}

# The directed cuts retain main's text test where executable evidence is
# unproved. This grants no argument, body-data or direct-filter permission.
environment_main_evidence() {
  local value evidence head="" continuation=$'\\\n'
  local opaque_re='(^|[^A-Za-z0-9_.-])(env|printenv|export|declare|typeset|show-environment)([^A-Za-z0-9_.-]|$)|(^|[^A-Za-z0-9_-])set([^A-Za-z0-9_-]|$)|/proc/[^[:space:]]*/environ'
  if [ "${1:-}" = --head ]; then head=1; shift; fi
  for value in "$@"; do
    evidence=${value//"$continuation"/}
    evidence=${evidence//[\'\"\\]/}
    if [ -n "$head" ]; then
      case "$evidence" in
        *[\*\?]* | *'['*']'* | *'{'*','*'}'* | *'{'*'..'*'}'*) return 0 ;;
      esac
      continue
    fi
    [[ ! $evidence =~ $opaque_re ]] || return 0
  done
  return 1
}

# Other optional registered bodies use the complete command classifier. Its
# original token order keeps the unsupported suffix at its source owner.
environment_main_command() { # command kind; arguments are already decoded data
  local LC_ALL=C i=0 c next quote="" word="" active="" kind=literal compound="" bare=1
  local j start=0 end n fd target proc output input_redirect input_escaped pos program value named flags
  local mode pattern_count pattern filter_ok stage=0 text text_length span span_re comment_span options_ended null_output syntax_head opaque_from
  local name_re='^[A-Za-z_][A-Za-z0-9_]*(=.*)?$'
  local filter_re='^([A-Za-z_][A-Za-z0-9_]*=?|\^[A-Za-z_][A-Za-z0-9_]*=|\^\([A-Za-z_][A-Za-z0-9_]*(\|[A-Za-z_][A-Za-z0-9_]*)+\)=)$'
  local ordinary_span_re=$'^[^\'"\\\\$`# \t\r\n;|()<>&]+'
  local single_span_re="^[^']+" ansi_span_re="^[^'\\\\]+" double_span_re='^[^"\\$`]+' comment_span_re=$'^[^\n]+'
  local tokens=() kinds=() unquoted_words=() saved_quotes=() closers=() args=() arg_kinds=() arg_unquoted=() arg_syntax=() origins=() evidence=()
  local private_inputs=()
  local starts=() ends=() separators=() decisions=()
  if [ "$1" = argv ]; then
    tokens=(${command_argv[@]+"${command_argv[@]}"})
    for ((i=0; i<${#tokens[@]}; i++)); do kinds[i]=literal; unquoted_words[i]=""; done
  else
    text=$command_text
    text_length=${#text}
    while [ "$i" -lt "$text_length" ]; do
      case "$quote" in
        "'") span_re=$single_span_re ;;
        ansi) span_re=$ansi_span_re ;;
        '"') span_re=$double_span_re ;;
        *) span_re=$ordinary_span_re ;;
      esac
      # Copy literal spans once. Marker handlers keep the quote and routing
      # decisions; growing a word byte by byte exceeds the hook budget.
      if [[ ${text:$i} =~ $span_re ]]; then
        span=${BASH_REMATCH[0]}; word=$word$span; active=1
        i=$((i + ${#span}))
        continue
      fi
      c=${text:$i:1}; i=$((i + 1)); next=${text:$i:1}
      if [ "$quote" = ansi ]; then
        case "$c" in
          "'") quote="" ;;
          '\') kind=ansi-escaped; word=$word$c$next; i=$((i + 1)) ;;
          *) word=$word$c ;;
        esac
        continue
      fi
      if [ "$quote" = "'" ]; then
        if [ "$c" = "'" ]; then quote=""; else word=$word$c; fi
        continue
      fi
      if [ "$c" = '\' ]; then
        if [ "$i" -ge "$text_length" ]; then kind=unknown; break; fi
        i=$((i + 1))
        [ "$next" = $'\n' ] || bare=""
        if [ "$quote" = '"' ]; then
          case "$next" in '"' | '\' | '$' | '`' | $'\n') ;; *) word=$word$c ;; esac
        fi
        [ "$next" = $'\n' ] || { word=$word$next; active=1; }
        continue
      fi
      # A substitution's known producer must remain visible inside double
      # quotes. Saving only the enclosing quote grants no inner permission.
      if { [ "$c" = '$' ] && [ "$next" = '(' ]; } || [ "$c" = '`' ]; then
        if [ -n "$active" ]; then unquoted_words[${#tokens[@]}]=$bare; tokens[${#tokens[@]}]=$word; kinds[${#kinds[@]}]=$kind; fi
        word=""; active=""; kind=literal; bare=1; compound=1
        n=${#closers[@]}
        if [ "$c" = '`' ] && [ "$n" -gt 0 ] && [ "${closers[$((n - 1))]}" = '`' ]; then
          quote=${saved_quotes[$((n - 1))]}; unset 'closers[n-1]' 'saved_quotes[n-1]'
        else
          saved_quotes[n]=$quote; quote=""
          if [ "$c" = '$' ]; then closers[n]=')'; i=$((i + 1)); else closers[n]='`'; fi
        fi
        [ -z "$quote" ] || bare=""
        unquoted_words[${#tokens[@]}]=""
        tokens[${#tokens[@]}]=';'; kinds[${#kinds[@]}]=operator
        continue
      fi
      if [ "$quote" = '"' ]; then
        if [ "$c" = '"' ]; then quote=""; else word=$word$c; [ "$c" != '$' ] || [ "$kind" = ansi-escaped ] || kind=unknown; fi
        continue
      fi
      case "$c" in
        "'" | '"') quote=$c; active=1; bare=""; continue ;;
        '$')
          case "$next" in
            "'" | '"')
              quote=$next; [ "$next" != "'" ] || quote=ansi
              # Dollar arguments keep their conservative kind. Only the
              # existing command-head selector can use the literal word.
              [ "$kind" != literal ] || kind=dollar-literal
              i=$((i + 1)) ;;
            *) [ "$kind" = ansi-escaped ] || kind=unknown; word=$word$c ;;
          esac
          active=1; bare=""; continue ;;
        '#')
          if [ -z "$active" ]; then
            if [[ ${text:$i} =~ $comment_span_re ]]; then
              comment_span=${BASH_REMATCH[0]}; i=$((i + ${#comment_span}))
            fi
            continue
          fi ;;
      esac
      case "$c" in
        ' ' | $'\t' | $'\r' | $'\n' | ';' | '&' | '|' | '(' | ')' | '<' | '>')
          if [ -n "$active" ]; then unquoted_words[${#tokens[@]}]=$bare; tokens[${#tokens[@]}]=$word; kinds[${#kinds[@]}]=$kind; fi
          word=""; active=""; kind=literal; bare=1
          case "$c" in ' ' | $'\t' | $'\r') continue ;; esac
          case "$c" in
            '(') compound=1; n=${#closers[@]}; saved_quotes[n]=""; closers[n]=')'; c=';' ;;
            ')')
              compound=1; n=${#closers[@]}
              if [ "$n" -gt 0 ]; then quote=${saved_quotes[$((n - 1))]}; unset 'closers[n-1]' 'saved_quotes[n-1]'; fi
              [ -z "$quote" ] || bare=""
              c=';' ;;
            $'\n') c=';' ;;
            *)
              case "$c$next" in
                '&&' | '||' | '>>' | '>&' | '<&' | '&>' | '<<') c=$c$next; i=$((i + 1)) ;;
              esac
              [ "$c" != '<<' ] || compound=1 ;;
          esac
          unquoted_words[${#tokens[@]}]=""; tokens[${#tokens[@]}]=$c; kinds[${#kinds[@]}]=operator ;;
        *) word=$word$c; active=1 ;;
      esac
    done
    [ -z "$quote" ] && [ "${#closers[@]}" -eq 0 ] || compound=1
    if [ -n "$active" ]; then unquoted_words[${#tokens[@]}]=$bare; tokens[${#tokens[@]}]=$word; kinds[${#kinds[@]}]=$kind; fi
  fi
  n=${#tokens[@]}
  for ((i=0; i<=n; i++)); do
    if [ "$i" -lt "$n" ]; then
      [ "${kinds[$i]}" = operator ] || continue
      case "${tokens[$i]}" in '|' | ';' | '&&' | '||' | '&') ;; *) continue ;; esac
    fi
    starts[stage]=$start; ends[stage]=$i
    separators[stage]=${tokens[$i]:-end}; stage=$((stage + 1)); start=$((i + 1))
  done
  for ((stage=0; stage<${#starts[@]}; stage++)); do
    start=${starts[$stage]}; end=${ends[$stage]}; args=(); arg_kinds=(); arg_unquoted=(); origins=()
    private_inputs=(); proc=""; output=""; input_redirect=""; input_escaped=""; mode=other; program=""; opaque_from=""
    for ((j=start; j<end; j++)); do
      if [ "${kinds[$j]}" = operator ]; then
        fd=""; n=${#args[@]}
        if [ "$n" -gt 0 ] && [[ ${args[$((n - 1))]} =~ ^[0-9]+$ ]]; then
          fd=${args[$((n - 1))]}; unset 'args[n-1]' 'arg_kinds[n-1]' 'arg_unquoted[n-1]' 'origins[n-1]'
        fi
        j=$((j + 1)); target=${tokens[$j]:-}
        case "${tokens[$((j - 1))]}" in
          '<')
            input_redirect=1
            private_inputs[${#private_inputs[@]}]=$target
            [ "${kinds[$j]:-}" != ansi-escaped ] || input_escaped=1
            [[ $target != /proc/*/environ ]] || proc=1 ;;
          '<&' | '<<') input_redirect=1 ;;
          '>' | '>>' | '>&') [ "$fd" = 2 ] || output=1 ;;
          '&>') output=1 ;;
        esac
        continue
      fi
      n=${#args[@]}
      args[n]=${tokens[$j]}; arg_kinds[n]=${kinds[$j]}; arg_unquoted[n]=${unquoted_words[$j]}; origins[n]=$j
    done
    pos=0
    if [ "$1" = shell ]; then
      while [ "$pos" -lt "${#args[@]}" ] && [[ ${args[$pos]} =~ $name_re ]] && [[ ${args[$pos]} == *=* ]]; do pos=$((pos + 1)); done
    fi
    syntax_head=""
    if [ "$1" = shell ] && [ "$pos" -lt "${#args[@]}" ] && [ "${arg_kinds[$pos]}" = literal ]; then
      # Reserved-word spelling ends selection, not merely one forwarding
      # step. No function name, case pattern or option can restart it.
      case "${args[$pos]}" in
        if | then | elif | else | fi | time | for | in | until | while | do | done | case | 'coproc' | select | function | '{' | '}' | '[[' | ']]' | '!')
          syntax_head=${arg_unquoted[$pos]} ;;
        exec | builtin) syntax_head=1 ;;
      esac
    fi
    if [ -n "$syntax_head" ]; then
      program=opaque
      opaque_from=$((origins[$pos] + 1))
    fi
    # Only these literal forwarding forms are part of the input contract.
    # Unsupported executable-string arguments get conservative detection.
    while [ "$program" != opaque ] && [ "$pos" -lt "${#args[@]}" ]; do
      # ANSI-C escapes in a head have no decoder in this input contract.
      # Refuse rather than permit an encoded environment producer.
      [ "${arg_kinds[$pos]}" != ansi-escaped ] || return 0
      [ "${arg_kinds[$pos]}" != dollar-literal ] || arg_kinds[pos]=literal
      [ "${arg_kinds[$pos]}" = literal ] || break
      program=${args[$pos]##*/}; pos=$((pos + 1))
      case "$program" in
        exec | builtin)
          if [ "$1" = shell ] && [ "${args[$((pos - 1))]}" = "$program" ]; then
            opaque_from=$((origins[$((pos - 1))] + 1)); program=opaque
          fi
          break ;;
        command)
          case "${args[$pos]:-}" in -v | -V) pos=${#args[@]}; break ;; -p) pos=$((pos + 1)) ;; esac
          [ "${args[$pos]:-}" != -- ] || pos=$((pos + 1))
          continue ;;
        sudo)
          while [ "$pos" -lt "${#args[@]}" ]; do
            case "${args[$pos]}" in
              -u | -g | --user | --group) pos=$((pos + 2)) ;;
              --user=* | --group=* | -n | -E | -H) pos=$((pos + 1)) ;;
              --) pos=$((pos + 1)); break ;;
              *) break ;;
            esac
          done
          continue ;;
        env)
          options_ended=""; null_output=""
          while [ "$pos" -lt "${#args[@]}" ]; do
            value=${args[$pos]}
            case "${arg_kinds[$pos]}" in dollar-literal | ansi-escaped) break ;; esac
            # -- ends options, not the following assignment operands.
            if [[ $value =~ $name_re ]] && [[ $value == *=* ]]; then pos=$((pos + 1)); continue; fi
            [ -z "$options_ended" ] || break
            case "$value" in
              -i | --ignore-environment) pos=$((pos + 1)) ;;
              -0 | --null) null_output=1; pos=$((pos + 1)) ;;
              -u | --unset | -C | --chdir) pos=$((pos + 2)) ;;
              --unset=* | --chdir=*) pos=$((pos + 1)) ;;
              --help | --version) pos=${#args[@]}; program=""; break ;;
              --) options_ended=1; pos=$((pos + 1)); continue ;;
              -S | --split-string | --split-string=*) program=opaque; break ;;
              -*) mode=dump-unknown; break ;;
              *) break ;;
            esac
          done
          if [ "$program" = env ] && [ "$pos" -ge "${#args[@]}" ]; then
            mode=dump-lines; [ -z "$null_output" ] || mode=dump-nul
          fi
          if [ "$program" = env ] && [ "${arg_kinds[$pos]:-literal}" != literal ]; then mode=dump-unknown; fi
          [ "$program" = env ] && [ "$mode" = other ] || break
          continue ;;
        *) break ;;
      esac
    done
    # Bash expands ANSI-C escapes after the harness submits command text.
    # These producer operands cannot prove a safe name, flag or input path.
    case "${program:-}" in
      printenv | export | declare | typeset | set | systemctl | cat | tr | strings | xargs)
        for ((j=pos; j<${#args[@]}; j++)); do
          [ "${arg_kinds[$j]}" != ansi-escaped ] || return 0
        done ;;
    esac
    case "${program:-}" in
      cat | tr | strings | xargs) [ -z "$input_escaped" ] || return 0 ;;
    esac
    case "${program:-}" in
      printenv)
        named=""; options_ended=""; null_output=""; mode=dump-lines
        for ((j=pos; j<${#args[@]}; j++)); do
          value=${args[$j]}
          [ "${arg_kinds[$j]}" = literal ] || mode=dump-unknown
          if [ -z "$options_ended" ]; then
            case "$value" in
              --help | --version) named=1; continue ;;
              -0 | --null) null_output=1; continue ;;
              --) options_ended=1; continue ;;
              -*) mode=dump-unknown; continue ;;
            esac
          fi
          [ "${arg_kinds[$j]}" != literal ] || [[ ! $value =~ $name_re ]] || named=1
        done
        if [ "$mode" != dump-unknown ]; then
          if [ -n "$named" ]; then mode=other; elif [ -n "$null_output" ]; then mode=dump-nul; fi
        fi ;;
      export | declare | typeset)
        named=""; flags=""
        for ((j=pos; j<${#args[@]}; j++)); do
          value=${args[$j]}
          case "$value" in -*) flags=$flags$value ;; *)
            [ "${arg_kinds[$j]}" != literal ] || [[ ! $value =~ $name_re ]] || named=1 ;;
          esac
        done
        if [ -z "$named" ]; then
          case "$program:$flags" in export:* | *:*p* | *:*x*) mode=dump-lines ;; esac
          if [ "$mode" = dump-lines ]; then
            for ((j=pos; j<${#args[@]}; j++)); do
              value=${args[$j]}
              case "$value" in --) ;; -*) [[ $value =~ ^-[px]+$ ]] || mode=dump-unknown ;; *) mode=dump-unknown ;; esac
            done
          fi
        fi ;;
      set)
        named=""
        for ((j=pos; j<${#args[@]}; j++)); do [ "${arg_kinds[$j]}" != literal ] || named=1; done
        if [ -z "$named" ]; then
          if [ "$pos" -lt "${#args[@]}" ]; then mode=dump-unknown; else mode=dump-lines; fi
        fi ;;
      systemctl)
        for ((j=pos; j<${#args[@]}; j++)); do [ "${args[$j]}" != show-environment ] || mode=dump-lines; done
        if [ "$mode" = dump-lines ]; then
          for ((j=pos; j<${#args[@]}; j++)); do
            case "${args[$j]}" in --user | --system | -- | show-environment) ;; *) mode=dump-unknown ;; esac
          done
        fi ;;
      cat | tr | strings | xargs)
        for ((j=pos; j<${#args[@]}; j++)); do [[ ${args[$j]} != /proc/*/environ ]] || proc=1; done
        if [ -n "$proc" ]; then
          case "$program" in
            cat | strings)
              mode=dump-nul; [ "$program" != strings ] || mode=dump-lines
              for ((j=pos; j<${#args[@]}; j++)); do
                [ "${args[$j]}" != -- ] || continue
                [ "${arg_kinds[$j]}" = literal ] || mode=dump-unknown
                [[ ${args[$j]} == /proc/*/environ ]] || mode=dump-unknown
              done ;;
            tr | xargs) mode=dump-unknown ;;
          esac
        fi
        # Only this literal conversion proves separate newline records.
        # Unknown transformations and flattened xargs output stay unknown.
        if [ "$program" = tr ] && [ -z "$output" ] && [ "$((${#args[@]} - pos))" -eq 2 ] &&
          [ "${arg_kinds[$pos]}:${arg_kinds[$((pos + 1))]}" = literal:literal ]; then
          case "${args[$pos]}:${args[$((pos + 1))]}" in
            '\0:\n' | '\000:\n')
              if [ -n "$proc" ]; then mode=dump-lines; elif [ -z "$input_redirect" ]; then mode=convert; fi ;;
          esac
        fi
        if [ "$program" = cat ] && environment_private_path ${private_inputs[@]+"${private_inputs[@]}"} "${args[@]:pos}"; then mode=dump-unknown; fi ;;
      grep)
        filter_ok=1; pattern_count=0; pattern=""
        for ((j=pos; j<${#args[@]}; j++)); do
          value=${args[$j]}
          [ "${arg_kinds[$j]}" = literal ] || filter_ok=""
          case "$value" in
            --) pos=$((j + 1)); break ;;
            -e) j=$((j + 1)); value=${args[$j]:-}; [ "${arg_kinds[$j]:-}" = literal ] || filter_ok="" ;;
            -*) [[ $value =~ ^-[EFq]+$ ]] || filter_ok=""; continue ;;
          esac
          pattern_count=$((pattern_count + 1)); pattern=$value
        done
        if [ "${value:-}" = -- ]; then
          for ((j=pos; j<${#args[@]}; j++)); do
            pattern_count=$((pattern_count + 1)); pattern=${args[$j]}; [ "${arg_kinds[$j]}" = literal ] || filter_ok=""
          done
        fi
        if [ -n "$filter_ok" ] && [ "$pattern_count" -eq 1 ] && [[ $pattern =~ $filter_re ]] && [ -z "$input_redirect" ]; then mode=filter; fi ;;
      opaque | bash | sh | dash | zsh | ksh | eval | source | .)
        evidence=()
        if [ -n "$opaque_from" ]; then
          mode=opaque-clean; compound=1
          # Keep the suffix across list, pipe and brace boundaries. The
          # selector cannot prove where an unsupported construct ends.
          for ((j=opaque_from; j<${#tokens[@]}; j++)); do
            [ "${kinds[$j]}" != ansi-escaped ] || mode=dump-unknown
            evidence[${#evidence[@]}]=${tokens[$j]}
          done
        else
          for ((j=pos; j<${#args[@]}; j++)); do evidence[${#evidence[@]}]=${args[$j]}; done
        fi
        for value in ${evidence[@]+"${evidence[@]}"}; do
          if environment_main_evidence "$value"; then mode=dump-unknown; compound=1; fi
        done ;;
    esac
    case "$mode" in dump-*) [ -z "$output" ] || mode=unrouted ;; esac
    decisions[stage]=$mode
  done
  for ((stage=0; stage<${#decisions[@]}; stage++)); do
    case "${decisions[$stage]}" in
      unrouted | dump-unknown) return 0 ;;
      dump-lines | dump-nul)
        [ -z "$compound" ] || return 0
        j=$stage
        if [ "${decisions[$stage]}" = dump-nul ]; then
          if [ "${separators[$j]}" != '|' ] || [ "${decisions[$((j + 1))]:-}" != convert ]; then return 0; fi
          j=$((j + 1))
        fi
        if [ "${separators[$j]}" != '|' ] || [ "${decisions[$((j + 1))]:-}" != filter ]; then return 0; fi ;;
    esac
  done
  return 1
}

# Receiving language is a local classification, not an exemption from the
# independent shell expansion and unsupported forwarding checks.
environment_receiver() {
  receiver=unknown; receiver_pattern=""; receiver_option=""; receiver_named=""
  case "$program" in
    cat) receiver=data ;;
    bash | sh | dash | zsh | ksh | eval | source | .) receiver=shell ;;
    python | python3)
      receiver=interpreter; receiver_option='^-c$'
      receiver_pattern='(^|[^A-Za-z0-9_])os[[:space:]]*\.[[:space:]]*environ'
      receiver_named='^[[:blank:]]*(\[|\.[[:blank:]]*(get|pop|setdefault|__getitem__|__contains__)[[:blank:]]*\()' ;;
    node)
      receiver=interpreter; receiver_option='^(-e|--eval)$'
      receiver_pattern='(^|[^A-Za-z0-9_])process[[:space:]]*\.[[:space:]]*env'
      receiver_named='^[[:blank:]]*(\[|\.)' ;;
    ruby)
      receiver=interpreter; receiver_option='^-e$'
      receiver_pattern='(^|[^A-Za-z0-9_])ENV[[:space:]]*\.[[:space:]]*(to_h|each)([^A-Za-z0-9_]|$)' ;;
    perl)
      receiver=interpreter; receiver_option='^-e$'
      receiver_pattern='%ENV([^A-Za-z0-9_]|$)' ;;
  esac
}

environment_receiver_evidence() {
  local remaining=$1 matched
  while [[ $remaining =~ $receiver_pattern ]]; do
    matched=${BASH_REMATCH[0]}
    remaining=${remaining#*"$matched"}
    [ -n "$receiver_named" ] || return 0
    # Identifier suffixes are not this object. A newline ends the reference;
    # only same-line key selection proves a named value instead of a mapping.
    if [[ $remaining =~ ^[A-Za-z0-9_]+ ]]; then
      matched=${BASH_REMATCH[0]}
      remaining=${remaining#"$matched"}
      continue
    fi
    [[ $remaining =~ $receiver_named ]] || return 0
  done
  return 1
}

# Shell invocation options precede the executable operand, including options
# after -c. Known literal input stays conservative for every shell invocation;
# script operands and redirects do not prove that the body is unused.
environment_program_text() {
  local cursor=$pos source="" options_ended="" wants_string="" value text="" unproved=""
  stdin_program=""; source_pos=""
  environment_receiver
  if [ "$receiver" = interpreter ]; then
    for ((cursor=pos; cursor<${#args[@]}; cursor++)); do
      if [[ ${args[$cursor]} =~ $receiver_option ]]; then
        cursor=$((cursor + 1))
        if [ "${arg_kinds[$cursor]:-}" = literal ] &&
           environment_receiver_evidence "${args[$cursor]:-}"; then mode=dump-unknown; fi
        break
      fi
      case "${args[$cursor]}" in - | --) break ;; -*) ;; *) break ;; esac
    done
    return
  fi
  [ -z "$unsupported$syntax_head" ] && [ -n "$program_pos" ] &&
    [ "${arg_roles[$program_pos]:-}" = command ] || unproved=1
  case "$program" in
    bash | sh | dash | zsh | ksh)
      stdin_program=1
      while [ "$cursor" -lt "${#args[@]}" ]; do
        value=${args[$cursor]}
        [ "${arg_kinds[$cursor]}" = literal ] || unproved=1
        if [ -z "$options_ended" ]; then
          case "$value" in
            --) options_ended=1; cursor=$((cursor + 1)); continue ;;
            --rcfile | --init-file)
              [ "${arg_kinds[$((cursor + 1))]:-}" = literal ] || unproved=1
              cursor=$((cursor + 2)); continue ;;
            -[^-]* | +*)
              # A short-option word can combine command-string selection and
              # an option with an operand. Consume the entire invocation word.
              [[ $value != -*c* ]] || wants_string=1
              [[ ${value:1} =~ ^[abCefhiklmnprstuvxBDEHPTcoO]+$ ]] || unproved=1
              case "${value:1}" in
                *[oO]*[oO]*)
                  # Main's refusal remains for unproved grouped operands.
                  # This cut adds no operand-counting allowance.
                  if environment_main_evidence "${args[@]:pos}"; then mode=dump-unknown; fi
                  return ;;
                *o* | *O*)
                  [ "${arg_kinds[$((cursor + 1))]:-}" = literal ] || unproved=1
                  cursor=$((cursor + 2)) ;;
                *) cursor=$((cursor + 1)) ;;
              esac
              continue ;;
            -*) unproved=1; cursor=$((cursor + 1)); continue ;;
          esac
        fi
        if [ -n "$wants_string" ]; then source=$value; source_pos=$cursor; fi
        break
      done ;;
    eval)
      stdin_program=1
      # Eval can consume a leading option operand before joining its source.
      case "${args[$pos]:-}" in -*) unproved=1 ;; esac
      for ((cursor=pos; cursor<${#args[@]}; cursor++)); do
        source=$source$text${args[$cursor]}; text=' '
        [ "${arg_kinds[$cursor]}" = literal ] || unproved=1
      done
      source_pos=$pos ;;
    source | .) stdin_program=1 ;;
    opaque)
      unproved=1
      # Exec can retain literal input for later list commands. Remove the
      # entire unproved body-data permission, including encoded body words.
      [ -z "$data_source" ] || { mode=dump-unknown; return; }
      case "${args[$pos]:-}" in
        -S | --split-string) source_pos=$((pos + 1)); source=${args[$source_pos]:-} ;;
        --split-string=*) source_pos=$pos; source=${args[$pos]#*=} ;;
      esac ;;
  esac
  if [ -n "$source_pos" ]; then
    # Only a proved source range belongs to recursive command parsing.
    # Unproved selection retains main's complete-string evidence.
    if [ -n "$unproved" ]; then
      if environment_main_evidence "$source"; then mode=dump-unknown; return; fi
    elif [ "$program" = eval ]; then
      for ((cursor=pos; cursor<${#args[@]}; cursor++)); do arg_roles[cursor]=executable; done
    else
      arg_roles[$source_pos]=executable
    fi
    cursor=${#executable_texts[@]}
    executable_texts[cursor]=$source; executable_stages[cursor]=$stage
    # Selecting shell or eval source does not classify its descendants.
    # Keep the forwarded argv check active through every queued source.
    [ -z "${forwarded_argument:-}" ] || executable_contexts[cursor]=forwarded
  fi
}

# Word roles belong to the collector, including across command records.
# Case frames share the delimiter stack so a pattern cannot close its caller.
environment_collect_word() {
  local frame=$((${#closers[@]} - 1)) syntax=""
  [ -n "$active" ] || return 0
  case "$command_head" in
    time)
      case "$word" in -*) syntax=1 ;; *) command_head=1 ;; esac ;;
    name) syntax=1; command_head=body ;;
    body)
      syntax=1
      [ "$word:$kind:$bare" != '{:literal:1' ] || command_head=1 ;;
  esac
  if [ "$frame" -ge 0 ] && [ "${nesting[$frame]}" = case ]; then
    case "${case_phases[$frame]}" in
      subject) syntax=1; case_phases[frame]=in ;;
      in) syntax=1; [ "$word:$kind:$bare" != in:literal:1 ] || case_phases[frame]=pattern ;;
      pattern) syntax=1 ;;
    esac
    if [ "$word:$kind:$bare" = esac:literal:1 ] &&
       { [ "${case_phases[$frame]}" = pattern ] || [ -n "$command_head" ]; }; then
      syntax=1; unset 'closers[frame]' 'nesting[frame]' 'case_phases[frame]'
    fi
  fi
  if [ -z "$syntax" ] && [ -n "$command_head" ] && [ -z "$needs_target" ]; then
    if [ "$word:$kind:$bare" = case:literal:1 ]; then
      frame=${#closers[@]}; nesting[frame]=case; closers[frame]=esac; case_phases[frame]=subject
      syntax=1
    elif [[ $word =~ $name_re ]] && [[ $word == *=* ]]; then :
    else
      case "$word:$kind:$bare" in
        if:literal:1 | then:literal:1 | elif:literal:1 | else:literal:1 | while:literal:1 | until:literal:1 | do:literal:1 | '{:literal:1' | '!:literal:1') ;;
        time:literal:1) syntax=1; command_head=time ;;
        function:literal:1) syntax=1; command_head=name ;;
        *) command_head="" ;;
      esac
    fi
  fi
  index=${#tokens[@]}; token_commands[index]=$command_id; expansion_words[index]=$expansion
  unquoted_words[index]=$bare; tokens[index]=$word; kinds[index]=$kind; token_syntax[index]=$syntax
}

environment_dump() { # command kind; arguments are already decoded data
  local LC_ALL=C i=0 c next quote="" word="" expansion="" active="" kind=literal compound="" bare=1 quoted=""
  local j start=0 end n fd redirection_kind target proc output input_redirect input_escaped pos program value named flags
  local mode pattern_count pattern filter_ok stage=0 text text_length span span_re comment_span options_ended null_output syntax_head program_pos stdin_program source_pos data_source piped_source="" pipeline="" heredoc_input=${heredoc_input:-}
  local receiver receiver_pattern receiver_option receiver_named
  local unsupported="" scan candidate limit producer_end code incoming_sources="" file_output file_body redirect_evidence head_start main_start script_pos forwarded_argument=""
  local heredoc_op="" heredoc_origin delimiter line remaining doc body found needs_target="" main_text main_required="" body_start body_end
  local name_re='^[A-Za-z_][A-Za-z0-9_]*(=.*)?$'
  local filter_re='^([A-Za-z_][A-Za-z0-9_]*=?|\^[A-Za-z_][A-Za-z0-9_]*=|\^\([A-Za-z_][A-Za-z0-9_]*(\|[A-Za-z_][A-Za-z0-9_]*)+\)=)$'
  local ordinary_span_re=$'^[^\'"\\\\$`# \t\r\n;|()<>&]+'
  local single_span_re="^[^']+" ansi_span_re="^[^'\\\\]+" double_span_re='^[^"\\$`]+' comment_span_re=$'^[^\n]+'
  local tokens=() kinds=() unquoted_words=() saved_quotes=() closers=() args=() arg_kinds=() arg_unquoted=() arg_roles=() stage_roles=() stage_args=() stage_kinds=() stage_unquoted=() heredocs=() heredoc_tabs=() heredoc_expand=() heredoc_bodies=() heredoc_starts=() body_ids=() stage_sources=() stage_stdin=() executable_texts=() executable_stages=()
  local body_decisions=()
  local command_id=0 command_count=1 owner record index redirect write reference
  local token_commands=() expansion_words=() arg_expansions=() stage_expansions=()
  local command_domains=() token_syntax=() ordered_syntax=() arg_syntax=()
  local command_head=1 saved_heads=() case_phases=()
  local arithmetic_starts=() arithmetic_tokens=() arithmetic_counts=() arithmetic_forms=() arithmetic_active=() arithmetic_docs=() rejected_arithmetic=()
  local record_first=() record_last=() token_next=()
  local saved_commands=() saved_words=() saved_expansions=() saved_kinds=() saved_bare=() saved_quoted=() saved_targets=() nesting=() arithmetic_levels=()
  local ordered_tokens=() ordered_kinds=() ordered_unquoted=() ordered_expansions=() ordered_bodies=()
  local command_writes=()
  local registry_root="" command_offset
  if [ -z "${environment_registry_active:-}" ]; then
    local environment_registry_active=1 command_serial=0
    local write_owners=() write_targets=() write_kinds=() write_bodies=() write_states=()
    local reference_owners=() reference_targets=() reference_kinds=() command_receivers=() command_unresolved=()
    registry_root=1
  fi
  local private_inputs=()
  local starts=() ends=() separators=() decisions=() literal_inputs=() input_bodies=() file_outputs=() executable_contexts=()
  if [ "${2:-}" = forwarded ]; then
    forwarded_argument=1
    set -- "$1" conservative "${@:3}"
  fi
  # Only a forwarded body can inherit its caller's registered heredoc origin.
  [ "$#" -ge 3 ] || heredoc_input=""
  [ "${2:-}" != conservative ] || compound=1
  if [ "$1" = argv ]; then
    tokens=(${command_argv[@]+"${command_argv[@]}"})
    for ((i=0; i<${#tokens[@]}; i++)); do kinds[i]=literal; unquoted_words[i]=""; token_commands[i]=0; expansion_words[i]=""; done
  else
    if [ "$1" = expansions ]; then quote='"'; command_domains[0]=data; fi
    text=$command_text
    text_length=${#text}
    while [ "$i" -lt "$text_length" ]; do
      [ "$1" != expansions ] || [ "${#closers[@]}" -ne 0 ] || kind=heredoc-data
      case "$quote" in
        "'") span_re=$single_span_re ;;
        ansi) span_re=$ansi_span_re ;;
        '"') span_re=$double_span_re ;;
        arithmetic) span_re='^[^$()`]+' ;;
        *) span_re=$ordinary_span_re ;;
      esac
      # Copy literal spans once. Marker handlers keep the quote and routing
      # decisions; growing a word byte by byte exceeds the hook budget.
      if [[ ${text:$i} =~ $span_re ]]; then
        span=${BASH_REMATCH[0]}; word=$word$span; active=1
        if [ -z "$quote" ]; then expansion=$expansion$span; else expansion=$expansion' '; fi
        i=$((i + ${#span}))
        continue
      fi
      c=${text:$i:1}; i=$((i + 1)); next=${text:$i:1}
      if [ "$quote" = ansi ]; then
        case "$c" in
          "'") quote="" ;;
          '\') kind=ansi-escaped; word=$word$c$next; expansion=$expansion'  '; i=$((i + 1)) ;;
          *) word=$word$c; expansion=$expansion' ' ;;
        esac
        continue
      fi
      if [ "$quote" = "'" ]; then
        if [ "$c" = "'" ]; then quote=""; else word=$word$c; expansion=$expansion' '; fi
        continue
      fi
      if [ "$c" = '\' ]; then
        if [ "$i" -ge "$text_length" ]; then [ "$kind" = ansi-escaped ] || kind=unknown; break; fi
        i=$((i + 1))
        [ "$next" = $'\n' ] || { bare=""; quoted=1; }
        if [ "$quote" = '"' ]; then
          case "$next" in '"' | '\' | '$' | '`' | $'\n') ;; *) word=$word$c ;; esac
        fi
        [ "$next" = $'\n' ] || { word=$word$next; expansion=$expansion' '; active=1; }
        continue
      fi
      # A child command has its own record. The enclosing word, including a
      # pending redirect operand, resumes without treating child output as text.
      n=${#closers[@]}
      if [ -z "$quote" ] && { [ "$c" = ')' ] || { [ "$n" -gt 0 ] && [ "$c" = '`' ] && [ "${closers[$((n - 1))]}" = '`' ]; }; }; then
        environment_collect_word
        word=""; expansion=""; active=""; kind=literal; bare=1; quoted=""
      fi
      n=${#closers[@]}
      if [ "$n" -gt 0 ] && [ "${nesting[$((n - 1))]:-}" = case ] &&
         [ "${case_phases[$((n - 1))]}" = pattern ] && [ "$c" = ')' ] && [ -z "$quote" ]; then
        case_phases[n-1]=arm; command_head=1; c=';'
      fi
      if [ "$n" -gt 0 ] && [ "${nesting[$((n - 1))]:-}" = substitution ] &&
         [ "$c" = "${closers[$((n - 1))]}" ] && [ -z "$quote" ]; then
        token_commands[${#tokens[@]}]=$command_id; expansion_words[${#tokens[@]}]=""; token_syntax[${#tokens[@]}]=""; unquoted_words[${#tokens[@]}]=""; tokens[${#tokens[@]}]=';'; kinds[${#kinds[@]}]=operator
        n=$((n - 1)); command_id=${saved_commands[$n]}; quote=${saved_quotes[$n]}
        word=${saved_words[$n]}; expansion=${saved_expansions[$n]}; kind=${saved_kinds[$n]}
        bare=${saved_bare[$n]}; quoted=${saved_quoted[$n]}; needs_target=${saved_targets[$n]}; command_head=${saved_heads[$n]}; active=1
        unset 'closers[n]' 'nesting[n]'
        continue
      fi
      if [ -z "${rejected_arithmetic[$((i - 1))]:-}" ] &&
         { { [ "$c" = '$' ] && [ "$next" = '(' ] && [ "${text:$((i + 1)):1}" = '(' ]; } ||
           { [ "$c" = '(' ] && [ "$next" = '(' ] && [ -z "$quote$active" ] && [ -n "$command_head" ]; }; }; then
        saved_quotes[n]=$quote; closers[n]=arithmetic; nesting[n]=arithmetic; arithmetic_levels[n]=1
        arithmetic_starts[n]=$((i - 1)); arithmetic_tokens[n]=${#tokens[@]}; arithmetic_counts[n]=$command_count
        saved_words[n]=$word; saved_expansions[n]=$expansion; saved_kinds[n]=$kind
        saved_bare[n]=$bare; saved_quoted[n]=$quoted; saved_commands[n]=$command_id
        saved_targets[n]=$needs_target; saved_heads[n]=$command_head; arithmetic_forms[n]=$c; arithmetic_active[n]=$active; arithmetic_docs[n]=${#heredocs[@]}
        quote=arithmetic; expansion=$expansion' '; [ "$kind" = ansi-escaped ] || kind=unknown; active=1
        if [ "$c" = '$' ]; then word=$word'$(('; i=$((i + 2)); else word='(('; i=$((i + 1)); fi
        continue
      fi
      if { [ "$c" = '$' ] && [ "$next" = '(' ]; } || [ "$c" = '`' ]; then
        saved_commands[n]=$command_id; saved_quotes[n]=$quote; saved_words[n]=$word'$(...)'
        saved_expansions[n]=$expansion' '; saved_kinds[n]=$kind; [ "$kind" = ansi-escaped ] || saved_kinds[n]=unknown; saved_bare[n]=$bare
        saved_quoted[n]=$quoted; saved_targets[n]=$needs_target; saved_heads[n]=$command_head; nesting[n]=substitution
        if [ "$c" = '$' ]; then closers[n]=')'; i=$((i + 1)); else closers[n]='`'; fi
        command_id=$command_count; command_count=$((command_count + 1))
        word=""; expansion=""; active=""; kind=literal; bare=1; quoted=""; quote=""; needs_target=""; command_head=1; compound=1
        continue
      fi
      if [ "$quote" = arithmetic ]; then
        n=$((n - 1)); word=$word$c
        case "$c" in
          '(') arithmetic_levels[n]=$((arithmetic_levels[n] + 1)) ;;
          ')')
            arithmetic_levels[n]=$((arithmetic_levels[n] - 1))
            if [ "${arithmetic_levels[$n]}" -eq 0 ]; then
              if [ "$next" = ')' ]; then
                word=$word')'; i=$((i + 1)); quote=${saved_quotes[$n]}
                if [ "${arithmetic_forms[$n]}" = '(' ]; then
                  environment_collect_word; token_syntax[${#tokens[@]}-1]=1
                  word=""; expansion=""; active=""; kind=literal; command_head=""
                fi
                unset 'closers[n]' 'nesting[n]'
              else
                # Bash retries this opener as a subshell in substitution.
                # Rewind the same collector; speculative operand roles prove nothing.
                i=${arithmetic_starts[$n]}; rejected_arithmetic[i]=1; index=${arithmetic_tokens[$n]}
                tokens=("${tokens[@]:0:index}"); kinds=("${kinds[@]:0:index}")
                token_commands=("${token_commands[@]:0:index}"); expansion_words=("${expansion_words[@]:0:index}")
                unquoted_words=("${unquoted_words[@]:0:index}")
                token_syntax=("${token_syntax[@]:0:index}")
                for j in "${!body_ids[@]}"; do [ "$j" -lt "$index" ] || unset 'body_ids[j]'; done
                doc=${arithmetic_docs[$n]}
                heredocs=("${heredocs[@]:0:doc}"); heredoc_tabs=("${heredoc_tabs[@]:0:doc}")
                heredoc_expand=("${heredoc_expand[@]:0:doc}"); heredoc_bodies=("${heredoc_bodies[@]:0:doc}")
                heredoc_starts=("${heredoc_starts[@]:0:doc}")
                command_count=${arithmetic_counts[$n]}; command_id=${saved_commands[$n]}; quote=${saved_quotes[$n]}
                word=${saved_words[$n]}; expansion=${saved_expansions[$n]}; kind=${saved_kinds[$n]}
                bare=${saved_bare[$n]}; quoted=${saved_quoted[$n]}; needs_target=${saved_targets[$n]}; command_head=${saved_heads[$n]}
                active=${arithmetic_active[$n]}
                unset 'closers[n]' 'nesting[n]'
              fi
            fi ;;
        esac
        continue
      fi
      if [ "$quote" = '"' ]; then
        if [ "$c" = '"' ] && { [ "$1" != expansions ] || [ "${#closers[@]}" -ne 0 ]; }; then quote=""; else word=$word$c; expansion=$expansion' '; [ "$c" != '$' ] || [ "$kind" = ansi-escaped ] || kind=unknown; fi
        continue
      fi
      case "$c" in
        "'" | '"') quote=$c; active=1; bare=""; quoted=1; continue ;;
        '$')
          case "$next" in
            "'" | '"')
              quoted=1; quote=$next; [ "$next" != "'" ] || quote=ansi
              # Dollar arguments keep their conservative kind. Only the
              # existing command-head selector can use the literal word.
              [ "$kind" != literal ] || kind=dollar-literal
              i=$((i + 1)) ;;
            *) [ "$kind" = ansi-escaped ] || kind=unknown; word=$word$c ;;
          esac
          active=1; bare=""; continue ;;
        '#')
          if [ -z "$active" ]; then
            if [[ ${text:$i} =~ $comment_span_re ]]; then
              comment_span=${BASH_REMATCH[0]}; i=$((i + ${#comment_span}))
            fi
            continue
          fi ;;
      esac
      case "$c" in
        ' ' | $'\t' | $'\r' | $'\n' | ';' | '&' | '|' | '(' | ')' | '<' | '>')
          redirection_kind=operator
          if [ -n "$heredoc_op" ] && [ -n "$active" ]; then
            [ "$kind" != ansi-escaped ] || return 0
            doc=${#heredocs[@]}
            heredocs[doc]=$word; heredoc_tabs[doc]=$heredoc_op
            heredoc_expand[doc]=""; [ -n "$quoted" ] || heredoc_expand[doc]=1
            body_ids[$heredoc_origin]=$doc
            heredoc_op=""
          # A numeric target remains operand data before a compact redirect.
          # Only a bare word outside that target can establish a descriptor.
          elif [ -z "$needs_target" ] && { [ "$c" = '<' ] || [ "$c" = '>' ]; } && [ -n "$active" ] &&
               [ -n "$bare" ] && [ "$kind" = literal ] && [[ $word =~ ^[0-9]+$ ]]; then
            redirection_kind=operator-explicit-other
            [ "$word" != 2 ] || redirection_kind=operator-stderr
            active=""
          fi
          if [ -n "$active" ]; then
            environment_collect_word
            needs_target=""
          fi
          word=""; expansion=""; active=""; kind=literal; bare=1; quoted=""
          case "$c" in ' ' | $'\t' | $'\r') continue ;; esac
          n=${#closers[@]}
          if [ "$n" -gt 0 ] && [ "${nesting[$((n - 1))]}" = case ]; then
            if [ "${case_phases[$((n - 1))]}" = pattern ]; then
              case "$c" in '|' | '(') continue ;; esac
            elif [ "$c$next" = ';;' ] || { [ "$c" = ';' ] && [ "$next" = '&' ]; }; then
              case_phases[n-1]=pattern; i=$((i + 1))
              [ "${text:$i:1}" != '&' ] || i=$((i + 1))
            fi
          fi
          case "$c" in
            '(') compound=1; n=${#closers[@]}; saved_quotes[n]=""; closers[n]=')'; nesting[n]=group; c=';' ;;
            ')')
              compound=1; n=${#closers[@]}
              if [ "$n" -gt 0 ]; then quote=${saved_quotes[$((n - 1))]}; unset 'closers[n-1]' 'nesting[n-1]'; fi
              [ -z "$quote" ] || bare=""
              c=';' ;;
            $'\n')
              c=';'
              # Keep every declared body in order. Quoting controls outer
              # expansion; the receiving program decides execution later.
              for ((doc=0; doc<${#heredocs[@]}; doc++)); do
                [ -z "${heredoc_bodies[$doc]+present}" ] || continue
                delimiter=${heredocs[$doc]}; body=""; found=""
                heredoc_starts[doc]=$i
                while [ "$i" -lt "$text_length" ]; do
                  remaining=${text:$i}; line=${remaining%%$'\n'*}
                  i=$((i + ${#line})); [ "$i" -ge "$text_length" ] || i=$((i + 1))
                  if [ "${heredoc_tabs[$doc]}" = '<<-' ]; then
                    while [[ $line == $'\t'* ]]; do line=${line:1}; done
                  fi
                  if [ "$line" = "$delimiter" ]; then found=1; break; fi
                  body=$body$line$'\n'
                done
                [ -n "$found" ] || return 0
                heredoc_bodies[doc]=$body
              done ;;
            *)
              case "$c$next" in
                '&&' | '||' | '>>' | '>&' | '<&' | '<>' | '&>' | '<<') c=$c$next; i=$((i + 1)) ;;
              esac
              if [ "$c" = '&>' ] && [ "${text:$i:1}" = '>' ]; then c=$c'>'; i=$((i + 1)); fi
              if [ "$c" = '<<' ] && [ "${text:$i:1}" = '<' ]; then c='<<<'; i=$((i + 1)); fi
              if [ "$c" = '<<' ]; then
                compound=1
                if [ "${text:$i:1}" = - ]; then c='<<-'; i=$((i + 1)); fi
                heredoc_op=$c; heredoc_origin=${#tokens[@]}
              fi ;;
          esac
          token_commands[${#tokens[@]}]=$command_id; expansion_words[${#tokens[@]}]=""; token_syntax[${#tokens[@]}]=""; unquoted_words[${#tokens[@]}]=""; tokens[${#tokens[@]}]=$c
          kinds[${#kinds[@]}]=$redirection_kind
          case "$c" in '<'* | '>'* | '&>'*) needs_target=1 ;; *) needs_target="" ;; esac
          case "$c" in ';' | '|' | '&&' | '||' | '&') command_id=$command_count; command_count=$((command_count + 1)); command_head=1 ;; esac ;;
        *) word=$word$c; expansion=$expansion$c; active=1 ;;
      esac
    done
    [ -z "$quote" ] && [ "${#closers[@]}" -eq 0 ] || compound=1
    environment_collect_word
  fi
  # A shell can end a submission before a registered body is read. Evidence
  # must exist before its identifier reaches either expansion or input checks.
  [ -z "$heredoc_op" ] || return 0
  # A forwarded local body cannot gain permission from a later receiver.
  # Check its complete source before expansion or input interpretation.
  if [ -n "$forwarded_argument" ] && [ "${#heredocs[@]}" -gt 0 ] &&
     environment_main_evidence "$text" "${@:3}"; then return 0; fi
  for ((doc=0; doc<${#heredocs[@]}; doc++)); do
    [ -n "${heredoc_bodies[$doc]+present}" ] || return 0
    [ -z "${heredoc_expand[$doc]}" ] || {
      local command_text=${heredoc_bodies[$doc]:-}
      if [ "$#" -ge 3 ]; then
        if environment_dump expansions conservative "${@:3}"; then return 0; fi
      else
        if environment_dump expansions conservative; then return 0; fi
      fi
    }
  done
  literal_inputs=(${heredoc_bodies[@]+"${heredoc_bodies[@]}"})
  for ((doc=3; doc<=$#; doc++)); do
    n=${#literal_inputs[@]}; literal_inputs[n]=${!doc}
    incoming_sources="$incoming_sources $n"
  done
  [ "${#heredocs[@]}" -eq 0 ] || heredoc_input=1
  main_text=${text:-}
  # Group each complete command by identity, retaining its original words
  # and redirect origins even when child records appeared between them.
  for ((i=0; i<${#tokens[@]}; i++)); do
    record=${token_commands[$i]}
    if [ -n "${record_last[$record]+present}" ]; then token_next[${record_last[$record]}]=$i
    else record_first[record]=$i; fi
    record_last[record]=$i
  done
  for ((record=0; record<command_count; record++)); do
    start=${#ordered_tokens[@]}; redirect=end
    for ((i=${record_first[$record]:--1}; i>=0; i=${token_next[$i]:--1})); do
      if [ "${kinds[$i]}" = operator ]; then
        case "${tokens[$i]}" in
          '|' | ';' | '&&' | '||' | '&') redirect=${tokens[$i]}; continue ;;
        esac
      fi
      index=${#ordered_tokens[@]}; ordered_tokens[index]=${tokens[$i]}; ordered_kinds[index]=${kinds[$i]}
      ordered_unquoted[index]=${unquoted_words[$i]}; ordered_expansions[index]=${expansion_words[$i]:-}; ordered_syntax[index]=${token_syntax[$i]:-}
      [ -z "${body_ids[$i]+present}" ] || ordered_bodies[index]=${body_ids[$i]}
    done
    starts[record]=$start; ends[record]=${#ordered_tokens[@]}; separators[record]=$redirect
    [ "$redirect" != '|' ] || pipeline=1
    index=${#ordered_tokens[@]}; ordered_tokens[index]=$redirect; ordered_kinds[index]=operator
    ordered_unquoted[index]=""; ordered_expansions[index]=""; ordered_syntax[index]=""
  done
  tokens=("${ordered_tokens[@]}"); kinds=("${ordered_kinds[@]}"); unquoted_words=("${ordered_unquoted[@]}")
  expansion_words=("${ordered_expansions[@]}"); token_syntax=("${ordered_syntax[@]}"); body_ids=()
  for ((index=0; index<${#ordered_tokens[@]}; index++)); do
    [ -z "${ordered_bodies[$index]+present}" ] || body_ids[index]=${ordered_bodies[$index]}
  done
  command_offset=$command_serial; command_serial=$((command_serial + command_count))
  # Forwarded input has no local data contract for the complete pipeline.
  if [ -n "$pipeline" ] && [ -n "$incoming_sources" ] && [ -n "$heredoc_input" ] && environment_main_evidence "$text" "${@:3}"; then return 0; fi
  for ((stage=0; stage<${#starts[@]}; stage++)); do
    owner=$((command_offset + stage))
    # Heredoc expansion scans have one enclosing data record. Only their
    # independently collected substitution children are executable contexts.
    if [ "${command_domains[$stage]:-command}" = data ]; then
      decisions[stage]=other; stage_sources[stage]=""; stage_stdin[stage]=""
      continue
    fi
    start=${starts[$stage]}; end=${ends[$stage]}; args=(); arg_kinds=(); arg_unquoted=(); arg_expansions=(); arg_roles=(); arg_syntax=()
    private_inputs=(); proc=""; output=""; input_redirect=""; input_escaped=""; mode=other; program=""; program_pos=""; data_source=""; file_output=""; file_body=""; redirect_evidence=""; command_writes=()
    for ((j=start; j<end; j++)); do
      case "${kinds[$j]}" in operator | operator-stderr | operator-explicit-other)
        fd=${kinds[$j]}
        j=$((j + 1)); target=${tokens[$j]:-}
        case "${tokens[$((j - 1))]}" in
          '<' | '<>')
            input_redirect=1
            private_inputs[${#private_inputs[@]}]=$target
            [ "${kinds[$j]:-}" != ansi-escaped ] || input_escaped=1
            [[ $target != /proc/*/environ ]] || proc=1
            [ "${tokens[$((j - 1))]}" != '<>' ] || output=1 ;;
          '<&') input_redirect=1 ;;
          '<<' | '<<-')
            input_redirect=1
            doc=${body_ids[$((j - 1))]:-}
            [ -n "$doc" ] || return 0
            if [ "$fd" = operator ] && [ "${tokens[$((j - 1))]}" = '<<' ] &&
               [ "${kinds[$j]:-}" = literal ]; then
              file_body=1; [ -z "${heredoc_expand[$doc]}" ] || file_body=expanding
            fi
            data_source="$data_source $doc" ;;
          '<<<')
            input_redirect=1; doc=${#literal_inputs[@]}; literal_inputs[doc]=$target
            data_source="$data_source $doc" ;;
          '>')
            [ "$fd" = operator-stderr ] || output=1
            if [ "$fd" = operator ] && [ "${kinds[$j]:-}" = literal ]; then file_output=1; fi ;;
          '>>')
            [ "$fd" = operator-stderr ] || output=1
            if [ "$fd" = operator ] && [ "${kinds[$j]:-}" = literal ]; then file_output=append; fi ;;
          '>&') [ "$fd" = operator-stderr ] || output=1 ;;
          '&>' | '&>''>') output=1 ;;
        esac
        redirect=${tokens[$((j - 1))]}
        case "$redirect" in
          '<' | '<>')
            reference=${#reference_owners[@]}; reference_owners[reference]=$owner
            reference_targets[reference]=$target; reference_kinds[reference]=${kinds[$j]:-unknown} ;;
        esac
        write=""
        case "$redirect" in
          '>' | '>>' | '<>' | '&>' | '&>''>') write=1 ;;
          '>&') [[ $target =~ ^[0-9]+$ ]] || [ "$target" = - ] || write=1 ;;
        esac
        if [ -n "$write" ]; then
          write=${#write_owners[@]}; write_owners[write]=$owner; write_targets[write]=$target
          write_kinds[write]=${kinds[$j]:-unknown}; write_bodies[write]=""; write_states[write]=unread
          # Only a literal stdout overwrite can carry the cat heredoc class.
          if [ "$redirect:$fd" = '>:operator' ]; then command_writes[${#command_writes[@]}]=$write; fi
        fi
        if environment_main_evidence "$target"; then redirect_evidence=1; fi
        continue ;;
      esac
      n=${#args[@]}
      args[n]=${tokens[$j]}; arg_kinds[n]=${kinds[$j]}; arg_unquoted[n]=${unquoted_words[$j]}; arg_expansions[n]=${expansion_words[$j]:-}; arg_syntax[n]=${token_syntax[$j]:-}
    done
    # An empty recorded stage cannot prove how literal input will execute.
    # Existing boundaries select this main-refusal path before head parsing.
    if [ "${#literal_inputs[@]}" -gt 0 ] && [ "$stage" -gt 0 ] && [ "$start" -eq "$end" ] &&
       [ "${separators[$((stage - 1))]}" = '|' ] && [ "${separators[$stage]}" = '&' ] &&
       environment_main_evidence "${literal_inputs[@]}"; then return 0; fi
    environment_head "$1"
    main_start=0
    # Main excluded initial assignments before its first reserved head.
    # Later unsupported stages remain part of that complete suffix.
    [ -n "$unsupported" ] || main_start=$head_start
    if [ -n "$syntax_head" ]; then unsupported=1; compound=1; fi
    if [ "$pos" -ge "${#args[@]}" ]; then
      program=opaque
    fi
    environment_producer "$1" "$unsupported${2:-}" command-head
    if [ -n "$program_pos" ]; then
      for ((j=0; j<program_pos; j++)); do
        [ "${arg_roles[$j]}" = unset-launcher ] || arg_roles[j]=prefix
      done
      arg_roles[$program_pos]=command
      for ((j=program_pos+1; j<${#args[@]}; j++)); do arg_roles[j]=argument; done
    fi
    environment_program_text
    # Preserve main's known-dump evidence for brace arguments without giving
    # those arguments executable roles or applying the head expansion rule.
    for ((j=pos; j<${#args[@]}; j++)); do
      [ "${arg_roles[$j]:-}" = argument ] && [ -n "${arg_unquoted[$j]}" ] || continue
      case "${arg_expansions[$j]}" in *'{'*','*'}'*)
        if environment_main_evidence "${args[$j]}"; then mode=dump-unknown; fi ;;
      esac
    done
    command_receivers[owner]=$receiver; command_unresolved[owner]=""
    if [ "$program" = opaque ] && [ "$head_start" -lt "${#args[@]}" ] && [ -z "$syntax_head" ]; then
      command_unresolved[owner]=1
    elif [ "$pos" -lt "${#args[@]}" ] && [ -z "$program" ] && [ -z "$syntax_head" ]; then
      command_unresolved[owner]=1
    elif [ -n "$program_pos" ] && [ "${arg_kinds[$program_pos]}" != literal ]; then
      command_unresolved[owner]=1
    fi
    # A selected ordinary receiver never executes a shell-name argument.
    if [ "$receiver" = shell ]; then
      for ((j=pos; j<${#args[@]}; j++)); do
        reference=${#reference_owners[@]}; reference_owners[reference]=$owner
        reference_targets[reference]=${args[$j]}; reference_kinds[reference]=${arg_kinds[$j]}
      done
    fi
    if [ "$program" = tee ]; then
      options_ended=""
      for ((j=pos; j<${#args[@]}; j++)); do
        if [ -z "$options_ended" ]; then
          case "${args[$j]}" in --) options_ended=1; continue ;; -*) continue ;; esac
        fi
        [ "${args[$j]}" != - ] || continue
        write=${#write_owners[@]}; write_owners[write]=$owner; write_targets[write]=${args[$j]}
        write_kinds[write]=${arg_kinds[$j]}; write_bodies[write]=""; write_states[write]=unread
      done
    fi
    # Supported shell source keeps this classification check in its queue.
    # Other unclassified forwarded argv retains the complete read evidence.
    if [ "$mode" = unclassified-forwarded ]; then
      mode=other
      if [ -z "$stdin_program" ] && { [ -n "$redirect_evidence" ] || environment_main_evidence "${args[@]}"; }; then mode=dump-unknown; fi
    fi
    # Keep pipe input before the body fallback: an opaque receiver can execute it.
    if [ "$stage" -gt 0 ] && [ "${separators[$((stage - 1))]}" = '|' ]; then
      data_source="$data_source$piped_source"
    fi
    file_outputs[stage]=$file_output
    # The approved data and file-writing classes bypass this fallback.
    # File data must stay out of later bodies' complete-command fallback.
    for doc in $data_source; do
      [ "$doc" -lt "${#heredocs[@]}" ] || continue
      # A literal output redirect can still feed the next pipe receiver.
      if [ -z "${2:-}$unsupported$incoming_sources" ] && [ "$1" = shell ] &&
         [ "$receiver" = data ] && [ "$mode" = other ] && [ "${#args[@]}" -eq 1 ] &&
         [ "${separators[$stage]}" != "|" ] &&
         [ "$file_output" = 1 ] && [ "$file_body" = 1 ] && [ -z "$redirect_evidence" ] &&
         [ "$program_pos" = 0 ] && [ "$head_start" -eq 0 ] && [ "${arg_kinds[0]}" = literal ] &&
         [ "$data_source" = " $doc" ]; then
        for write in ${command_writes[@]+"${command_writes[@]}"}; do write_bodies[write]=${heredoc_bodies[$doc]}; write_states[write]=readable; done
        body=${heredoc_bodies[$doc]}; body_start=${heredoc_starts[$doc]}; body_end=$((body_start + ${#body}))
        main_text=${main_text:0:body_start}${body//[!$'\n']/ }${main_text:body_end}
        continue
      fi
      # Input can execute downstream. A later fallback needs the original
      # body even when an earlier interpreter classifies it in its own language.
      if [ "$1" = shell ] && [ -z "${2:-}$unsupported$incoming_sources" ] &&
         [ "$mode" = other ] && [ -z "$redirect_evidence$stdin_program" ]; then
        case "$receiver" in
          interpreter)
            if environment_receiver_evidence "${literal_inputs[$doc]}"; then return 0; fi
            [ "${body_decisions[$doc]:-}" = fallback ] || body_decisions[doc]=interpreter
            continue ;;
          data)
            if [ "${#heredocs[@]}" -eq 1 ] && [ "$data_source" = " 0" ] &&
               [ "$program_pos" = 0 ] && [ "$head_start" -eq 0 ] && [ "${arg_kinds[0]}" = literal ] &&
               { [ "$file_body" = 1 ] || { [ -z "$input_redirect" ] && [ -n "$piped_source" ] &&
                 [ -z "${heredoc_expand[$doc]}" ] && [ "${heredoc_tabs[$doc]}" = '<<' ]; }; }; then continue; fi ;;
        esac
      fi
      main_required=1
      body_decisions[doc]=fallback
    done
    stage_stdin[stage]=$stdin_program; stage_sources[stage]=$data_source
    scan=$unsupported
    if [ "$receiver" = shell ] || [ "$program" = opaque ]; then scan=1; fi
    if [ -n "$scan" ]; then
      case "$mode" in dump-*) return 0 ;; esac
      [ -z "$redirect_evidence" ] || return 0
      stage_args=(${args[@]+"${args[@]}"}); stage_kinds=(${arg_kinds[@]+"${arg_kinds[@]}"})
      stage_unquoted=(${arg_unquoted[@]+"${arg_unquoted[@]}"})
      stage_expansions=(${arg_expansions[@]+"${arg_expansions[@]}"})
      stage_roles=(${arg_roles[@]+"${arg_roles[@]}"})
      script_pos=""
      if [ "$1" = shell ] && [ -z "${2:-}$compound$incoming_sources" ] &&
         [[ $program =~ ^(bash|sh|dash|zsh|ksh)$ ]] && [ -z "$source_pos$syntax_head" ] &&
         [ "${#starts[@]}" -eq 1 ] && [ -z "$input_redirect" ] &&
         [ "${stage_kinds[$pos]:-}" = literal ] && [[ ${stage_args[$pos]:-} != [-+]* ]] &&
         [ "${stage_roles[$pos]:-}" = argument ]; then script_pos=$pos; fi
      for ((candidate=0; candidate<${#stage_args[@]}; candidate++)); do
        [ "${stage_kinds[$candidate]}" != ansi-escaped ] || return 0
        [ "$candidate" -ge "$main_start" ] || continue
        value=${stage_args[$candidate]}
        case "${stage_roles[$candidate]}" in
          unset-launcher) continue ;;
          executable) continue ;;
          prefix) [ -n "$unsupported" ] || continue ;;
          command)
            # The shared producer already refused optional conservative
            # clean reads. Its retained receipt decision owns this command.
            [ "$program" != set ] || continue ;;
        esac
        # The approved ordinary quoted-data class has the same recorded
        # receiver, role and argument bounds. It recognizes no inner words.
        if [ "$1" = shell ] && [ -z "${2:-}$compound" ] && [ "$program" = bash ] && [ -z "$source_pos" ] && [ -z "$syntax_head" ] &&
           [ "${#stage_args[@]}" -eq 3 ] && [ "$candidate" -eq 2 ] && [ "${#starts[@]}" -eq 1 ] &&
           [ "$start" -eq 0 ] && [ "$end" -eq 3 ] && [ "${stage_kinds[1]}" = literal ] &&
           [ "${stage_roles[0]}:${stage_roles[1]}" = command:argument ] &&
           [ "${stage_roles[$candidate]}" = argument ] && [ "${stage_kinds[$candidate]}" = literal ] &&
           [ -z "${stage_unquoted[$candidate]}" ] && [ -z "$input_redirect$output" ] &&
           ! environment_main_evidence --head "${stage_expansions[$candidate]}"; then continue; fi
        if [ -z "$script_pos" ] || [ "$candidate" -le "$script_pos" ] ||
           [ "${stage_roles[$candidate]}:${stage_kinds[$candidate]}" != argument:literal ]; then
          if environment_main_evidence "$value"; then return 0; fi
          continue
        fi
        # Waiter launchers execute forwarded argv. Keep each selected program
        # beside its operands before considering a quoted command string.
        limit=${#stage_args[@]}
        args=("${stage_args[@]:candidate:limit-candidate}")
        arg_kinds=("${stage_kinds[@]:candidate:limit-candidate}")
        arg_unquoted=("${stage_unquoted[@]:candidate:limit-candidate}")
        arg_expansions=("${stage_expansions[@]:candidate:limit-candidate}")
        arg_roles=()
        program=""; pos=0; mode=other; producer_end=0; program_pos=""
        environment_producer shell "$scan"
        environment_program_text
        [ -z "$stdin_program" ] || stage_stdin[stage]=1
        case "$mode" in dump-*) return 0 ;; esac
        if [ "$candidate" -gt "$((script_pos + 1))" ] && [ -z "$output" ] &&
           [ -z "${stage_unquoted[$candidate]}" ] && [ "$producer_end" -eq 1 ]; then
          code=${#executable_texts[@]}
          executable_texts[code]=${stage_args[$candidate]}; executable_stages[code]=$stage
          executable_contexts[code]=forwarded
        else
          case "${stage_args[$candidate]##*/}" in
            env) ;;
            *) if environment_main_evidence "${stage_args[$candidate]}"; then return 0; fi ;;
          esac
        fi
        [ "$producer_end" -le 1 ] || candidate=$((candidate + producer_end - 2))
      done
      mode=opaque-clean
    fi
    case "$mode" in dump-*) [ -z "$output" ] || mode=unrouted ;; esac
    decisions[stage]=$mode
    piped_source=$data_source
  done
  if [ -n "$main_required" ]; then
    # Mask interpreter bodies only after every consumer has had its turn.
    # A fallback consumer retains the original bytes instead of an earlier
    # language-local decision. Spaces preserve the registry's source offsets.
    for ((doc=0; doc<${#heredocs[@]}; doc++)); do
      [ "${body_decisions[$doc]:-}" = interpreter ] || continue
      body=${heredoc_bodies[$doc]}; body_start=${heredoc_starts[$doc]}; body_end=$((body_start + ${#body}))
      body=${body//[!$'\n']/ }
      main_text=${main_text:0:body_start}$body${main_text:body_end}
    done
    local command_text=$main_text
    if environment_main_command "$1"; then return 0; fi
  fi
  for ((stage=0; stage<${#decisions[@]}; stage++)); do
    data_source=${stage_sources[$stage]}
    data_source="$data_source $incoming_sources"
    input_bodies=()
    for doc in $data_source; do input_bodies[${#input_bodies[@]}]=${literal_inputs[$doc]}; done
    # A command string can start a shell that reads the same stdin.
    for ((code=0; code<${#executable_texts[@]}; code++)); do
      [ "${executable_stages[$code]}" -eq "$stage" ] || continue
      local command_text=${executable_texts[$code]}
      if environment_dump shell "${executable_contexts[$code]:-conservative}" ${input_bodies[@]+"${input_bodies[@]}"}; then return 0; fi
    done
    if [ -n "${stage_stdin[$stage]}" ]; then
      # These identifiers come only from the proved registry. Keep bodies
      # independent: quotes in one program cannot hide another program.
      for doc in $data_source; do
        local command_text=${literal_inputs[$doc]}
        if environment_dump shell conservative; then return 0; fi
      done
    fi
  done
  if [ -n "$registry_root" ]; then
    for ((write=0; write<${#write_owners[@]}; write++)); do
      found=""
      for ((owner=0; owner<command_serial; owner++)); do
        [ "$owner" -ne "${write_owners[$write]}" ] || continue
        if [ -n "${command_unresolved[$owner]:-}" ]; then found=1; break; fi
        [ "${command_receivers[$owner]:-}" = shell ] || continue
        for ((reference=0; reference<${#reference_owners[@]}; reference++)); do
          [ "${reference_owners[$reference]}" -eq "$owner" ] || continue
          if [ "${reference_kinds[$reference]}" != literal ] ||
             { [ "${write_kinds[$write]}" = literal ] && [ "${write_targets[$write]}" = "${reference_targets[$reference]}" ]; }; then found=1; break; fi
        done
        [ -z "$found" ] || break
      done
      [ -n "$found" ] || continue
      # An empty body is readable too; store its presence independently.
      [ "${write_states[$write]}" = readable ] || {
        environment_refusal=(unread-write "${write_targets[$write]}")
        return 0
      }
      local command_text=${write_bodies[$write]}
      # A body is an independent submitted shell program, not another write
      # in this submission's registry. Its own source checks still recurse.
      local environment_registry_active=""
      if environment_dump shell; then return 0; fi
      environment_registry_active=1
    done
  fi
  for ((stage=0; stage<${#decisions[@]}; stage++)); do
    # The retained set decision also needs the recorded closing group and
    # status file write. Future-stage collector facts are now available.
    if [ "${decisions[$stage]}" = opaque-clean ] && [ "$stage" -eq 1 ] && [ "${#starts[@]}" -eq 6 ]; then
      if [ "${tokens[${starts[1]}]:-}" = set ] &&
         { [ "${tokens[0]:-}" != '{' ] || [ "${tokens[${starts[5]}]:-}" != '}' ] ||
           [ "${tokens[${starts[4]}]:-}" != printf ] || [ "${file_outputs[4]:-}" != append ]; }; then
        if environment_main_evidence "${tokens[${starts[1]}]:-}"; then return 0; fi
      fi
    fi
    case "${decisions[$stage]}" in
      unrouted | dump-unknown) return 0 ;;
      dump-lines | dump-nul)
        [ -z "$compound" ] || return 0
        j=$stage
        if [ "${decisions[$stage]}" = dump-nul ]; then
          if [ "${separators[$j]}" != '|' ] || [ "${decisions[$((j + 1))]:-}" != convert ]; then return 0; fi
          j=$((j + 1))
        fi
        if [ "${separators[$j]}" != '|' ] || [ "${decisions[$((j + 1))]:-}" != filter ]; then return 0; fi ;;
    esac
  done
  return 1
}

# Every line this hook writes, and the only place its text lives. The first
# line is the contract a reader parses, `command-safety: <key>=<value>`: a
# stable key for the condition and the value acted on — the missing tool, why
# the payload could not be read, the state of the project policy, or the exit
# status of a check that did not complete. The English explanation follows it.
# The keyed line stands first, at position 1. What a command this hook runs
# wrote is captured where the hook reads it and passed here as the cause, so
# it is replayed under the key rather than ahead of it.
# The EXIT trap below calls this, so the whole message is one group that
# cannot carry a failure out: a write that fails there would leave with the
# writer's status rather than the refusal's, which the harness runs past.
refuse() { # KEY VALUE [CAUSE]
  loading=""
  {
    printf 'command-safety: %s=%s\n' "$1" "$2"
    case "$1=$2" in
      missing-tools=*) echo "the commands ${2//,/, } are required and are not on PATH" ;;
      payload=unreadable) echo "the hook input could not be read" ;;
    cwd=*) echo "the working directory $2 could not be entered" ;;
      payload=invalid-json) echo "the hook input is not valid JSON, or names no command this hook can read" ;;
      payload=invalid-cwd) echo "the payload's working directory is not a string" ;;
        git=unreadable) echo "the Git working directory could not be resolved" ;;
      hook=unlocatable) echo "this hook's own directory could not be read, so its installed dependencies cannot be found" ;;
      settings=no-loader) echo "the command-safety bundle requires the installed commit-guards settings loader" ;;
      support=unreadable) echo "the installed commit-guards support could not be loaded; repair that installation; its diagnostic follows" ;;
      settings=unreadable) echo "the project settings could not be read, so COMMAND_SAFETY_DENY_PATTERN is unknown; the loader's line below names what to fix" ;;
      settings=empty) echo "COMMAND_SAFETY_DENY_PATTERN must be configured" ;;
      settings=invalid-pattern) echo "COMMAND_SAFETY_DENY_PATTERN is not a readable POSIX ERE" ;;
      refused=policy) echo "the command text matches this project's COMMAND_SAFETY_DENY_PATTERN" ;;
      refused=environment-dump)
        case "${environment_refusal[0]}" in
          unread-write)
            printf 'the submitted command may execute written file [%s], whose contents could not be established from this submission\n' "${environment_refusal[1]}"
            echo "use a literal cat heredoc so the submitted contents can be checked, or write and run the file in separate submissions" ;;
          expanded-head)
            printf 'the executable word [%s] contains expansion that could select an environment producer\n' "${environment_refusal[1]}"
            echo "use a literal executable name; for environment producers, use a direct named-variable filter" ;;
          environment-read)
            echo "the command contains a recognized private-file read or a whole-environment read without a proven direct named-variable filter"
            echo "for named non-secret settings, use orch-env NAME DEFAULT; do not read or filter the private file"
            echo "for actual environment producers, read named variables, for example: systemctl --user show-environment | grep '^NAME='"
            echo "nested or unsupported environment routing can refuse conservatively; use the direct filtered form for environment producers" ;;
        esac ;;
      refused=default-policy)
        echo "the command text sets a systemd-run MemoryMax= or MemoryHigh= cap in kilobytes or megabytes, which the hook's default COMMAND_SAFETY_DENY_PATTERN refuses: a cgroup starved by a cap that small can fail a kernel allocation and leave the host's root volume read-only"
        echo "run it with no memory cap, or with a cap in gigabytes; text that only mentions such a cap goes in a file, because matching reads the command text"
        echo "a project that wants another pattern sets COMMAND_SAFETY_DENY_PATTERN in kendex.settings.toml [env] to replace the default, and the value \"^\$\" turns only project-pattern matching off; the fixed environment-dump refusal remains active" ;;
      exit=*) echo "the command safety check could not complete" ;;
    esac
    # The cause a command this hook ran wrote, captured at the site and
    # replayed here: under the keyed line, never ahead of it.
    [ -z "${3:-}" ] || printf '%s\n' "$3"
  } >&2 || :
  case "$1" in
    refused | path) exit 2 ;;
    *)
      echo "Check skipped. Repair the hook installation, tools or payload adapter; retry the command." >&2
      exit 0 ;;
  esac
}
# An exit that is neither a verdict (0) nor a refusal (2) is a check that did
# not complete, and it leaves with a warning. The EXIT trap is what reaches every
# such exit on Bash 3.2 too: an ERR trap inherited through `set -E` fires there
# inside a command substitution even when the substitution stands on the left
# of `||`, which reads the settings loader's guarded probes as failures.
# Support can explicitly exit with a guard's verdict status. While sourcing,
# that status is a support failure, not an executable-command refusal.
loading=""
trap '
  rc=$?
  if [ -n "$loading" ]; then
    cause=$loading
    while IFS= read -r detail <&5 || [ -n "$detail" ]; do
      cause="$cause
  $detail"
    done
    refuse support unreadable "$cause" 2>&3
  fi
  case $rc in 0 | 2) ;; *) refuse exit "$rc" ;; esac
' EXIT
MISSING=""
for dependency in jq git grep cat dirname mktemp rm; do
  command -v "$dependency" >/dev/null 2>&1 || MISSING="$MISSING,$dependency"
done
if ! command -v jq >/dev/null 2>&1 || ! command -v cat >/dev/null 2>&1; then
  refuse missing-tools "${MISSING#,}"
fi
input="$(cat 2>&1)" || refuse payload unreadable "$input"
fields="$(jq -er '
  def command_arg:
    if type == "object" then (.command // .cmd)
    elif type == "string" then
      (try fromjson catch null)
      | if type == "object" then (.command // .cmd) else null end
    else null end;
  . as $payload
  | [.tool_input.command, .tool_input.cmd, (.toolArgs | command_arg), .command, .cmd]
  | map(select(. != null))
  | if length == 0 then error("missing command") else .[0] end
  | . as $submitted
  | if type == "string" then .
    elif type == "array" and all(.[]; type == "string") then join(" ")
    else error("invalid command") end
  | sub("\n+$"; "") as $command
  | (if $payload.cwd != null and ($payload.cwd | type) != "string" then "invalid-cwd" else "valid-cwd" end) as $cwd_state
  | [(if $cwd_state == "invalid-cwd" then "" else ($payload.cwd // "" | sub("\n+$"; "")) end),
     $command, $cwd_state,
     (if ($submitted | type) == "array" then "argv" else "shell" end),
     (if ($submitted | type) == "array" then ($submitted | length), $submitted[] else 0 end)] | @tsv
' <<<"$input" 2>/dev/null)" || refuse payload invalid-json
[ -n "$fields" ] || exit 0
# TSV escapes tabs, newlines and backslashes, so only the field boundary is
# a literal tab. Read each field once instead of repeatedly copying and
# matching the remaining line. printf decodes data without shell evaluation.
# Bash 3.2 can unset the target of an empty %b assignment. Keep empty fields
# as ordinary assignments and decode only nonempty text.
{
  IFS= read -r -d $'\t' cwd || refuse payload invalid-json
  IFS= read -r -d $'\t' command_text || refuse payload invalid-json
  [ -n "$command_text" ] || exit 0
  [ -z "$cwd" ] || printf -v cwd '%b' "$cwd"
  printf -v command_text '%b' "$command_text"
  IFS= read -r -d $'\t' cwd_state || refuse payload invalid-json
  IFS= read -r -d $'\t' command_kind || refuse payload invalid-json
  IFS= read -r -d $'\t' argument_count || refuse payload invalid-json
  command_argv=()
  for ((argument_index=0; argument_index<argument_count; argument_index++)); do
    IFS= read -r -d $'\t' argument || refuse payload invalid-json
    [ -z "$argument" ] || printf -v argument '%b' "$argument"
    command_argv[argument_index]=$argument
  done
} <<<"$fields"$'\t'
if environment_dump "$command_kind"; then
  refuse refused environment-dump
fi
[ "$cwd_state" != invalid-cwd ] || refuse payload invalid-cwd
[ -z "$MISSING" ] || refuse missing-tools "${MISSING#,}"
[ -n "$cwd" ] || cwd="$PWD"
# The requested path is kept: the substitution below holds cd's own words when
# the directory cannot be entered, and the physical path when it can, so the
# refusal names the path it was asked for and replays the cause under it.
requested_cwd="$cwd"
cwd="$(cd -- "$cwd" 2>&1 && pwd -P)" || refuse cwd "$requested_cwd" "$cwd"
# git's words come back in place of the path when it cannot answer, so the
# refusal below has the cause to replay: which .git entry it could not read.
root_status=0
root="$(git -C "$cwd" rev-parse --show-toplevel 2>&1)" || root_status=$?
if [ "$root_status" -ne 0 ]; then
  at="$cwd"
  while [ "$at" != / ]; do
    if [ -e "$at/.git" ] || [ -L "$at/.git" ]; then
      refuse git unreadable "$root"
    fi
    at="${at%/*}"
    [ -n "$at" ] || at=/
  done
  exit 0
fi

lib=
hook_dir="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd)" || refuse hook unlocatable
at="$hook_dir"
levels=0
# Registered hook layouts keep the scope's skills one or two directories
# above hooks. A wider walk can reach executable files outside the install.
while [ "$levels" -lt 3 ] && [ "$at" != "$root" ] && [ "$at" != / ]; do
  candidate="$at/skills/commit-guards/scripts/lib"
  if [ -f "$candidate/common.sh" ] && [ -f "$candidate/settings.sh" ]; then
    lib="$candidate"
    break
  fi
  at="${at%/*}"
  [ -n "$at" ] || at=/
  levels=$((levels + 1))
done
if [ -z "$lib" ]; then
  # Choose the shared scope once. A global hook can use HOME's installed
  # dependency, but cannot source a project selected by the payload.
  case "$hook_dir" in
    "$root"/*) lib="$root/.agents/skills/commit-guards/scripts/lib" ;;
    *) lib="${HOME:+$HOME/.agents/skills/commit-guards/scripts/lib}" ;;
  esac
fi
[ -f "$lib/common.sh" ] && [ -f "$lib/settings.sh" ] || refuse settings no-loader
GG_CHECK=command-safety
# Keep nested support reads under errexit. A source on the left of || would
# continue past a failed nested import. EXIT owns the advisory outcome, and
# its saved stderr survives the source command's diagnostic redirection.
exec 3>&2
# Capture installed support's stderr in an owned file. Open separate write and
# read descriptions before unlinking it; EXIT can read from the beginning even
# while source's stderr redirection remains active. Process exit owns teardown.
support_capture=$(mktemp 2>&1) || refuse support unreadable "$support_capture"
exec 4>"$support_capture" 5<"$support_capture"
capture_err=$(rm -- "$support_capture" 2>&1) || refuse support unreadable "$capture_err"
loading="$lib/common.sh"
# shellcheck source=../skills/commit-guards/scripts/lib/common.sh
source "$lib/common.sh" 2>&4
loading="$lib/settings.sh"
# shellcheck source=../skills/commit-guards/scripts/lib/settings.sh
source "$lib/settings.sh" 2>&4
loading=""
exec 3>&- 4>&- 5<&-
# cd runs twice on purpose: a substitution cannot move this shell, so the
# probe is what carries the cause into the refusal and the second one is the
# move. The second failure is unreachable in practice — the probe just
# succeeded — and refuses without a cause rather than not at all.
if ! ROOT_ERR=$( (cd -- "$root") 2>&1 ); then
  refuse cwd "$root" "$ROOT_ERR"
fi
cd -- "$root" || refuse cwd "$root"
# The loader's diagnostic is captured, not left to precede the refusal: on
# failure the substitution holds the loader's keyed line — for a value in
# another shape, the file, the line and the key — and a successful read is
# silent, so the pattern is not mixed with a diagnostic.
# A failed whole-table settings read warns; the shell call remains available
# so the operator can repair that file.
# The default is the host-safety rule every install gets: a systemd-run memory
# cap in K or M starved a build's cgroup into a kernel allocation failure that
# left a host's root volume read-only. skills/commit-guards'
# kendex.settings.toml.example declares the same value.
default_pattern='(^|[^[:alnum:]_-])systemd-run[[:space:]][^&;|]*Memory(Max|High)=[[:punct:]]?[0-9]+[KkMm]([^[:alnum:]]|$)'
pattern="$(gg_setting COMMAND_SAFETY_DENY_PATTERN "$default_pattern" 2>&1)" || refuse settings unreadable "$pattern"
[ -n "$pattern" ] || refuse settings empty
[ "$pattern" != '^$' ] || exit 0
status=0
# Shell line continuations can split a denied command or token. Keep the raw
# text too: single quotes preserve backslash-newline pairs as literal text.
# Bash 3.2 needs ANSI-C quoting expanded before the replacement pattern.
continuation=$'\\\n'
joined_command_text="${command_text//"$continuation"/}"
# grep's words on a pattern it cannot read are captured: stderr becomes the
# substitution's stdout and grep's own stdout is discarded, so the status still
# decides and the cause reaches the refusal below its keyed line.
GREP_ERR=$(printf '%s\n' "$command_text" "$joined_command_text" | LC_ALL=C grep -E -- "$pattern" 2>&1 >/dev/null) || status=$?
case "$status" in
  0)
    # The default's reason and remedy are known here; a project pattern's are
    # its own. A project that sets the default's own value refuses for the
    # default's reason, so it gets the default's text.
    if [ "$pattern" = "$default_pattern" ]; then
      refuse refused default-policy
    fi
    refuse refused policy
    ;;
  1) exit 0 ;;
  *) refuse settings invalid-pattern "$GREP_ERR" ;;
esac
