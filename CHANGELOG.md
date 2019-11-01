# Change log

All notable changes to the LaunchDarkly Ruby SDK will be documented in this file. This project adheres to [Semantic Versioning](http://semver.org).

## [5.6.0] - 2019-08-28
### Added:
- Added support for upcoming LaunchDarkly experimentation features. See `LDClient.track()`.

## [5.5.12] - 2019-08-05
### Fixed:
- Under conditions where analytics events are being generated at an extremely high rate (for instance, if an application is evaluating a flag repeatedly in a tight loop on many threads), it was possible for the internal event processing logic to fall behind on processing the events, causing them to use more and more memory. The logic has been changed to drop events if necessary so that besides the existing limit on the number of events waiting to be sent to LaunchDarkly (`config.capacity`), the same limit also applies on the number of events that are waiting to be processed by the worker thread that decides whether or not to send them to LaunchDarkly. If that limit is exceeded, this warning message will be logged once: "Events are being produced faster than they can be processed; some events will be dropped". Under normal conditions this should never happen; this change is meant to avoid a concurrency bottleneck in applications that are already so busy that thread starvation is likely.

## [5.5.11] - 2019-07-24
### Fixed:
- `FileDataSource` was using `YAML.load`, which has a known [security vulnerability](https://trailofbits.github.io/rubysec/yaml/index.html). This has been changed to use `YAML.safe_load`, which will refuse to parse any files that contain the `!` directives used in this type of attack. This issue does not affect any applications that do not use `FileDataSource` (which is meant for testing purposes, not production use). ([#139](https://github.com/launchdarkly/ruby-server-sdk/issues/139))


## [5.5.10] - 2019-07-24
This release was an error; it is identical to 5.5.9.

## [5.5.9] - 2019-07-23
### Fixed:
- Due to the gem name no longer being the same as the `require` name, Bundler autoloading was no longer working in versions 5.5.7 and 5.5.8 of the SDK. This has been fixed. (Thanks, [tonyta](https://github.com/launchdarkly/ruby-server-sdk/pull/137)!)

## [5.5.8] - 2019-07-11
### Fixed:
- In streaming mode, depending on the Ruby version, calling `close` on the client could cause a misleading warning message in the log, such as `Unexpected error from event source: #<IOError: stream closed in another thread>`. ([#135](https://github.com/launchdarkly/ruby-server-sdk/issues/135))

## [5.5.7] - 2019-05-13
### Changed:
- Changed the gem name from `ldclient-rb` to `launchdarkly-server-sdk`.

There are no other changes in this release. Substituting `ldclient-rb` version 5.5.6 with `launchdarkly-server-sdk` version 5.5.7 will not affect functionality.

## [5.5.6] - 2019-05-08
### Fixed:
- CI tests now include Ruby 2.6.x.
- Running the SDK unit tests is now simpler, as the database integrations can be skipped. See `CONTRIBUTING.md`.

# Note on future releases

The LaunchDarkly SDK repositories are being renamed for consistency. This repository is now `ruby-server-sdk` rather than `ruby-client`.

The gem name will also change. In the 5.5.6 release, it is still `ldclient-rb`; in all future releases, it will be `launchdarkly-server-sdk`. No further updates to the `ldclient-rb` gem will be published after this release.


## [5.5.5] - 2019-03-28
### Fixed:
- Setting user attributes to non-string values when a string was expected would cause analytics events not to be processed. Also, in the case of the `secondary` attribute, this could cause evaluations to fail for a flag with a percentage rollout. The SDK will now convert attribute values to strings as needed. ([#131](https://github.com/launchdarkly/ruby-server-sdk/issues/131))

## [5.5.4] - 2019-03-29
### Fixed:
- Fixed a missing `require` that could sometimes cause a `NameError` to be thrown when starting the client, depending on what other gems were installed. This bug was introduced in version 5.5.3. ([#129](https://github.com/launchdarkly/ruby-server-sdk/issues/129))
- When an analytics event was generated for a feature flag because it is a prerequisite for another flag that was evaluated, the user data was being omitted from the event. ([#128](https://github.com/launchdarkly/ruby-server-sdk/issues/128))
- If `track` or `identify` is called without a user, the SDK now logs a warning, and does not send an analytics event to LaunchDarkly (since it would not be processed without a user).
- Added a link from the SDK readme to the guide regarding the client initialization.

## [5.5.3] - 2019-02-13
### Changed:
- The SDK previously used the `faraday` and `net-http-persistent` gems for all HTTP requests other than streaming connections. Since `faraday` lacks a stable version and has a known issue with character encoding, and `net-http-persistent` is no longer maintained, these have both been removed. This should not affect any SDK functionality.

### Fixed:
- The SDK was not usable in Windows because of `net-http-persistent`. That gem has been removed.
- When running in Windows, the event-processing thread threw a `RangeError` due to a difference in the Windows implementation of `concurrent-ruby`. This has been fixed.
- Windows incompatibilities were undetected before because we were not running a Windows CI job. We are now testing on Windows with Ruby 2.5.

## [5.5.2] - 2019-01-18
### Fixed:
- Like 5.5.1, this release contains only documentation fixes. Implementation classes that are not part of the supported API are now hidden from the [generated documentation](https://www.rubydoc.info/gems/ldclient-rb).


## [5.5.1] - 2019-01-17
### Fixed:
- Fixed several documentation comments that had the wrong parameter names. There are no other changes in this release; it's only to correct the documentation.

## [5.5.0] - 2019-01-17
### Added:
- It is now possible to use Consul or DynamoDB as a persistent feature store, similar to the existing Redis integration. See the `LaunchDarkly::Integrations::Consul` and `LaunchDarkly::Integrations::DynamoDB` modules, and the reference guide [Using a persistent feature store](https://docs.launchdarkly.com/v2.0/docs/using-a-persistent-feature-store).
- There is now a `LaunchDarkly::Integrations::Redis` module, which is the preferred method for creating a Redis feature store.
- All of the database feature stores now support local caching not only for individual feature flag queries, but also for `all_flags_state`.
- The `Config` property `data_source` is the new name for `update_processor` and `update_processor_factory`.

### Changed:
- The implementation of the SSE protocol for streaming has been moved into a separate gem, [`ld-eventsource`](https://github.com/launchdarkly/ruby-eventsource). This has no effect on streaming functionality.

### Fixed:
- Added or corrected a large number of documentation comments. All API classes and methods are now documented, and internal implementation details have been hidden from the documentation. You can view the latest documentation on [RubyDoc](https://www.rubydoc.info/gems/ldclient-rb).
- Fixed a problem in the Redis feature store that would only happen under unlikely circumstances: trying to evaluate a flag when the LaunchDarkly client had not yet been fully initialized and the store did not yet have data in it, and then trying again when the client was still not ready but the store _did_ have data (presumably put there by another process). Previously, the second attempt would fail.
- In polling mode, the SDK did not correctly handle non-ASCII Unicode characters in feature flag data. ([#90](https://github.com/launchdarkly/ruby-server-sdk/issues/90))

### Deprecated:
- `RedisFeatureStore.new`. This implementation class may be changed or moved in the future; use `LaunchDarkly::Integrations::Redis::new_feature_store`.
- `Config.update_processor` and `Config.update_processor_factory`; use `Config.data_source`.

## [5.4.3] - 2019-01-11
### Changed:
- The SDK is now compatible with `net-http-persistent` 3.x. (Thanks, [CodingAnarchy](https://github.com/launchdarkly/ruby-server-sdk/pull/113)!)

## [5.4.2] - 2019-01-04
### Fixed:
- Fixed overly specific dependency versions of `concurrent-ruby` and `semantic`. ([#115](https://github.com/launchdarkly/ruby-server-sdk/issues/115))
- Removed obsolete dependencies on `hashdiff` and `thread_safe`.

## [5.4.1] - 2018-11-05
### Fixed:
- Fixed a `LoadError` in `file_data_source.rb`, which was added in 5.4.0. (Thanks, [kbarrette](https://github.com/launchdarkly/ruby-server-sdk/pull/110)!)


## [5.4.0] - 2018-11-02
### Added:
- It is now possible to inject feature flags into the client from local JSON or YAML files, replacing the normal LaunchDarkly connection. This would typically be for testing purposes. See `file_data_source.rb`.

### Fixed:
- When shutting down an `LDClient`, if in polling mode, the client was using `Thread.raise` to make the polling thread stop sleeping. `Thread.raise` can cause unpredictable behavior in a worker thread, so it is no longer used.

## [5.3.0] - 2018-10-24
### Added:
- The `all_flags_state` method now accepts a new option, `details_only_for_tracked_flags`, which reduces the size of the JSON representation of the flag state by omitting some metadata. Specifically, it omits any data that is normally used for generating detailed evaluation events if a flag does not have event tracking or debugging turned on.

### Fixed:
- JSON data from `all_flags_state` is now slightly smaller even if you do not use the new option described above, because it omits the flag property for event tracking unless that property is true.

## [5.2.0] - 2018-08-29
### Added:
- The new `LDClient` method `variation_detail` allows you to evaluate a feature flag (using the same parameters as you would for `variation`) and receive more information about how the value was calculated. This information is returned in an `EvaluationDetail` object, which contains both the result value and a "reason" object which will tell you, for instance, if the user was individually targeted for the flag or was matched by one of the flag's rules, or if the flag returned the default value due to an error.

### Fixed:
- Evaluating a prerequisite feature flag did not produce an analytics event if the prerequisite flag was off.

 
## [5.1.0] - 2018-08-27
### Added:
- The new `LDClient` method `all_flags_state()` should be used instead of `all_flags()` if you are passing flag data to the front end for use with the JavaScript SDK. It preserves some flag metadata that the front end requires in order to send analytics events correctly. Versions 2.5.0 and above of the JavaScript SDK are able to use this metadata, but the output of `all_flags_state()` will still work with older versions.
- The `all_flags_state()` method also allows you to select only client-side-enabled flags to pass to the front end, by using the option `client_side_only: true`.

### Changed:
- Unexpected exceptions are now logged at `ERROR` level, and exception stacktraces at `DEBUG` level. Previously, both were being logged at `WARN` level.

### Deprecated:
- `LDClient.all_flags()`


## [5.0.1] - 2018-07-02
### Fixed:
Fixed a regression in version 5.0.0 that could prevent the client from reconnecting if the stream connection was dropped by the server.


## [5.0.0] - 2018-06-26
### Changed:
- The client no longer uses Celluloid for streaming I/O. Instead, it uses [socketry](https://github.com/socketry/socketry).
- The client now treats most HTTP 4xx errors as unrecoverable: that is, after receiving such an error, it will not make any more HTTP requests for the lifetime of the client instance, in effect taking the client offline. This is because such errors indicate either a configuration problem (invalid SDK key) or a bug, which is not likely to resolve without a restart or an upgrade. This does not apply if the error is 400, 408, 429, or any 5xx error.
- During initialization, if the client receives any of the unrecoverable errors described above, the client constructor will return immediately; previously it would continue waiting until a timeout. The `initialized?` method will return false in this case.

### Removed:
- The SDK no longer supports Ruby versions below 2.2.6, or JRuby below 9.1.16.

## [4.0.0] - 2018-05-10

### Changed:
- To reduce the network bandwidth used for analytics events, feature request events are now sent as counters rather than individual events, and user details are now sent only at intervals rather than in each event. These behaviors can be modified through the LaunchDarkly UI and with the new configuration option `inline_users_in_events`. For more details, see [Analytics Data Stream Reference](https://docs.launchdarkly.com/v2.0/docs/analytics-data-stream-reference).

### Removed:
- JRuby 1.7 is no longer supported.
- Greatly reduced the number of indirect gem dependencies by removing `moneta`, which was previously a requirement for the Redis feature store.


## [3.0.3] - 2018-03-23
## Fixed
- In the Redis feature store, fixed a synchronization problem that could cause a feature flag update to be missed if several of them happened in rapid succession.

## [3.0.2] - 2018-03-06
## Fixed
- Improved efficiency of logging by not constructing messages that won't be visible at the current log level. (Thanks, [julik](https://github.com/launchdarkly/ruby-server-sdk/pull/98)!)


## [3.0.1] - 2018-02-26
### Fixed
- Fixed a bug that could prevent very large feature flags from being updated in streaming mode.


## [3.0.0] - 2018-02-22
### Added
- Support for a new LaunchDarkly feature: reusable user segments.

### Changed
- The feature store interface has been changed to support user segment data as well as feature flags. Existing code that uses `InMemoryFeatureStore` or `RedisFeatureStore` should work as before, but custom feature store implementations will need to be updated.


## [2.5.0] - 2018-02-12

## Added
- Adds support for a future LaunchDarkly feature, coming soon: semantic version user attributes.

## Changed
- It is now possible to compute rollouts based on an integer attribute of a user, not just a string attribute.

## [2.4.1] - 2018-01-23
## Changed
- Reduce logging level for missing flags
- Relax json and faraday dependencies
## Fixed
- Wrap redis bulk updates in a transaction
- Fixed documentation links

## [2.4.0] - 2018-01-12
## Changed
- Will use feature store if already initialized even if connection to service could not be established.  This is useful when flags have been initialized in redis.
- Increase default and  minimum polling interval to 30s
- Strip out unknown top-level attributes

## [2.3.2] - 2017-12-02

### Fixed
- Make sure redis store initializations are atomic


## [2.3.1] - 2017-11-16

### Changed
- Include source code for changes described in 2.3.0


## [2.3.0] - 2017-11-16
## Added
- Add `close` method to Ruby client to stop processing events
- Add support for Redis feature store
- Add support for LDD mode
- Allow user to disable outgoing event stream.

## Changed
- Stop retrying on 401 responses (due to bad sdk keys)

## [2.2.7] - 2017-07-26
## Changed
- Update Readme to fix instructions on installing gem using command line
- Cleaned up formatting on various files (Rubocop)
## [2.2.5] - 2017-05-08
## Changed
- Added proxy support to streaming and http connections. Respects `HTTP_PROXY` and `http_proxy` environment variables as well as the `:proxy => protocol://user:pass@host` configuration parameter.

## [2.1.5] - 2017-03-28
## Changed
- Updated changelog 

## [2.1.1] - 2017-03-28
## Changed
- Bumped nio4r to 2.0

## [2.0.6] - 2017-02-10
## Changed
- Improved handling of http status codes that may not be integers.

## [2.0.5] - 2017-01-31
## Changed
- Improved error handling when connected to flag update stream.

## [2.0.3] - 2016-10-21
## Fixed
- Indirect stream events are now correctly processed

## [2.0.2] - 2016-08-08
## Changed
- The default logger now logs at `info` level

## [2.0.0] - 2016-08-08
### Added
- Support for multivariate feature flags. In addition to booleans, feature flags can now return numbers, strings, dictionaries, or arrays via the `variation` method.
- New `all_flags` method returns all flag values for a specified user.
- If streaming is disabled, the client polls for feature flag changes. If streaming is disabled, the client will default to polling LaunchDarkly every second for updates. The poll interval is configurable via `poll_interval`.
- New `secure_mode_hash` function computes a hash suitable for the new LaunchDarkly JavaScript client's secure mode feature.
- Support for extremely large feature flags. When a large feature flag changes, the stream will include a directive to fetch the updated flag.

### Changed
- You can now initialize the LaunchDarkly client with an optional timeout (specified in seconds). This will block initialization until the client has finished bootstrapping and is able to serve feature flags.
- The streaming implementation (`StreamProcessor`) uses [Celluloid](https://github.com/celluloid/celluloid) under the hood instead of [EventMachine](https://github.com/eventmachine/eventmachine). The dependency on EventMachine has been removed.
- The `store` option has been renamed to `cache_store`.
- Offline mode can no longer be set dynamically. Instead, at configuration time, the `offline` parameter can be set to put the client in offline mode. It is no longer possible to dynamically change whether the client is online and offline (via `set_online` and `set_offline`). Call `offline?` to determine whether or not the client is offline.
- The `debug_stream` configuration option has been removed.
- The `log_timings` configuration option has been removed.

### Deprecated
- The `toggle` call has been deprecated in favor of `variation`.

### Removed
- `update_user_flag_setting` has been removed. To change user settings, use the LaunchDarkly REST API.
