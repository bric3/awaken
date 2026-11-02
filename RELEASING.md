# Releasing

The [workflow](.github/workflows/release.yml) builds on pushes to `master` and on GitHub's `release: published` event. It uses `GITHUB_TOKEN` with `contents: write`. Runs are serialised; stale master builds skip draft updates.

Keep release immutability disabled: the published-release job uploads assets after publication. Draft refreshes replace all assets with the universal binary and its checksum. Published-release uploads replace those two files and preserve other assets.

## Versions

SwiftPM embeds the version in the executable. The installed tool needs neither Git nor a version file.

| Source state                    | Embedded version |
| ------------------------------- | ---------------- |
| No release tags or Git metadata | `0.1.0-SNAPSHOT` |
| Clean checkout at `v0.1.0-rc.1` | `0.1.0-rc.1`     |
| Clean checkout at `v0.1.0`      | `0.1.0`          |
| Development after either tag    | `0.1.1-SNAPSHOT` |

Development uses the highest reachable release version, removes its prerelease suffix, increments the patch, and appends `-SNAPSHOT`. Dirty builds use the development version. Master CI uses snapshot mode when there is no draft to refresh.

Release builds require a clean checkout at the selected tag. The embedded version must match the tag without its leading `v`.

## Development draft

Create a draft in GitHub with its intended version tag, such as `v0.1.0` or `v0.1.0-rc.1`, and set the prerelease checkbox to match. Leave the Git tag uncreated until publication.

Each successful current `master` build refreshes the newest draft by creation date. CI preserves its title, release notes, tag and prerelease flag, updates the target commit, and uploads `awaken-macos-universal` and its `.sha256` file. The executable embeds the draft's version. CI creates the tag only in its private checkout for versioning, then verifies the updated target and uploads.

When there is no draft, CI tests and builds a snapshot without uploading it. An existing Git tag causes draft preparation to fail. Stale master builds and drafts changed during a build skip the update. A test or build failure leaves the draft unchanged; upload failures fail the run and can leave incomplete assets. Check the successful Actions run before publishing. Saving a draft does not start a build; create it before the next push to `master`.

## Publish from GitHub

Open the refreshed draft or create a release. Select the target commit and a new tag:

| Tag           | Prerelease checkbox | Embedded version |
| ------------- | ------------------- | ---------------- |
| `v0.1.0-rc.1` | Checked             | `0.1.0-rc.1`     |
| `v0.1.0`      | Unchecked           | `0.1.0`          |

Click **Publish release**. [The published event](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#release) covers stable releases and prereleases, including publication from a draft. The job checks out the exact tag, tests it, builds and signs both architectures, verifies the embedded version, then uploads `awaken-macos-universal` and its `.sha256` file to that release.

Published releases use `gh release upload --clobber` to replace the binary and checksum. This preserves release metadata and avoids [GitHub's workflow-permission check when updating a release target](https://docs.github.com/en/rest/releases/releases#update-a-release). Reruns preserve the title, release notes, prerelease flag and other assets.

To finalise a candidate, create a new final tag and release. Changing the prerelease checkbox does not rename an `-rc.N` version. Assets appear after the build succeeds; monitor the Actions run for failures.

## Publish from the CLI

Create a draft prerelease before the next push to `master`:

```sh
gh release create v0.1.0-rc.1 --target master --draft --prerelease --generate-notes
```

After CI refreshes its assets, publish it:

```sh
gh release edit v0.1.0-rc.1 --draft=false
```

Publication uses the same published-release workflow as the GitHub interface. Omit `--prerelease` and use a final version tag to prepare a stable release.

## Universal build

SwiftPM builds each architecture separately in its own scratch directory, then `lipo` combines them. This avoids the Xcode universal-build failure when resolving the `BuildVersion` plugin. The job ad-hoc signs the combined executable, verifies both architectures, and creates SHA-256 checksums.
