Forked from [muePatrick](https://github.com/muePatrick/zsh-ai-commands) to use Gemini instead of OpenAI.

---

# ZSH AI Commands
![zsh-ai-commands-demo](./zsh-ai-commands-demo.gif)

This plugin works by asking Gemini for terminal commands that achieve the described target action.

To use it just type what you want to do (e.g. `list all files in this directory`) and hit the configured hotkey (default: `Ctrl+o`).
When the model responds with its suggestions just select the one from the list you want to use.

## Requirements
* [curl](https://curl.se/)
* [fzf](https://github.com/junegunn/fzf)
  * note: you need a recent version of fzf (the apt version for example is fairly old and will not work)
* [jq](https://github.com/jqlang/jq)
* awk

## Installation

Using [zplug](https://github.com/zplug/zplug), add this line in your zshrc:
```sh
zplug "m3at/zsh-ai-commands"
```

Export the API key in your by setting:

```
ZSH_AI_COMMANDS_GEMINI_API_KEY="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

Replace the placeholder with your own key.
The config can be set e.g in your `.zshrc` in this case be careful to not leak the key should you be sharing your config files.

## Configuration Variables

| Variable                                  | Default                                 | Description                                                                                                |
| ----------------------------------------- | --------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `ZSH_AI_COMMANDS_GEMINI_API_KEY` | `-/-` (not set) | Google Gemini API key |
| `ZSH_AI_COMMANDS_HOTKEY` | `'^o'` (Ctrl+o) | Hotkey to trigger the request |
| `ZSH_AI_COMMANDS_LLM_NAME` | `gemini-2.0-flash-lite-preview-02-05` | LLM name |
| `ZSH_AI_COMMANDS_N_GENERATIONS` | `3` | Number of completions to ask for |
| `ZSH_AI_COMMANDS_HISTORY` | `false` | If true, save the natural language prompt to the shell history (and atuin if installed) |


## Known Bugs
- [x] Sometimes the commands in the response have to much / unexpected special characters and the string is not preprocessed enough. In this case the fzf list stays empty.
- [ ] The placeholder message, that should be shown while the model request is running, is not always shown. For me it only works if `zsh-autosuggestions` is enabled.
