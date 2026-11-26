OUT ?= $(or $(XDG_STATE_HOME),$(HOME)/.local/state)/yudae/build/shadow

ifeq ($(CXX),g++)
    EXTRA_FLAGS = --no-gnu-unique
else
    EXTRA_FLAGS =
endif

CXXFLAGS ?= -O2
CXXFLAGS += -shared -fPIC -std=c++2b -Wall -Wno-unused-variable
CXXFLAGS += $(shell pkg-config --cflags hyprland)
TARGET   = $(OUT)/shadow.so

all: $(TARGET)

$(TARGET): src/main.cpp src/shadow_texture.h
	mkdir -p $(OUT)
	$(CXX) $(CXXFLAGS) $(LDFLAGS) $(EXTRA_FLAGS) src/main.cpp -o $(TARGET)

clean:
	rm -f $(TARGET)

.PHONY: all clean
