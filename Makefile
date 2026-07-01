BINARY := bin/noti-toast
SRC    := bin/noti-toast.swift

.PHONY: build install uninstall doctor clean test hooks

build: $(BINARY)

$(BINARY): $(SRC)
	swiftc -O $(SRC) -o $(BINARY)

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
