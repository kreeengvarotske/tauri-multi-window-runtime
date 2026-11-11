# Pilot freeze candidate for runner 9e70573

The files in this directory are copied byte for byte from the checked
72-position dry run. This candidate still requires written approval before
any pilot launch.

| Input | Frozen revision or SHA-256 |
|---|---|
| Runner | 9e705738acf0c9e0e6cef2d3d929fcc9c7d6e1a1 |
| Monitor | c5a4f16b54fb4c14dc79c21a2d52d227fc0dfff9 |
| Framework | 2dac921fcccde1bbadd86da16dbb3136d00341da |
| Protocol commit | c4548e7608b251c473836e8080138aa9dba2e3f8 |
| manifest.json | 9954728c5d75e7a4cf553e008c2ab495b054c31cc25ca00f68ddf92ce3018372 |
| schedule.csv | 9dc8fb97ac8bce7e3aa8146291a97cec81afc8bfd63744b21e1732e24a5608d1 |
| protocol.md | ac91077738a1b046ca5a5a67fc2c2d67a72bddf91aa00efe1b9df31517c1b686 |

Run from a separate clean checkout of the frozen runner, using the built
artifacts that match the executable hashes in manifest.json. This branch
stores the freeze inputs and is not the runner checkout.

The native Windows build 26200 smoke on this runner completed 12 of 12
valid runs in 47.3 minutes. All app and monitor exit codes were zero.
The [smoke evidence](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/54#issuecomment-6753687423)
records the source revisions and results archive hash.
The [hosted Windows run](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/42706896799)
passed on retry. Its first attempt lacked one Job Object exit notification.

The matrix has four cells, six matched triplets per cell, and 72 runs.
Each cell uses all six arm permutations. The measured smoke duration
implies about 4.8 hours for the pilot, plus preparation.
Keep all failures and invalid runs with reasons. Never replace them.
Report the pilot descriptively and keep its data separate from confirmatory data.

Before launch, repeat the runner's frozen-package rehearsal against these
files. An approved launch record must then identify this manifest, the
runner revision and the reviewed native smoke report hash.
The runner verifies the separately supplied SHA-256 of that record.

The .gitattributes file preserves the frozen bytes through checkout.
