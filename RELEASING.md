# Releasing

The [workflow](.github/workflows/release.yml) builds on pushes to `master` and on GitHub's `release: published` event. It uses `GITHUB_TOKEN` with `contents: write`. Runs are serialised; stale master builds skip draft updates.

Keep release immutability disabled: the published-release job uploads assets after publication.

## Versions

SwiftPM embeds the version in the executable. The installed tool needs neither Git nor a version file.

| Source state                    | Embedded version |
| ------------------------------- | ---------------- |
| No release tags or Git metadata | `0.1.0-SNAPSHOT` |
| Clean checkout at `v0.1.0-rc.1` | `0.1.0-rc.1`     |
| Clean checkout at `v0.1.0`      | `0.1.0`          |
| Development after either tag    | `0.1.1-SNAPSHOT` |

Development uses the highest reachable release version, removes its prerelease suffix, increments the patch, and appends `-SNAPSHOT`. Dirty builds use the development version. Master CI forces snapshot mode even when HEAD has a release tag.

Release builds require a clean checkout at the selected tag. The embedded version must match the tag without its leading `v`.

## Development draft

Each successful current `master` build creates or updates one managed draft. It suggests the next final tag and targets the built commit without creating a Git tag.

The draft carries `awaken-macos-universal-SNAPSHOT` and its `.sha256` file. Its managed body block records the embedded version and commit. User notes, title and tag selection are preserved. Unrelated drafts and existing Git tags remain unchanged. Failed builds leave the previous draft intact.

## Publish from GitHub

Open the managed draft or create a release. Select the target commit and a new tag:

| Tag           | Prerelease checkbox | Embedded version |
| ------------- | ------------------- | ---------------- |
| `v0.1.0-rc.1` | Checked             | `0.1.0-rc.1`     |
| `v0.1.0`      | Unchecked           | `0.1.0`          |

Click **Publish release**. [The published event](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#release) covers stable releases and prereleases, including publication from a draft. The job checks out the exact tag, tests it, builds and signs both architectures, verifies the embedded version, then uploads `awaken-macos-universal` and its `.sha256` file to that release.

Snapshot assets are removed after a successful upload. Saving a draft does not trigger a release build. Reruns replace workflow assets and preserve release notes.

To finalise a candidate, create a new final tag and release. Changing the prerelease checkbox does not rename an `-rc.N` version. Assets appear after the build succeeds; monitor the Actions run for failures.

## Publish from the CLI

Create a prerelease:

```sh
gh release create v0.1.0-rc.1 --target master --prerelease --generate-notes
```

Publish the existing final draft:

```sh
gh release edit v0.1.0 --draft=false
```

Both operations use the same published-release workflow as the GitHub interface. Creating a release with `gh release create --draft` leaves it unpublished and does not start a release build.

## Universal build

SwiftPM builds each architecture separately in its own scratch directory, then `lipo` combines them. This avoids the Xcode universal-build failure when resolving the `BuildVersion` plugin. The job ad-hoc signs the combined executable, verifies both architectures, and creates SHA-256 checksums.
