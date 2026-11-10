# AGENTS.md

## Project overview

Kelivo is a cross-platform LLM chat client built with Flutter, targeting iOS, Android, macOS, Windows, and Linux. Package name is `Kelivo` — imports use `package:Kelivo/...`.

## Architecture

- **Feature-based structure**: `lib/features/<feature>/` with `pages/`, `widgets/`, `models/`, `utils/` subdirectories.
- **Desktop / mobile split**: most UI pages have separate desktop and mobile layouts (e.g. `home_desktop_layout.dart` / `home_mobile_layout.dart`). Desktop-only code lives in `lib/desktop/`. Use `ResponsiveHelper` from `lib/shared/responsive/` to branch by screen type.
- **State management**: Provider (`lib/core/providers/`).
- **Database**: Drift (`lib/core/database/`). Schema versions tracked in `drift_schemas/`.
- **Localization**: edit `lib/l10n/app_en.arb` and `app_zh.arb` for product changes. Give every English key an `@key.description` explaining its UI location, meaning, and placeholders; update that description when the meaning changes. Keep both source key sets identical. Run `tool/l10n/translate.py sync`, then `check`, using a real Python 3 interpreter; commit the translated ARBs, translation state, and generated Dart output. On this Windows setup `python` / `python3` / `py` are not on PATH — resolve an absolute interpreter path first instead of assuming a bare `python3` works. The tool synchronizes `app_zh_Hans.arb` and translates the other languages from both sources plus the descriptions. For credentials, adding languages, or translation corrections, read [the localization workflow](tool/l10n/README.md). Inspect affected keys and tool summaries instead of loading every language file into the agent context.

## Pre-commit checklist

Format changed Dart files with `dart format`, including files under `lib/`,
`test/`, `integration_test/`, `tool/`, `dependencies/markstream/lib/`, and
`dependencies/markstream/test/`. For code changes, run static analysis before
committing:

```bash
flutter pub get --directory tool/l10n --enforce-lockfile
dart analyze --fatal-infos lib test integration_test tool
(cd dependencies/markstream && flutter pub get && dart analyze --fatal-infos)
```

Then sweep for leftovers from this round of work — debug prints, temporary
scripts or mocks, hardcoded placeholder data, temporary flags, and any code
kept only for debugging. Delete what is clearly scratch; keep real business
code, regression tests, fixtures, and logs you are still relying on. List
anything ambiguous (path, purpose, risk) instead of deciding for the user.

For ordinary changes, run only the test files or directories covering the
changed behavior and affected callers, using `flutter test <test paths>`.
If `markstream` is affected, also run its relevant tests from
`dependencies/markstream`; root-package checks do not cover this path package.

Run the full test suites locally only when merging a major feature, such as a
cross-feature integration or broad architectural change:

```bash
flutter test
(cd dependencies/markstream && flutter pub get && flutter test)
```

All required checks must pass. Documentation-only changes do not require Dart
analysis or Flutter tests.

`pr-check.yml` only triggers on PRs into `Chevey339/kelivo`. This fork pushes
to a branch and opens no PR upstream, so **nothing runs in CI here** — the
local pre-push gate is the only automated guardrail.

## Fixed boxes must scale

Flutter scales text through the global `TextScaler` but leaves container
geometry alone, so a literal box wrapped around scaled text wraps or clips at
145% and above. Wrap geometry in `scaledDim(context, n)` (`lib/utils/ui_scale.dart`,
`lib/utils/avatar_scale.dart`) and keep the `fontSize` literal — the framework
already multiplies it. Pinning the text (`maxLines: 1` + `softWrap: false`) is
the other accepted fix.

Every upstream release lands new UI written with bare literals, so sweep the
files a version adds before pushing:

```bash
grep -nE 'SizedBox\((width|height):\s*\d|\b(width|height):\s*\d+,|\bsize:\s*\d+,' <file.dart>
```

The pre-push gate (`deploy/pre_push_check.ps1`, check `[5]`) audits added lines
for this and blocks the push. `deploy/` is **untracked**, so a fresh clone has
neither the script nor the hook — run `deploy/install_hooks.ps1` first. When the
gate must audit a checkout other than the one the script lives in, pass
`-Repo <path>`; without it the script refuses to run from a different repo.

