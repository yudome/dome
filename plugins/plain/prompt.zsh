typeset -g YUDAE_PLAIN_CHAR='❯'

function _yudae_plain_precmd {
	local last=$? row
	local -a rows
	rows=("${(@f)$(git status --porcelain=v2 --branch 2>/dev/null)}")
	local branch='' dirty=0
	for row in "${rows[@]}"; do
		if [[ $row == '# branch.head '* ]]; then branch=${row#\# branch.head }; continue; fi
		[[ $row == '#'* ]] || dirty=1
	done
	local git=''
	[[ -n $branch && $branch != '(detached)' ]] && git=" %F{$(( dirty ? 1 : 2 ))}${branch//\%/%%}%f"
	PROMPT="%F{244}%2~%f${git} %F{$(( last ? 1 : 2 ))}$YUDAE_PLAIN_CHAR%f "
	RPROMPT=''
}

precmd_functions=(${precmd_functions:#_yudae_plain_precmd} _yudae_plain_precmd)
