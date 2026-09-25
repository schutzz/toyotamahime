# K8-S2 execution dependency reconciliation — 2026-09-26

## 対象

- baseline: `94b576e046b0d02ebebe04c019e4b3af9abd1413`
- Study01 Range A/B pin: `v0.13.5` / `80e550ffeab8daa6583590add490433a0305bb53`
- Study01 Range C pin: `v0.13.1` / `1d0fa75725078100e9da2e8492ca977ba8e89d95`
- scope: Shakedown execution dependencies and dependency-specific exception machinery only

## divergence audit

| item | old Shakedown state | accepted Study01 state | classification | action |
| --- | --- | --- | --- | --- |
| Range A/B generator | `16ec5a00d99efd26ddddfbbdb47712866861386f` | `80e550ffeab8daa6583590add490433a0305bb53` | obsolete | accepted pinへ更新 |
| F-20 RangeGen mismatch exception | exit 1 special acceptance、schema / record / parser / checker | natural preflight PASS、exit 0 | obsolete | 全て削除 |
| Range C validator / locale workaround | `v0.13.0` / `0378f8a32701b481e030f3db3d5f66ea471a4675` + `PYTHONUTF8=1` | `v0.13.1` / `1d0fa75725078100e9da2e8492ca977ba8e89d95` | obsolete | accepted pinへ更新しworkaround削除 |

- total intentional divergences found: 3
- current-required: 0
- obsolete: 3
- unexpected: 0

## exact-source verification

- `80e550ffeab8daa6583590add490433a0305bb53:platform/cli.py` は `--image-override NAME=REF` を `action="append"` で実装する。
- F-19はaccepted sourceに記載された13個のexact `service=image@sha256:...` を維持する。
- F-21は `docker compose ... up -d --no-build` を維持する。
- `1d0fa75725078100e9da2e8492ca977ba8e89d95:requirements.txt` の先頭は `# -*- coding: utf-8 -*-`。
- v0.13.1が旧cp932 decode defectをsource側で閉じているため、Shakedownの `PYTHONUTF8=1` は独立に必要ではない。

## gate effect

- F-20 `accepted_exit_codes`: `@(0)`
- execution-override acceptance schema / record path / parser / acceptance function: 削除
- C-8 / C-9 / preflight: 緩和なし
- Study01 / claims / expected / scorer: 変更なし

## regression

- focused dependency regression: PASS
- full Shakedown regression: `PASS 347 / FAIL 0 / SKIP 0 / exit 0`
