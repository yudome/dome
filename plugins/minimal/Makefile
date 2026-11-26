OUT ?= .

all: $(OUT)/prompt.zsh

$(OUT)/prompt.zsh: prompt.zsh
	mkdir -p $(OUT)
	cp prompt.zsh $@

clean:
	rm -f $(OUT)/prompt.zsh

.PHONY: all clean
