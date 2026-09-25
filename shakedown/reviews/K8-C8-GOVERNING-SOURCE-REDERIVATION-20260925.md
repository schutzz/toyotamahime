# K8 C-8 governing-source re-derivation — 2026-09-25

## 対象

- baseline candidate: `cb5ceac18f85d5af3b538e6ef151c8ca67a10966`
- contract: `shakedown/tools/K8ShakedownCommon.psm1`
- scope: `$script:K8FrozenSourceIdentity` の全9 sourceと、それらを参照するClass F / caller-role row
- C-8 model: 変更なし。source identity不一致は引き続きfail closedでSTOPする。

## 全source監査

| source | 旧SHA-256 | current SHA-256 | 分類 |
| --- | --- | --- | --- |
| `README.md` | `7ce29248f1124071a3db3e7a142cb986bc2286cfe23c2911ae43ea38ce526a66` | `5435e19ebd69cd9d07f07824835f97f3ffbd9e6405b4d8a90eeff87499e471b6` | changed-authorized |
| `studies/study-01-negative-result/protocol/freeze-decision-table.md` | `f90e687275dc0098e4de11377fe7f2ce46eadb494bcc1e1e913a8daf0977801d` | 同左 | unchanged |
| `studies/study-01-negative-result/protocol/c2-dnp3-range-derivation.md` | `ded5e1ea4019e800567b7de3b13215be9f80be5e15e83da83cc6715be24a8fe2` | `51fc89804fa543807630f6a25be2c849fcc5c0116ea9b1fbd8a338a7ca3e579d` | changed-authorized |
| `studies/study-01-negative-result/protocol/c2-dnp3-step4-range-b-fault-pilot.md` | `563e664ddde408a2136019b8dffe0ca911f5f144e2407aa1dbc15188a4e70d0c` | 同左 | unchanged |
| `studies/study-01-negative-result/protocol/k6-r-obs-05-collector-query-contract.md` | `ea657a995535414167ecb16c62d6f1897147f1f77745a13d1b52b137fd17a84b` | `66504e3d300dbf5a9396abeccb445c4cebcf3f6883005169a62893d28a4ae270` | changed-authorized |
| `studies/study-01-negative-result/protocol/c2-dnp3-capture-procedure.md` | `54cf70c6329e71356b394ac4829818eaa8b5c44db49c5c852cb386326c69b80e` | `888e5b455d4d047f278eafe24b1b7df4cc32c1f260953f41895eca4231f293d6` | changed-authorized |
| `studies/study-01-negative-result/protocol/c2-dnp3-image-inventory.md` | `9a306601c326f15f8b6d7e80ba2d7933037be322eedb125c546ecb7ef6a35b98` | 同左 | unchanged |
| `studies/study-01-negative-result/protocol/evidence-schema.md` | `b0c670734f9bab9d925e1591173f1fbe7f85209f84d315e08d5bcd2250f51137` | `ee9eba1efb785900862201ff0f58ff7c0003d830cd8883a9bf059c1f03e070d7` | changed-authorized |
| `studies/study-01-negative-result/protocol/c2-dnp3-sender-procedure.md` | `35b47f7d31973f84273a0283209def0b071614799ba362ee6b3fd105c0799683` | 同左 | unchanged |

`unexpected-change` は0件。

## changed sourceのsemantic re-derivation

分類Aはsource bytesのみ変更され既存mechanical contractが正しいもの、分類Bはcontract / process argvの最小追随が必要なもの、分類Cは科学的・規範的不整合を意味する。

### `README.md`

- affected: `F-20`, `F-21`, `F-35`
- `F-20`, `F-35`: A。preflightとRange C validatorの既存argv / exit semanticsはcurrent sourceと一致する。
- `F-21`: B。current sourceはdigest-pinned imagesを `docker compose ... up -d --no-build` で起動する。既存contract / process argvの `--build` を `--no-build` へ変更する。
- companion source-dependent validation: B。`Get-K8FrozenCandidateRangeGenCommit` のlocatorを、pin直後にannotated-tag説明を持つcurrent README行からもexact SHAを抽出できる形へ追随させる。抽出対象・fail-closed条件は変更しない。

### `c2-dnp3-range-derivation.md`

- affected: `F-02`, `F-03`, `F-05`, `F-06`, `F-07`, `F-19`, `F-33`, `F-34`
- `F-02`, `F-03`, `F-05`, `F-06`, `F-07`, `F-33`, `F-34`: A。interface resolution、fault、Range C derivationのmechanical contractに意味変更はない。
- `F-19`: B。Range A/B provisioningへ13個の固定 `--image-override service=image@sha256:...` が追加されたため、contractとprocess argvへ同じ順序・値を追加する。

### `k6-r-obs-05-collector-query-contract.md`

- affected Class F: `F-09`, `F-11`, `F-15`
- affected caller-role: `CR-01`, `CR-03`, `CR-04`, `CR-05`, `CR-06`, `CR-07`, `CR-08`
- 全てA。current sourceの独立liveness capture、mapping precondition、固定request / no-retry、correlation roleは既存行が既に表現している。

### `c2-dnp3-capture-procedure.md`

- affected Class F: `F-09`, `F-10`, `F-12`, `F-13`, `F-14`, `F-25`, `F-26`, `F-27`
- affected caller-role: `CR-01`
- 全てA。helper lifecycle、capture stage、export destination、post-capture decode roleは既存行がcurrent sourceを表現している。

### `evidence-schema.md`

- affected: `F-18`, `F-28`, `F-29`, `F-30`, `F-31`, `F-32`
- 全てA。wrapperによるtree作成、validate / finalize / cleanup / final finalize / integrity verificationの既存行はcurrent sourceと一致する。

## 結論

- affected Class F rows（重複除去）: `F-02`, `F-03`, `F-05`, `F-06`, `F-07`, `F-09`, `F-10`, `F-11`, `F-12`, `F-13`, `F-14`, `F-15`, `F-18`, `F-19`, `F-20`, `F-21`, `F-25`, `F-26`, `F-27`, `F-28`, `F-29`, `F-30`, `F-31`, `F-32`, `F-33`, `F-34`, `F-35`
- affected caller-role rows: `CR-01`, `CR-03`, `CR-04`, `CR-05`, `CR-06`, `CR-07`, `CR-08`
- A: 上記のうち `F-19`, `F-21` 以外の全行
- B: `F-19`, `F-21`
- C: なし
- Study01 sourceの変更: なし
- scientific semanticsの変更: なし。accepted current sourceを実行toolingへ機械的に反映する。
