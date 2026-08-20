.PHONY: build app run list icon clean

build:
	swift build

app:
	./scripts/make_app.sh

icon:
	./scripts/make_icon.sh

run:
	swift run Corral

list:
	swift run Corral --list

clean:
	rm -rf .build build
