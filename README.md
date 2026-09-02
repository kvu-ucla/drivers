# PlaceOS Drivers

[![CI](https://github.com/PlaceOS/drivers/actions/workflows/ci.yml/badge.svg)](https://github.com/PlaceOS/drivers/actions/workflows/ci.yml)

Manage and test [PlaceOS](https://place.technology) drivers.

## Development

### `harness`

`harness` is a helper for easing development of PlaceOS Drivers.

```
Usage: ./harness [-h|--help] [command]

Helper script for interfacing with the PlaceOS Driver spec runner

Command:
    report                  check all drivers' compilation status
    spec <driver|_spec.cr>  run one driver's spec locally, failing closed
    up                      starts the harness
    down                    stops the harness
    build                   builds drivers and uploads them to S3
    format                  formats driver code
    help                    display this message
```

> `crystal spec` with the DriverSpecs mock runner is fail-*open* for assertion
> failures: it prints `... spec failed` but the process still exits `0`, so its
> exit status alone cannot be trusted as proof of success. `./harness spec
> <driver>` builds the driver with all transports, runs its spec against a local
> redis, and exits **non-zero** unless the spec process exits `0`, a genuine
> `... spec passed` marker is present, and no failure marker appears — where a
> failure marker also includes a non-zero nested driver-process exit
> (`Driver terminated with:` / `driver process exited with:` other than `0`), so
> assertion failures, compile errors, and driver crashes (including a child
> crash during unload) all fail closed. `./harness report` fails closed the same
> way for the docker/CI path.

To spin up the test harness, clone the repository and run...

```shell-session
$ ./harness up
```

Point a browser to [localhost:8085/index.html](http://localhost:8085/index.html), and you're good to go.

When the environment is not in use, remember to run...

```shell-session
$ ./harness down
```

Before committing, please run...

```shell-session
$ ./harness format
```

## Documentation

- [Existing Driver Docs](https://placeos.github.io/drivers/)
- [Writing a PlaceOS Driver](https://docs.placeos.com/tutorials/backend/write-a-driver)
- [Testing a PlaceOS Driver](https://docs.placeos.com/tutorials/backend/write-a-driver/testing-drivers)
- [Sending Emails](docs/guide-event-emails.md)
- [Environment Setup](docs/setup.md)
- [Runtime Debugging](docs/runtime-debugging.md)
- [Directory Structure](docs/directory_structure.md)
- [PlaceOS Spec Runner HTTP API](docs/http-api.md)

## Contributing

1. [Fork it](https://github.com/PlaceOS/drivers/fork)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request