To restore a generated file to its committed state, use
`git checkout -- <file>`. `git show HEAD:<file> > <file>` writes LF into a
CRLF working tree, so `git status` keeps showing `M` while `git diff` is empty —
it looks like the restore silently failed. `tools/check-tools.ps1` flags that
state.

## Benchmarks are not tests

`test/perf/*_bench.dart` print timings and contain no `expect()`, so they cannot
fail. They are named out of the default `_test.dart` glob and so are skipped by
`flutter test`. Run one explicitly:

```bash
flutter test test/perf/timeline_scroll_bench.dart
```

## UI guidelines

- **Use app-defined widgets** from `lib/shared/widgets/` and `lib/shared/dialogs/` instead of raw Flutter/Material widgets wherever an equivalent exists (e.g. `SectionCard`, `CustomBottomSheet`, `IosFormTextField`, `IosCheckbox`, `InteractiveDrawer`).
- **BottomSheet**: both Flutter's built-in bottom sheet and `CustomBottomSheet` are fine on mobile. Never use any bottom sheet on desktop — use a dialog or another interaction pattern instead.
- **Icons**: use `lucide_icons_flutter`, not `Icons.*` from Material.
- **Animations**: use `flutter_animate` / `animations` for motion.
- When building a new page, create separate desktop and mobile layouts unless the page is trivially simple. Wire them together via `ResponsiveHelper`.

## Code style

- Do not preserve backward compatibility. Remove obsolete paths instead of adding compatibility layers, fallbacks, or migrations.
- Choose the simplest implementation that fully meets the current requirements. Avoid speculative abstractions, configuration, and indirection.
- Grow the system in layers. Start from the smallest version that works end to end, and add each new capability on top of a product that already works. Never trade a working product for unfinished complexity.
- Keep components modular and concerns clearly separated.
- Prefer established, well-maintained libraries when they reduce overall complexity or improve reliability. Do not reimplement common functionality without a clear reason.
- Lean on the dependencies already in the project before writing your own implementation or adding packages. Do not assume a library lacks a capability without checking its documentation and types.
- Make architectural decisions for the long term. Do not accept a stopgap that only works for now and is meant to be replaced later.

## Local dependencies

Several packages live under `dependencies/` and are referenced by path in `pubspec.yaml` (e.g. `markstream`, `mcp_client`, `flutter_tts`, `flutter_math_fork`, `downsize`). The analyzer excludes `dependencies/flutter_math_fork/**` and `dependencies/flutter_tts/**`.

## Useful commands

```bash
flutter pub get                             # install dependencies
flutter gen-l10n                            # regenerate l10n files
dart run build_runner build                 # regenerate Drift code
```

## Agent skills

### Issue tracker

Local markdown files under `.scratch/<feature>/`. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical roles, label strings identical to the role names. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: root `CONTEXT.md` plus `docs/adr/` — neither exists yet, proceed silently if absent. See `docs/agents/domain.md`.

## Guardrails

| Rule | Enforced by |
|---|---|
| Static analysis clean before pushing | `deploy/pre_push_check.ps1` check `[1]` (git pre-push hook) |
| Commit author emails are noreply addresses | gate check `[2]` |
| No keys / build junk among net-new files | gate check `[3]` |
| No absolute local paths in added lines | gate check `[4]` |
| Fixed boxes must scale (`scaledDim`) | gate check `[5]` |
| The gate must not silently audit a different repo | `pre_push_check.ps1` exits `2` when cwd is another git repo |
| `.ps1` tooling is UTF-8 BOM + parses clean | `deploy/check-tools.ps1` (run after editing any script) |
| No EOL-only `M` files left in the tree | `deploy/check-tools.ps1` |

`deploy/` is untracked, so every guardrail above travels with this machine, not
with the repo. On a fresh clone: `deploy/install_hooks.ps1` for the hook, then
`deploy/check-tools.ps1` for the script hygiene checks.
