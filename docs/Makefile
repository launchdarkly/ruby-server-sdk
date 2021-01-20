
ifeq ($(LD_RELEASE_VERSION),)
TITLE=LaunchDarkly Ruby SDK
else
TITLE=LaunchDarkly Ruby SDK ($(LD_RELEASE_VERSION))
endif

.PHONY: dependencies html

html: dependencies
	rm -rf ./build
	cd .. && yard doc \
		-o docs/build/html \
		--title "$(TITLE)" \
		--no-private \
		--markup markdown \
		--embed-mixins \
		-r docs/index.md \
		lib/*.rb \
		lib/**/*.rb \
		lib/**/**/*.rb \
		lib/**/**/**/*.rb

dependencies:
	gem install --conservative yard
	gem install --conservative redcarpet  # provides Markdown formatting
