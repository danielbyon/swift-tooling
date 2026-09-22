# swift-tooling

Portable, pinned SwiftFormat and SwiftLint tooling for macOS/Xcode repositories.

The repository publishes release archives rather than requiring consumers to
clone or vendor the implementation. A release contains the runner, baseline
format/lint policy, a consumer adapter, and an editable local-configuration
template. Mint and the Swift tools remain separately downloaded and verified by
the runner.

## Install in a repository

Run this from the target repository. It resolves the latest release once,
verifies the archive, installs it under `.tools/`, adds `.tools/` to
`.gitignore`, and creates the adapter and local configuration template:

```bash
setup_script=$(mktemp) && curl --fail --location --silent --show-error \
  https://github.com/danielbyon/swift-tooling/releases/latest/download/setup-swift-tools.sh \
  --output "$setup_script" && bash "$setup_script" --repository-root "$PWD"; status=$?; rm -f "$setup_script"; exit "$status"
```

Complete `Scripts/swift-tools-local.sh` before running the adapter. The file
declares the Swift source roots, local `.swiftformat` and `.swiftlint.yml`
overlays, and any repository-owned Xcode command prefix.

```bash
Scripts/swift-tools.sh bootstrap
Scripts/swift-tools.sh format
Scripts/swift-tools.sh lint
```

The release version and checksum are tracked in
`Scripts/swift-tools.lock`. Reinstalling the same release is a no-op for
tracked files. `Scripts/swift-tools.sh update` resolves a newer release and
updates only the adapter/lock pair; it never overwrites the local config.

## Consumer contract

The local configuration uses Bash arrays so paths remain safe when they contain
spaces:

```bash
SWIFT_TOOLS_SOURCE_PATHS=(Sources Tests)
SWIFT_TOOLS_SWIFTFORMAT_CONFIG=.swiftformat
SWIFT_TOOLS_SWIFTLINT_CONFIG=.swiftlint.yml
SWIFT_TOOLS_COMMAND_PREFIX=()
```

Apps can set `SWIFT_TOOLS_COMMAND_PREFIX` to a repository-owned Xcode selector.
Compiler-backed SwiftLint analysis remains a consumer-owned adapter because
Xcode workspace/scheme topology is not shared by SwiftPM libraries and apps.

## Development

```bash
make test
make lint
make release VERSION=v0.1.0
```
