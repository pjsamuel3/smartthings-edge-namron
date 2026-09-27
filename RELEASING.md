# Releasing

Publishing to the **Namron Edge Drivers** channel pushes code to every hub that has enrolled in it. Treat it like a production deploy. Only the maintainer publishes.

## One-time account hygiene

- Turn on two-step verification on the Samsung account that owns the channel. Anyone with access to that account can publish to every enrolled hub.
- Don't keep SmartThings personal access tokens in this repo, in CI or in shell history. The CLI's browser login is enough.

## Release checklist

1. Make sure the change is merged to `main` through a pull request and the **Test** workflow is green.
2. Start from a clean checkout of the exact commit you are releasing:
   ```bash
   git switch main && git pull --ff-only && git status --porcelain   # must print nothing
   ```
3. Tag it, then push the tag:
   ```bash
   git tag -a vYYYY.MM.DD -m "namron-edge-thermostat release" && git push origin vYYYY.MM.DD
   ```
4. Package and publish:
   ```bash
   smartthings edge:drivers:package drivers/namron-edge-thermostat
   smartthings edge:channels:assign
   ```
5. Create a GitHub release for the tag. Include the **driver version** printed by `package` (a timestamp) and a short changelog, so the version on a hub can be traced back to a commit.
6. Update one of your own devices first and watch `smartthings edge:drivers:logcat` before announcing the release.

## Rolling back

Check out the previous release tag and repeat steps 4–5. The hubs pick up the re-published version like any other update.
