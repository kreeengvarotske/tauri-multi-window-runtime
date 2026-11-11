# Pilot freeze candidate on WebView2 157.0.4341.46

This packet follows the uninterrupted 12/12 valid native smoke on Windows
build 26200 with WebView2 157.0.4341.46. It requires a separate written
decision to launch the pilot.

| Input | Revision or SHA-256 |
|---|---|
| Runner | 9e705738acf0c9e0e6cef2d3d929fcc9c7d6e1a1 |
| Monitor | c5a4f16b54fb4c14dc79c21a2d52d227fc0dfff9 |
| Framework | 2dac921fcccde1bbadd86da16dbb3136d00341da |
| Protocol commit | c4548e7608b251c473836e8080138aa9dba2e3f8 |
| manifest.json | 0469c0d18f21d95a67f65d565cae9c8f96103e08295f2132e74deb16a6ba6a49 |
| schedule.csv | 9dc8fb97ac8bce7e3aa8146291a97cec81afc8bfd63744b21e1732e24a5608d1 |
| protocol.md | ac91077738a1b046ca5a5a67fc2c2d67a72bddf91aa00efe1b9df31517c1b686 |

The runner remains in a separate clean checkout at the frozen revision.
This branch stores the input files. Git attributes preserve their bytes.
The 72 positions contain six matched triplets in each of four cells.
Dry run and frozen-package rehearsal produced the same manifest hash.
Compared with the previous candidate in #55, the manifest differs only in
WebView2 version.

The [native smoke report](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/54#issuecomment-6808515759)
records 12 valid runs, app and monitor exit codes of zero, and 47.01 minutes.
Interrupted data from the prior attempt is retained separately.
The results archive SHA-256 is
d5f020ea64ff34f84881d46a592e45bc97596ed1d3dc5507ce09f639e8b6d9c6.

The earlier [hosted CI](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/42706896799)
passed on retry. The missing exit notification in its first attempt
remains documented in #54.

Expect approximately 4.8 hours for the pilot plus preparation. Preserve
failed and invalid runs with reasons. Pilot results are descriptive.
Confirmatory data and thresholds require a separate freeze.

Before launch, repeat -VerifyPilotFreeze using these files and the
prebuilt binaries matching the manifest. The real invocation requires the
separately approved launch record and its SHA-256. The record must bind
this manifest, the frozen runner and the reviewed native smoke report.
