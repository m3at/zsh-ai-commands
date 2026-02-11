#!/usr/bin/zsh

(( ! $+commands[fzf] )) && return
(( ! $+commands[curl] )) && return
(( ! $+commands[jq] )) && return

(( ! ${+ZSH_AI_COMMANDS_GEMINI_API_KEY} )) && {
  echo "zsh-ai-commands::Error::No API key set in the env var ZSH_AI_COMMANDS_GEMINI_API_KEY. Plugin will not be loaded"
  return
}

(( ! ${+ZSH_AI_COMMANDS_HOTKEY} )) && typeset -g ZSH_AI_COMMANDS_HOTKEY='^o'
(( ! ${+ZSH_AI_COMMANDS_LLM_NAME} )) && typeset -g ZSH_AI_COMMANDS_LLM_NAME='gemini-3-flash-preview'
(( ! ${+ZSH_AI_COMMANDS_EXPLAINER} )) && typeset -g ZSH_AI_COMMANDS_EXPLAINER=true
(( ! ${+ZSH_AI_COMMANDS_HISTORY} )) && typeset -g ZSH_AI_COMMANDS_HISTORY=false
(( ! ${+ZSH_AI_COMMANDS_DEBUG} )) && typeset -g ZSH_AI_COMMANDS_DEBUG=false

# Remove terminal/ZLE-hostile control chars robustly:
# 1) map CR/LF/TAB to spaces
# 2) delete remaining ASCII control (0x00-0x1F + 0x7F)
_zsh_ai_sanitize() {
  LC_ALL=C tr $'\r\n\t' '   ' | LC_ALL=C tr -d $'\000-\010\013\014\016-\037\177' | sed -E 's/[[:space:]]+/ /g; s/^ +//; s/ +$//'
}

