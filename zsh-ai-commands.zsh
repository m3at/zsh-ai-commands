#!/usr/bin/zsh

# Check if required tools are installed
(( ! $+commands[fzf] )) && return
(( ! $+commands[curl] )) && return
(( ! $+commands[jq] )) && return

# Check if if Gemini API key ist set
(( ! ${+ZSH_AI_COMMANDS_GEMINI_API_KEY} )) && echo "zsh-ai-commands::Error::No API key set in the env var ZSH_AI_COMMANDS_GEMINI_API_KEY. Plugin will not be loaded" && return

(( ! ${+ZSH_AI_COMMANDS_HOTKEY} )) && typeset -g ZSH_AI_COMMANDS_HOTKEY='^o'

(( ! ${+ZSH_AI_COMMANDS_LLM_NAME} )) && typeset -g ZSH_AI_COMMANDS_LLM_NAME='gemini-2.0-flash-lite'

(( ! ${+ZSH_AI_COMMANDS_N_GENERATIONS} )) && typeset -g ZSH_AI_COMMANDS_N_GENERATIONS=3

(( ! ${+ZSH_AI_COMMANDS_EXPLAINER} )) && typeset -g ZSH_AI_COMMANDS_EXPLAINER=true

(( ! ${+ZSH_AI_COMMANDS_HISTORY} )) && typeset -g ZSH_AI_COMMANDS_HISTORY=false

