# rime-cloud -- build the optional C HTTP module.
#
#   make            build lua/cloud_input/cloud_http.so
#   make test       offline parser tests
#   make live-test  live Sogou/Baidu endpoint tests
#   make clean

CC       ?= cc
CFLAGS   ?= -O2 -g -Wall -Wextra
LUA_CFLAGS ?= $(shell pkg-config --cflags lua5.5 2>/dev/null)
LUA_LIBS   ?= $(shell pkg-config --libs lua5.5 2>/dev/null || echo -llua)
CURL_LIBS  ?= $(shell pkg-config --libs libcurl 2>/dev/null || echo -lcurl)
LDFLAGS  ?=
MODULE   := lua/cloud_input/cloud_http.so

.PHONY: all test live-test integration clean install uninstall

all: $(MODULE)

$(MODULE): src/cloud_http.c
	$(CC) $(CFLAGS) $(LUA_CFLAGS) -fPIC -shared $(LDFLAGS) -o $@ $< $(LUA_LIBS) $(CURL_LIBS) -lpthread

test: $(MODULE)
	lua tests/test_parsers.lua

live-test: $(MODULE)
	lua tests/test_providers.lua

integration: $(MODULE)
	./tests/integration.sh

clean:
	rm -f $(MODULE)

install: $(MODULE)
	./install.sh

uninstall:
	./uninstall.sh
