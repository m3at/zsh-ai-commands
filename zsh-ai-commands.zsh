#!/usr/bin/zsh

# ══════════════════════════════════════════════════════════════════
# zsh-ai-commands — Gemini-powered command generation via fzf
# ══════════════════════════════════════════════════════════════════
#
# Example inputs and expected outputs for reference:
#
#   "list files, sort by descending size"
#   → ls -lhSr
#
#   "git diff without lock files"
#   → git diff -- . ':!*.lock'
#
#   "count the number of {"success": true} in file.jsonl"
#   → jq '[.success | select(. == true)] | length' < file.jsonl | awk '{s+=$1} END {print s}'
#
#   "find all TODO comments in src/ excluding node_modules"
#   → rg 'TODO' src/ --glob '!node_modules'
#
#   "show disk usage of top-level dirs, sorted"
#   → du -sh */ | sort -rh
#
#   "kill whatever is listening on port 3000"
#   → lsof -ti tcp:3000 | xargs kill -9
#
# ══════════════════════════════════════════════════════════════════

(( ! $+commands[fzf] )) && return
(( ! $+commands[curl] )) && return
(( ! $+commands[jq] )) && return

(( ! ${+ZSH_AI_COMMANDS_GEMINI_API_KEY} )) && {
  echo "zsh-ai-commands::Error::No API key set in ZSH_AI_COMMANDS_GEMINI_API_KEY"
  return
}

(( ! ${+ZSH_AI_COMMANDS_HOTKEY} )) && typeset -g ZSH_AI_COMMANDS_HOTKEY='^o'
(( ! ${+ZSH_AI_COMMANDS_LLM_NAME} )) && typeset -g ZSH_AI_COMMANDS_LLM_NAME='gemini-3-flash-preview'
(( ! ${+ZSH_AI_COMMANDS_HISTORY} )) && typeset -g ZSH_AI_COMMANDS_HISTORY=false
(( ! ${+ZSH_AI_COMMANDS_DEBUG} )) && typeset -g ZSH_AI_COMMANDS_DEBUG=false

fzf_ai_commands() {
  setopt localoptions extendedglob pipefail

  [[ -n "$BUFFER" ]] || { echo "Empty prompt"; return }

  local original_buffer="$BUFFER"
  local user_query="${original_buffer/#AI_ASK: /}"

  if [[ "$ZSH_AI_COMMANDS_HISTORY" == true ]]; then
    print -r -- "AI_ASK: $user_query" >> "$HISTFILE"
    if (( $+commands[atuin] )); then
      local atuin_id
      atuin_id=$(atuin history start "AI_ASK: $user_query")
      atuin history end --exit 0 "$atuin_id"
    fi
  fi

  # ── Loading indicator ──────────────────────────────────────────
  BUFFER="# ⏳ …"
  CURSOR=$#BUFFER
  zle -R

  # ── Build request ──────────────────────────────────────────────
  local sys
  read -r -d '' sys <<'PROMPT'
You are an expert sysadmin and shell scripter. Given a task description, output a single shell one-liner.

Environment:
- Shell: zsh on macOS (Darwin). GNU coreutils are installed.
- Available beyond the defaults: rg (ripgrep), jq, fzf, fd, sed, awk, perl, curl, git.

Output rules:
- Print ONLY the bare command. Nothing else.
- No markdown, no code fences, no backticks, no commentary, no leading/trailing whitespace.
- The command must be a single logical line. Use pipes, &&, ||, ;, or subshells to chain steps. Never use literal newlines.
- Quoting: prefer single quotes for fixed strings, double quotes when variable expansion or escapes are needed. Escape carefully inside nested quotes.
- Prefer sensible defaults, but when you can't, use <placeholder> for values that must be filled in, e.g. <file>, <pattern>, <port>.

Command quality:
- Prefer simple, robust solutions. Avoid unnecessary subshells or processes.
- When the task is ambiguous, pick the most common interpretation rather than asking for clarification.
PROMPT

  local request_body
  request_body=$(
    jq -n \
      --arg sys  "$sys" \
      --arg user "$user_query" \
      '{
        system_instruction: { parts: { text: $sys } },
        contents: [{ role: "user", parts: { text: $user } }],
        generationConfig: { maxOutputTokens: 512, temperature: 0.2 }
      }'
  ) || { BUFFER="$original_buffer"; zle reset-prompt; return 1; }

  # ── API call with interruption handling ─────────────────────────
  local resp_file
  resp_file="$(mktemp /tmp/zshllmresp.XXXXXX.json)" || {
    BUFFER="$original_buffer"; zle reset-prompt; return 1
  }

  trap 'BUFFER="$original_buffer"; zle reset-prompt; rm -f "$resp_file" 2>/dev/null; trap - INT; return 130' INT

  local url="https://generativelanguage.googleapis.com/v1beta/models/${ZSH_AI_COMMANDS_LLM_NAME}:generateContent?key=$ZSH_AI_COMMANDS_GEMINI_API_KEY"
  curl --silent --max-time 30 "$url" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "$request_body" > "$resp_file"
  local ret=$?
  trap - INT

  if (( ret != 0 )); then
    echo "curl failed (exit $ret)"
    BUFFER="$original_buffer"; zle end-of-line; zle reset-prompt
    [[ "$ZSH_AI_COMMANDS_DEBUG" == true ]] && echo "$resp_file" || rm -f "$resp_file"
    return $ret
  fi

  # ── Parse response ──────────────────────────────────────────────
  local raw
  raw="$(jq -r '
    .candidates[0].content.parts
    | map(.text // "")
    | join("\n")
  ' "$resp_file" 2>/dev/null)"

  if [[ -z "$raw" || "$raw" == "null" ]]; then
    local err
    err="$(jq -r '
      .error.message
      // .promptFeedback.blockReasonMessage
      // .promptFeedback.blockReason
      // "unknown error (set ZSH_AI_COMMANDS_DEBUG=true)"
    ' "$resp_file" 2>/dev/null)"
    echo "Gemini API error: $err"
    BUFFER="$original_buffer"; zle end-of-line; zle reset-prompt
    [[ "$ZSH_AI_COMMANDS_DEBUG" == true ]] && echo "$resp_file" || rm -f "$resp_file"
    return 1
  fi

  # Strip markdown fences while lines are still lines, then flatten.
  local cmd
  cmd="$(print -r -- "$raw" \
    | sed '/^[[:space:]]*```/d' \
    | tr '\n' ' ' \
    | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"

  if [[ -z "$cmd" ]]; then
    echo "Empty command after parsing"
    BUFFER="$original_buffer"; zle end-of-line; zle reset-prompt
    [[ "$ZSH_AI_COMMANDS_DEBUG" == true ]] && echo "$resp_file" || rm -f "$resp_file"
    return 1
  fi

  # ── fzf selection ───────────────────────────────────────────────
  local choice
  choice="$(printf 'Use command\nAbort and restore: %s\n' "$original_buffer" \
    | fzf --reverse --height=6 --prompt='ai> ' \
           --header="$(print -r -- "$cmd")")"

  if [[ "$choice" == "Use command" ]]; then
    BUFFER="$cmd"
  else
    BUFFER="$original_buffer"
  fi

  zle end-of-line
  zle reset-prompt

  [[ "$ZSH_AI_COMMANDS_DEBUG" == true ]] && echo "$resp_file" || rm -f "$resp_file"
}

autoload fzf_ai_commands
zle -N fzf_ai_commands
bindkey "$ZSH_AI_COMMANDS_HOTKEY" fzf_ai_commands
