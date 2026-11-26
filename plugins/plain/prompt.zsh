typeset -g YUDAE_PLAIN_CHAR='❯'
typeset -g _yudae_plain_color=2

function _yudae_plain_git {
	emulate -L zsh
	local branch
	branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || return 0
	local color=2
	[[ -n $(git status --porcelain 2>/dev/null) ]] && color=1
	print -rn -- " %F{$color}${branch}%f"
}

function _yudae_plain_precmd {
	local last=$?
	typeset -g _yudae_plain_color=2
	(( last )) && typeset -g _yudae_plain_color=1
}

function _yudae_plain_right {
	print -rn -- "$(_yudae_plain_git)"
}

setopt prompt_subst
precmd_functions=(${precmd_functions:#_yudae_plain_precmd} _yudae_plain_precmd)
PROMPT='%F{244}%~%f$(_yudae_plain_right) %F{$_yudae_plain_color}$YUDAE_PLAIN_CHAR%f '
RPROMPT=''
