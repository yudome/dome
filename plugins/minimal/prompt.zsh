typeset -g YUDAE_PROMPT_CHAR='λ' YUDAE_PROMPT_INSERT='›' YUDAE_PROMPT_NORMAL='·'
typeset -g YUDAE_PROMPT_OK=2 YUDAE_PROMPT_ERR=1 YUDAE_PROMPT_DIM=244

typeset -g _yudae_color=$YUDAE_PROMPT_OK _yudae_keymap=$YUDAE_PROMPT_INSERT
typeset -g _yudae_git='' _yudae_jobs=0 _yudae_last=0

function _yudae_git_scan {
	local -a rows
	rows=("${(@f)$(git status --porcelain=v2 --branch 2>/dev/null)}")
	local row branch='' dirty=0
	for row in "${rows[@]}"; do
		if [[ $row == '# branch.head '* ]]; then branch=${row#\# branch.head }; continue; fi
		[[ $row == '#'* ]] || dirty=1
	done
	_yudae_git=''
	[[ -z $branch || $branch == '(detached)' ]] && return
	_yudae_git=" %F{$(( dirty ? YUDAE_PROMPT_ERR : YUDAE_PROMPT_OK ))}${branch//\%/%%}%f"
}

function _yudae_prompt_build {
	local prefix='' bold=''
	[[ -n $SSH_CONNECTION ]] && prefix+="%F{$YUDAE_PROMPT_DIM}${HOST%%.*}%f "
	[[ -n $VIRTUAL_ENV ]] && prefix+="%F{$YUDAE_PROMPT_DIM}${VIRTUAL_ENV:t}%f "
	(( _yudae_jobs )) && bold='%B'
	PROMPT="${prefix}${bold}%F{$_yudae_color}%(!.#.$YUDAE_PROMPT_CHAR)%f%b %F{$YUDAE_PROMPT_DIM}${_yudae_keymap}%f "
	RPROMPT="%F{$YUDAE_PROMPT_DIM}%2~%f${_yudae_git}"
}

function _yudae_keymap_scan {
	if [[ $KEYMAP == vicmd ]]; then
		_yudae_keymap=$YUDAE_PROMPT_NORMAL
	else
		_yudae_keymap=$YUDAE_PROMPT_INSERT
	fi
}

function _yudae_precmd {
	local last=$?
	_yudae_last=$last
	_yudae_color=$(( last ? YUDAE_PROMPT_ERR : YUDAE_PROMPT_OK ))
	_yudae_jobs=$#jobstates
	_yudae_keymap_scan
	_yudae_git_scan
	_yudae_prompt_build
}

function _yudae_info {
	local dim=$'\e[38;5;244m' err=$'\e[31m' reset=$'\e[0m'
	(( _yudae_last )) && print -r -- "${err}status $_yudae_last${reset}"
	(( _yudae_jobs )) && print -r -- "${dim}jobs $_yudae_jobs${reset}"
	local -a visible hidden
	visible=(*(N)) hidden=(.*(N))
	print -r -- "${dim}${USER}@${HOST%%.*}:${PWD/#$HOME/~} files ${#visible} (${#hidden})${reset}"
}

function _yudae_magic {
	local listing
	listing="$(dirs -v 2>/dev/null)"$'\n'"$(ls -CF --color=always --group-directories-first 2>/dev/null)"
	git rev-parse --is-inside-work-tree >/dev/null 2>&1 && listing+=$'\n'"$(git status -sb 2>/dev/null)"
	print -r -- "$listing" | less -XFR
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
	_yudae_keymap_scan
	_yudae_prompt_build
	zle reset-prompt
}

precmd_functions=(${precmd_functions:#_yudae_precmd} _yudae_precmd)

if [[ -o interactive ]]; then
	zle -N accept-line _yudae_accept
	zle -N zle-keymap-select _yudae_keymap_select
fi
