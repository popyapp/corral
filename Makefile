.PHONY: build test app dmg run list disk bench icon clean

build:
	swift build

test:
	swift test

app:
	./scripts/make_app.sh

dmg: app
	./scripts/make_dmg.sh

icon:
	./scripts/make_icon.sh

run:
	swift run Corral

list:
	swift run Corral --list

disk:
	swift run Corral --disk

bench:
	swift run -c release Corral --bench

clean:
	rm -rf .build build
