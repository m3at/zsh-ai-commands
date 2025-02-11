#!/usr/bin/zsh

# Check if required tools are installed
(( ! $+commands[fzf] )) && return
(( ! $+commands[curl] )) && return
(( ! $+commands[jq] )) && return

# Check if if Gemini API key ist set
(( ! ${+ZSH_AI_COMMANDS_GEMINI_API_KEY} )) && echo "zsh-ai-commands::Error::No API key set in the env var ZSH_AI_COMMANDS_GEMINI_API_KEY. Plugin will not be loaded" && return

(( ! ${+ZSH_AI_COMMANDS_HOTKEY} )) && typeset -g ZSH_AI_COMMANDS_HOTKEY='^o'

(( ! ${+ZSH_AI_COMMANDS_LLM_NAME} )) && typeset -g ZSH_AI_COMMANDS_LLM_NAME='gemini-2.0-flash-lite-preview-02-05'

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

  ZSH_AI_COMMANDS_GPT_SYSTEM="You only answer 1 appropriate shell one liner that does what the user asks for. The command has to work with the $(basename $SHELL) terminal. Don't wrap your answer in code blocks or anything, dont acknowledge those rules, don't format your answer. Just reply the plaintext command. If your answer uses arguments or flags, you MUST end your shell command with a shell comment starting with ## with a ; separated list of concise explanations about each agument. Don't explain obvious placeholders like <ip> or <serverport> etc. Remember that your whole answer MUST remain a oneliner."
  ZSH_AI_COMMANDS_GPT_EX="Description of what the command should do: 'list files, sort by descending size'. Give me the appropriate command."
  ZSH_AI_COMMANDS_GPT_EX_REPLY="ls -lSr ## -l long listing ; -S sort by file size ; -r reverse order"
  ZSH_AI_COMMANDS_GPT_USER="Description of what the command should do: '$ZSH_AI_COMMANDS_USER_QUERY'. Give me the appropriate command."
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
          "text": "'$ZSH_AI_COMMANDS_GPT_EX'"
        }
      },
      {
        "role": "model",
        "parts": {
          "text": "'$ZSH_AI_COMMANDS_GPT_EX_REPLY'"
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
      "temperature": 1
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
  if [ ! -z "$exit_code" ]
  then
    # ZSH_AI_COMMANDS_PARSED=$(jq -r '.candidates[].content.parts[0].text' /tmp/zshllmresp.json | uniq)
    ZSH_AI_COMMANDS_PARSED=$(jq -r '.candidates[].content.parts[0].text | gsub("[\\n\\t]"; "")' /tmp/zshllmresp.json | uniq)
  else
    # retrying with better parsing - not really needed for gemini, but keep for consistency, and might help in some edge cases
    # exit_code=$(echo "$ZSH_AI_COMMANDS_GPT_RESPONSE" |sed '/"text": "/ s/\\/\\\\/g' | jq -r '.candidates[0].content.parts[0].text' 2>&1) || exit_code=""

    if [ ! -z "$exit_code" ]
    then
        # parse output
        # ZSH_AI_COMMANDS_PARSED=$(echo "$ZSH_AI_COMMANDS_GPT_RESPONSE" |sed '/"text": "/ s/\\/\\\\/g' | jq -r '.candidates[].content.parts[0].text' | uniq)
        ZSH_AI_COMMANDS_PARSED=$(jq -r '.candidates[].content.parts[0].text | gsub("[\\n\\t]"; "")' /tmp/zshllmresp.json | uniq)
    else
        # give up parsing
        echo "Failed to parse gemini response: $exit_code"
        # echo $ZSH_AI_COMMANDS_GPT_RESPONSE | jq -r '.candidates[].content.parts[0].text'
    fi
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
