typeset -g YUDAE_PROMPT_CHAR='λ'
typeset -g YUDAE_PROMPT_INSERT='›'
typeset -g YUDAE_PROMPT_NORMAL='·'
typeset -g YUDAE_PROMPT_OK=2
typeset -g YUDAE_PROMPT_ERR=1
typeset -g YUDAE_PROMPT_DIM=244
typeset -g YUDAE_PROMPT_SEGMENTS=2
typeset -g YUDAE_PROMPT_LENGTH=8

typeset -g _yudae_last_status=0
typeset -g _yudae_status_color=$YUDAE_PROMPT_OK

function _yudae_status_line {
	emulate -L zsh
	local char=$YUDAE_PROMPT_CHAR style=''
	[[ $EUID -eq 0 ]] && char='#'
	[[ -n $(jobs -p) ]] && style='%B'
	print -rn -- "${style}%F{$_yudae_status_color}${char}%f%b"
}

function _yudae_prefix {
	emulate -L zsh
	local out=''
	[[ -n $SSH_CONNECTION ]] && out+="%F{$YUDAE_PROMPT_DIM}${HOST%%.*}%f "
	[[ -n $VIRTUAL_ENV ]] && out+="%F{$YUDAE_PROMPT_DIM}${VIRTUAL_ENV:t}%f "
	print -rn -- "$out"
}

function _yudae_keymap {
	emulate -L zsh
	if [[ $KEYMAP == vicmd ]]; then
		print -rn -- "%F{$YUDAE_PROMPT_DIM}$YUDAE_PROMPT_NORMAL%f"
	else
		print -rn -- "%F{$YUDAE_PROMPT_DIM}$YUDAE_PROMPT_INSERT%f"
	fi
}

function _yudae_cwd {
	emulate -L zsh
	local path="${PWD/#$HOME/~}"
	local -a parts
	parts=("${(@s:/:)path}")
	local count=${1:-$YUDAE_PROMPT_SEGMENTS}
	local width=${2:-$YUDAE_PROMPT_LENGTH}
	(( count > 0 )) || count=${#parts}
	(( count > ${#parts} )) && count=${#parts}
	parts=("${(@)parts[-$count,-1]}")
	local -a out
	local part
	for part in "${(@)parts}"; do
		if (( width >= 4 && ${#part} > width )); then
			local half=$(( width / 2 - 1 ))
			part="${part[1,half]}..${part[-$half,-1]}"
		fi
		out+=("$part")
	done
	print -rn -- "${(j:/:)out}"
}

function _yudae_git {
	emulate -L zsh
	local branch
	branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || return 0
	local color=$YUDAE_PROMPT_OK
	[[ -n $(git status --porcelain 2>/dev/null) ]] && color=$YUDAE_PROMPT_ERR
	print -rn -- "%F{$color}${branch}%f"
}

function _yudae_right {
	emulate -L zsh
	local out="%F{$YUDAE_PROMPT_DIM}$(_yudae_cwd)%f"
	local git=$(_yudae_git)
	[[ -n $git ]] && out+=" $git"
	print -rn -- "$out"
}

function _yudae_info {
	emulate -L zsh
	local dim=$'\e[38;5;244m' err=$'\e[31m' reset=$'\e[0m'
	(( _yudae_last_status )) && print -r -- "${err}status $_yudae_last_status${reset}"
	local -a running
	running=(${(f)"$(jobs -p)"})
	(( ${#running} )) && print -r -- "${dim}jobs ${#running}${reset}"
	print -r -- "${dim}${USER}@${HOST%%.*}:$(_yudae_cwd 0 0)${reset}"
	local -a visible hidden
	visible=(*(N))
	hidden=(.*(N))
	local files="${#visible}"
	(( ${#hidden} )) && files+=" (${#hidden})"
	print -r -- "${dim}files ${files}${reset}"
}

function _yudae_magic {
	emulate -L zsh
	local out=''
	(( ${#dirstack} )) && out+="$(dirs -v)"$'\n'
	out+="$(ls -CF --color=always --group-directories-first 2>/dev/null)"$'\n'
	git rev-parse --is-inside-work-tree >/dev/null 2>&1 && out+="$(git -c color.status=always status -sb 2>/dev/null)"
	[[ -n $out ]] && print -r -- "$out" | less -XFR
}

function _yudae_precmd {
	local last=$?
	typeset -g _yudae_last_status=$last
	typeset -g _yudae_status_color=$YUDAE_PROMPT_OK
	(( last )) && typeset -g _yudae_status_color=$YUDAE_PROMPT_ERR
}

function _yudae_accept {
	if [[ -z $BUFFER ]]; then
		_yudae_info
		_yudae_magic
		zle redisplay
	else
		zle .accept-line
	fi
}

function _yudae_keymap_select {
	zle reset-prompt
}

setopt prompt_subst
precmd_functions=(${precmd_functions:#_yudae_precmd} _yudae_precmd)
PROMPT='$(_yudae_prefix)$(_yudae_status_line) $(_yudae_keymap) '
RPROMPT='$(_yudae_right)'

if [[ -o interactive ]]; then
	zle -N accept-line _yudae_accept
	zle -N zle-keymap-select _yudae_keymap_select
fi
