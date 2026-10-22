.PHONY: all build install clean test

all: build

build:
	@./scripts/build.sh

install:
	@./scripts/install.sh

test:
	@bash scripts/test.sh

clean:
	@rm -rf build
