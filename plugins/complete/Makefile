OUT ?= .

all: $(OUT)/complete.zsh

$(OUT)/complete.zsh: complete.zsh
	mkdir -p $(OUT)
	cp complete.zsh $@

clean:
	rm -f $(OUT)/complete.zsh

.PHONY: all clean
