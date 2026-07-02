BINARY := bin/noti-toast
SRC    := bin/noti-toast.swift

.PHONY: build install uninstall doctor clean test hooks

# Delegate to `./noti build` so make inherits the universal, floor-pinned,
# atomic build (a bare `swiftc` here would stamp the host's min-OS and ship a
# single-arch binary that won't launch on other Macs).
build:
	./noti build

install: build
	./noti install

uninstall:
	./noti uninstall

doctor:
	./noti doctor

test: build
	./test.sh

hooks:
	git config core.hooksPath .githooks

clean:
	rm -f $(BINARY)
