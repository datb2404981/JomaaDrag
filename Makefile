.PHONY: all build install clean

all: build

build:
	@./scripts/build.sh

install:
	@./scripts/install.sh

clean:
	@rm -rf build