fzf_ai_commands() {
  setopt extendedglob

  [ -n "$BUFFER" ] || { echo "Empty prompt" ; return }

  BUFFER="$(echo "$BUFFER" | sed 's/^AI_ASK: //g')"

  ZSH_AI_COMMANDS_USER_QUERY=$BUFFER

  if [ $ZSH_AI_COMMANDS_HISTORY = true ]
  then
    # save to history
    echo "AI_ASK: $ZSH_AI_COMMANDS_USER_QUERY" >> $HISTFILE
    # also to atuin's history if installed
    if command -v atuin &> /dev/null;
    then
        atuin_id=$(atuin history start "AI_ASK: $ZSH_AI_COMMANDS_USER_QUERY")
        atuin history end --exit 0 "$atuin_id"
    fi
  fi

  # FIXME: For some reason the buffer is only updated if zsh-autosuggestions is enabled
  # BUFFER="Asking $ZSH_AI_COMMANDS_LLM_NAME for a command to do: $ZSH_AI_COMMANDS_USER_QUERY. Please wait..."
  ZSH_AI_COMMANDS_USER_QUERY=$(echo "$ZSH_AI_COMMANDS_USER_QUERY" | sed 's/"/\\"/g')
  zle end-of-line
  zle reset-prompt
  
  ZSH_AI_COMMANDS_GPT_SYSTEM="You are an experienced sysadmin. You craft a short and elegant one liner, for the $(basename $SHELL) shell on MacOS, to do what the user asks for. Assume all common GNU utils are available, as well as rg, jq and fzf. Do NOT wrap your answer in code blocks or other formatting. Use ex <file> or <port_number> when placeholders are required. When using rare arguments or flags, you can append a comment starting with ## to concisely explain the command. Your whole answer MUST always remain a oneliner."
  ZSH_AI_COMMANDS_GPT_EX_1="list files, sort by descending size"
  ZSH_AI_COMMANDS_GPT_EX_REPLY_1="ls -lhSr ## -l long listing ; -h unit suffixes ; -S sort by size ; -r reverse"
  ZSH_AI_COMMANDS_GPT_EX_2='git diff without lock files'
  ZSH_AI_COMMANDS_GPT_EX_REPLY_2="git diff -- . ':!*.lock'"
  ZSH_AI_COMMANDS_GPT_EX_3='count the number of {\"success\": true} in file.jsonl'
  ZSH_AI_COMMANDS_GPT_EX_REPLY_3="jq '[.success | select(. == true)] | length' < file.jsonl | awk '{s+=\$1} END {print s}' ## Through jq, extract 'success' fields that are true, wrap in an array to get 1 if true. Then use awk to sum it all"
  # get 4 random words
  # shuf -n4 /usr/share/dict/words | tr '\n' '-' | head -c -1
  ZSH_AI_COMMANDS_GPT_USER="$ZSH_AI_COMMANDS_USER_QUERY"
  ZSH_AI_COMMANDS_GPT_REQUEST_BODY='{
    "system_instruction": {
      "parts": {
        "text": "'$ZSH_AI_COMMANDS_GPT_SYSTEM'"
      }
    },
    "contents": [
      {
        "role": "user",
        "parts": {
          "text": "'$ZSH_AI_COMMANDS_GPT_EX_1'"
        }
      },
      {
        "role": "model",
        "parts": {
          "text": "'$ZSH_AI_COMMANDS_GPT_EX_REPLY_1'"
        }
      },
      {
        "role": "user",
        "parts": {
          "text": "'$ZSH_AI_COMMANDS_GPT_EX_2'"
        }
      },
      {
        "role": "model",
        "parts": {
          "text": "'$ZSH_AI_COMMANDS_GPT_EX_REPLY_2'"
        }
      },
      {
        "role": "user",
        "parts": {
          "text": "'$ZSH_AI_COMMANDS_GPT_EX_3'"
        }
      },
      {
        "role": "model",
        "parts": {
          "text": "'$ZSH_AI_COMMANDS_GPT_EX_REPLY_3'"
        }
      },
      {
        "role": "user",
        "parts": {
          "text": "'$ZSH_AI_COMMANDS_GPT_USER'"
        }
      }
    ],
    "generationConfig": {
      "candidateCount": '$ZSH_AI_COMMANDS_N_GENERATIONS',
      "maxOutputTokens": 128,
      "temperature": 0.4
    }
  }'

  # check request is valid json
  {echo "$ZSH_AI_COMMANDS_GPT_REQUEST_BODY" | jq > /dev/null} || {echo "Couldn't parse the body request" ; return}

  MODEL_NAME=$ZSH_AI_COMMANDS_LLM_NAME
  curl --silent "https://generativelanguage.googleapis.com/v1beta/models/"$MODEL_NAME":generateContent?key=$ZSH_AI_COMMANDS_GEMINI_API_KEY" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "$ZSH_AI_COMMANDS_GPT_REQUEST_BODY" > /tmp/zshllmresp.json
  local ret=$?

  # if the json parsing fails, retry after some formating
  exit_code=$(jq -r '.candidates[0].content.parts[0].text' /tmp/zshllmresp.json 2>&1) || exit_code=""

  # DEBUG
  # example:
  # find the 5 biggest local files under current root, shown their human redable size along with their path (split your command into multiple line)
  # echo /tmp/zshllmresp.json

  if [ ! -z "$exit_code" ]
  then
    ZSH_AI_COMMANDS_PARSED=$(jq -r '.candidates[].content.parts[0].text | gsub("[\\n\\t]"; "")' /tmp/zshllmresp.json | uniq)
  else
    echo "Failed to parse gemini response: $exit_code"
    return 1
  fi

  export ZSH_AI_COMMANDS_PARSED

  selected=$(echo "$ZSH_AI_COMMANDS_PARSED" | sed 's/## /\t/g' | fzf --reverse --preview-window down:wrap --delimiter='\t' --with-nth=1 --preview 'echo {} | awk -F "\t" '\''{print $2}'\''')
  ZSH_AI_COMMANDS_SELECTED=$(echo "$selected" | awk -F " \t" '{print $1}')

  # get the answers
  BUFFER=$ZSH_AI_COMMANDS_SELECTED

  zle end-of-line
  zle reset-prompt
  return $ret
}

autoload fzf_ai_commands
zle -N fzf_ai_commands

bindkey $ZSH_AI_COMMANDS_HOTKEY fzf_ai_commands
