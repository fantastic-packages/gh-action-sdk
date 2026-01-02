# OpenWrt GitHub Action SDK

GitHub CI action to build packages via SDK using official OpenWrt SDK Docker
containers. This is primary used to test build OpenWrt repositories but can
also be used for downstream projects maintaining their own package
repositories.

## Example usage

The following YAML code can be used to build all packages of a repository and
store created `apk` files as artifacts.

```yaml
name: Test Build

on:
  pull_request:
    branches:
      - main

jobs:
  build:
    name: ${{ matrix.release }} ${{ matrix.target }} build
    runs-on: ubuntu-latest
    strategy:
      matrix:
        release:
          - master
          - 24.10.1
        arch:
          - mips_24kc
          - x86_64
        include:
          - arch: mips_24kc
            target: ath79/generic
          - arch: x86_64
            target: x86/64

    steps:
      - uses: actions/checkout@v2
        with:
          fetch-depth: 0

      - name: Build
        uses: fantastic-packages/gh-action-sdk@master
        with:
          sdk_cache: false # enable caching for downloaded imagebuilder/sdk, you needs to create an empty `openwrt.org-cache` repository
          token: ${{ secrets.NEW_PERSONAL_ACCESS_TOKEN }} # only required when `sdk_cache` is enabled, used to push content to the `openwrt.org-cache` repository
        env:
          TARGET: ${{ matrix.target }}
          VERSION: ${{ matrix.release }}

      - name: Store packages
        uses: actions/upload-artifact@v2
        with:
          name: ${{ matrix.arch}}-packages
          path: bin/packages/${{ matrix.arch }}/packages/*.apk
```

## Environmental variables

The action reads a few env variables:

* `FILE_HOST` determines the used OpenWrt download server.
  E.g. `https://downloads.openwrt.org` or `https://mirrors.cicku.me/openwrt`.
* `TARGET` determines the used OpenWrt SDK target.
  E.g. `x86/64` or `ath79/generic`.
* `VERSION` determines the used OpenWrt SDK version.
  E.g. `24.10.5` or `24.10-SNAPSHOT` or `snapshots`.
* `ARTIFACTS_DIR` determines where built packages and build logs are saved.
  Defaults to the default working directory (`GITHUB_WORKSPACE`).
* `FEEDS_DIR` (Optional) determines where download feeds repo are saved.
* `DL_DIR` (Optional) determines where download source code packages are saved.
* `BUILD_LOG` stores build logs in `./logs`.
* `EXTRA_FEEDS` are added to the `feeds.conf`, where `|` are replaced by white
  spaces.
* `FEED_DIR` used in the created `feeds.conf` for the current repo. Defaults to
  the default working directory (`GITHUB_WORKSPACE`).
* `FEEDNAME` used in the created `feeds.conf` for the current repo. Defaults to
  `action`.
* `IGNORE_ERRORS` can ignore failing packages builds.
* `INDEX` makes the action build the package index. Default is 0. Set to 1 to enable.
* `KEY_BUILD` can be a private Signify/`usign` key to sign the packages (ipk) feed.
* `PRIVATE_KEY` can be a private key to sign the packages (apk) feed.
* `NO_DEFAULT_FEEDS` disable adding the default SDK feeds
* `NO_REPO_FEEDS` disable adding the `FEED_DIR` as feeds
* `NO_REFRESH_CHECK` disable check if patches need a refresh.
* `NO_SHFMT_CHECK` disable check if init files are formated
* `PACKAGES` (Optional) specify the list of packages (space separated) to be built
* `V` changes the build verbosity level.
