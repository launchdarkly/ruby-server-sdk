TEMP_TEST_OUTPUT=/tmp/contract-test-service.log

# TEST_HARNESS_PARAMS can be set to add -skip parameters for any contract tests that cannot yet pass
# Explanation of current skips:
TEST_HARNESS_PARAMS=

build-contract-tests:
	@cd contract-tests && bundle _2.2.33_ install

start-contract-test-service:
	@cd contract-tests && bundle _2.2.33_ exec ruby service.rb

start-contract-test-service-bg:
	@echo "Test service output will be captured in $(TEMP_TEST_OUTPUT)"
	@make start-contract-test-service >$(TEMP_TEST_OUTPUT) 2>&1 &

run-contract-tests:
	@curl -s https://raw.githubusercontent.com/launchdarkly/sdk-test-harness/main/downloader/run.sh \
      | VERSION=v2 PARAMS="-url http://localhost:9000 -debug -stop-service-at-end $(TEST_HARNESS_PARAMS)" sh

contract-tests: build-contract-tests start-contract-test-service-bg run-contract-tests

.PHONY: build-contract-tests start-contract-test-service run-contract-tests contract-tests
