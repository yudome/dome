function _yudae_complete_tab {
	if (( $#POSTDISPLAY )); then
		zle autosuggest-accept
	elif (( ${+widgets[fzf-completion]} )); then
		zle fzf-completion
	else
		zle expand-or-complete
	fi
}

if [[ -o interactive ]]; then
	zle -N _yudae_complete_tab
	bindkey '^I' _yudae_complete_tab
fi