fzf_ai_commands() {
  setopt localoptions extendedglob pipefail

  [[ -n "$BUFFER" ]] || { echo "Empty prompt" ; return }

  local original_buffer="$BUFFER"
  local user_query="$original_buffer"
  user_query="${user_query/#AI_ASK: /}"
  ZSH_AI_COMMANDS_USER_QUERY="$user_query"

  if [[ "$ZSH_AI_COMMANDS_HISTORY" == true ]]; then
    print -r -- "AI_ASK: $ZSH_AI_COMMANDS_USER_QUERY" >> "$HISTFILE"
    if command -v atuin >/dev/null 2>&1; then
      local atuin_id
      atuin_id=$(atuin history start "AI_ASK: $ZSH_AI_COMMANDS_USER_QUERY")
      atuin history end --exit 0 "$atuin_id"
    fi
  fi

  zle end-of-line
  zle reset-prompt

  local sys="You are an experienced sysadmin. You craft a short and elegant one liner, for the $(basename "$SHELL") shell on MacOS, to do what the user asks for. Assume all common GNU utils are available, as well as rg, jq and fzf. Do NOT wrap your answer in code blocks or other formatting. Use ex <file> or <port_number> when placeholders are required. When using rare arguments or flags, you can append a comment starting with ## to concisely explain the command. Your whole answer MUST always remain a oneliner."
  local ex1="list files, sort by descending size"
  local ex1r="ls -lhSr ## -l long listing ; -h unit suffixes ; -S sort by size ; -r reverse"
  local ex2='git diff without lock files'
  local ex2r="git diff -- . ':!*.lock'"
  local ex3='count the number of {"success": true} in file.jsonl'
  local ex3r="jq '[.success | select(. == true)] | length' < file.jsonl | awk '{s+=\$1} END {print s}' ## Through jq, extract 'success' fields that are true, wrap in an array to get 1 if true. Then use awk to sum it all"

  local request_body
  request_body=$(
    jq -n \
      --arg sys  "$sys" \
      --arg ex1  "$ex1"  --arg ex1r "$ex1r" \
      --arg ex2  "$ex2"  --arg ex2r "$ex2r" \
      --arg ex3  "$ex3"  --arg ex3r "$ex3r" \
      --arg user "$ZSH_AI_COMMANDS_USER_QUERY" \
      '{
        system_instruction: { parts: { text: $sys } },
        contents: [
          { role:"user",  parts:{ text:$ex1  } }, { role:"model", parts:{ text:$ex1r } },
          { role:"user",  parts:{ text:$ex2  } }, { role:"model", parts:{ text:$ex2r } },
          { role:"user",  parts:{ text:$ex3  } }, { role:"model", parts:{ text:$ex3r } },
          { role:"user",  parts:{ text:$user } }
        ],
        generationConfig: { maxOutputTokens:512, temperature:0.4 }
      }'
  ) || { echo "Couldn't build the request body"; BUFFER="$original_buffer"; zle reset-prompt; return 1; }

  local resp_file
  resp_file="$(mktemp /tmp/zshllmresp.XXXXXX.json)" || { echo "mktemp failed"; BUFFER="$original_buffer"; zle reset-prompt; return 1; }

  local model_name="$ZSH_AI_COMMANDS_LLM_NAME"
  curl --silent \
    "https://generativelanguage.googleapis.com/v1beta/models/${model_name}:generateContent?key=$ZSH_AI_COMMANDS_GEMINI_API_KEY" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "$request_body" > "$resp_file"
  local ret=$?

  if (( ret != 0 )); then
    echo "curl failed ($ret)"
    BUFFER="$original_buffer"
    zle end-of-line; zle reset-prompt
    [[ "$ZSH_AI_COMMANDS_DEBUG" == true ]] && echo "$resp_file" || rm -f "$resp_file" 2>/dev/null
    return $ret
  fi

  # join ALL text parts, then sanitize hard
  local raw
  raw="$(jq -r '.candidates[0].content.parts | map(.text // "") | join("")' "$resp_file" 2>/dev/null)"

  if [[ -z "$raw" ]]; then
    local err
    err="$(jq -r '.error.message? // .promptFeedback.blockReasonMessage? // .promptFeedback.blockReason? // empty' "$resp_file" 2>/dev/null)"
    [[ -z "$err" ]] && err="(unknown error; set ZSH_AI_COMMANDS_DEBUG=true and inspect the JSON)"
    echo "Gemini API error: $err"
    BUFFER="$original_buffer"
    zle end-of-line; zle reset-prompt
    [[ "$ZSH_AI_COMMANDS_DEBUG" == true ]] && echo "$resp_file" || rm -f "$resp_file" 2>/dev/null
    return 1
  fi

  raw="$(print -r -- "$raw" | _zsh_ai_sanitize)"
  # best-effort fence strip (after sanitize)
  raw="$(print -r -- "$raw" | sed -E 's/^```[a-zA-Z0-9_-]*[[:space:]]*//; s/[[:space:]]*```$//')"

  local cmd="$raw"
  local expl=""
  if [[ "$raw" == *"## "* ]]; then
    cmd="${raw%%"## "*}"
    expl="${raw#*"## "}"
    cmd="$(print -r -- "$cmd" | sed -E 's/[[:space:]]+$//')"
  fi
  [[ -n "$cmd" ]] || cmd="$raw"

  # Two choices, but display the actual texts inline (no preview).
  # Use a hidden first column as the action key.
  local menu selected action
  menu="$(printf 'USE\t%s\nABORT\t%s\n' "$cmd" "$original_buffer")"
  selected="$(print -r -- "$menu" | fzf --reverse --delimiter=$'\t' --with-nth=2 --prompt='ai> ' --header='enter=select • esc=abort')"

  action="${selected%%$'\t'*}"
  if [[ -z "$selected" || "$action" == "ABORT" ]]; then
    BUFFER="$original_buffer"
  else
    BUFFER="$cmd"
  fi

  zle end-of-line
  zle reset-prompt

  [[ "$ZSH_AI_COMMANDS_DEBUG" == true ]] && echo "$resp_file" || rm -f "$resp_file" 2>/dev/null
  return $ret
}

autoload fzf_ai_commands
zle -N fzf_ai_commands
bindkey $ZSH_AI_COMMANDS_HOTKEY fzf_ai_commands
