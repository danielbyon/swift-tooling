# swift-tooling

Portable, pinned SwiftFormat and SwiftLint tooling for macOS/Xcode repositories.

The repository publishes release archives rather than requiring consumers to
clone or vendor the implementation. A release contains the runner, baseline
format/lint policy, a consumer adapter, and an editable local-configuration
template. Mint and the Swift tools remain separately downloaded and verified by
the runner.

## Install in a repository

Run this from the target repository. It resolves the selected release once,
verifies the archive, installs it under `.tools/`, adds `.tools/` to
`.gitignore`, and creates the adapter and local configuration template:

```bash
tooling_version=v0.1.1
setup_script=$(mktemp) && curl --fail --location --silent --show-error \
  "https://github.com/danielbyon/swift-tooling/releases/download/$tooling_version/setup-swift-tools.sh" \
  --output "$setup_script" && bash "$setup_script" \
  --repository-root "$PWD" --release-version "$tooling_version"; status=$?; rm -f "$setup_script"; exit "$status"
```

The versioned URL and release pin make the bootstrap reproducible. Update
`tooling_version` deliberately when adopting a newer shared release.

Complete `Scripts/swift-tools-local.sh` before running the adapter. The file
declares the Swift source roots and any repository-owned Xcode command prefix.
Set the optional `.swiftformat` and `.swiftlint.yml` overlay paths only when
the repository needs customizations; repositories that accept the shared
baseline do not need either overlay file.

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
# Optional; omit either path when the shared baseline is sufficient.
SWIFT_TOOLS_SWIFTFORMAT_CONFIG=.swiftformat
SWIFT_TOOLS_SWIFTLINT_CONFIG=.swiftlint.yml
SWIFT_TOOLS_COMMAND_PREFIX=()
```

The shared runner layers the release baseline before each configured overlay.
The overlay files should contain only repository-specific options. SwiftFormat
uses a generated effective config, while SwiftLint receives the baseline and
overlay as a parent-child config pair.

Apps can set `SWIFT_TOOLS_COMMAND_PREFIX` to a repository-owned Xcode selector.
Compiler-backed SwiftLint analysis remains a consumer-owned adapter because
Xcode workspace/scheme topology is not shared by SwiftPM libraries and apps.
The shared baseline intentionally contains only rules enforced by `swiftlint
lint`; consumers that have a compiler log can add analyzer rules to their local
overlay and invoke `Scripts/swift-tools.sh configured swiftlint analyze ...` in
their own adapter.

## Development

```bash
make test
make lint
make validate-config
make release VERSION=v0.1.1
```
