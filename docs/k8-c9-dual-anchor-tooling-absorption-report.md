# K8-S2 Study01 C-9 dual-anchor tooling absorption report

## 対象と境界

- base producer tooling: `cdfc7309731fb65c5a328f04134d56bae575b6e2`
- implementation commit: `4c21eb7082b612ace0f552a71eed1d1eadad90b3`
- historical anchor: `k8-bootstrap-v4^{}` = `91ba5d2f7709a8938ef00fed1bcfd10c14181c8b`
- consumer export source: `8873aeeb2837b357fa39fd4b36e3b265d8eea9d5`
- dedicated branch: `c9/c9-dual-anchor-candidate-absorption`
- dedicated worktree: `C:\Users\user\.gemini\antigravity-ide\scratch\github_repo\toyotamahime-c9-dual-anchor`
- candidate worktree `C:\tw`: 変更していない

本作業は C-9 / criterion 11(a) の producer tooling と回帰試験だけを対象とする。Study01 amended candidate の construction、commit、ref、ledger、verification および K8-S2 authorization は対象外である。

## 原因と設計上の分類

修正前の B3B-05 immutable-base/frozen-path regression は、現在の checkout の `Study01`、`bootstrap`、`docs/k8-packaging-certification.md` が immutable v4 base と常に byte-for-byte 同一であることを要求していた。そのため、accepted amended-candidate design に従う正当な candidate delta も C-9 FAIL になった。

accepted dual-anchor の解釈は次のとおりである。

```text
historical K6/K7 apparatus
  -> fixed v4 commit 91ba5d2f7709a8938ef00fed1bcfd10c14181c8b

K8-S2 amended candidate
  -> exact 40-hex candidate commit
  -> candidate commit 内の Study01 tree
  -> candidate attestation の closed delta と blob binding
  -> 最終的な candidate acceptance は formal candidate verifier に委譲
```

moving ref を authority にせず、historical v4 anchor を維持したまま責任を分離できるため、design revision は不要である。

## 実装

`Test-K8FrozenPathIdentity` を追加した。

- historical path は fixed v4 commit の実在、ancestry、frozen paths の byte identity を検査する。
- frozen delta が存在する場合だけ candidate path に入り、入力を exact 40-hex commit に限定する。
- exact commit 内の `docs/k8-study01-amended-candidate-attestation.json` から authority を読み、moving ref、fetch、branch 名による例外を使わない。
- observed frozen delta と attested delta の閉集合一致、`claims` / `expected` 不変、base/new blob binding、code-bearing path の accepted blob binding を fail-closed で検査する。
- formal candidate verifier の machine checks、T/C/L checks、packaging readiness は複製せず、戻り値 `candidate_verification = required` により委譲境界を明示する。
- C-8 command contract に 2 call site を追加し、closed-world inventory を `112 (F 37 / C 72 / I 3)` に更新した。

producer source identity、canonical remote/ref publication check、qualification sequence locked HEAD check は変更していない。

## BEFORE / AFTER

```text
BEFORE
  legitimate amended-candidate semantic delta
  -> current frozen paths != immutable v4 base
  -> C-9 FAIL

AFTER
  same semantic fixture + exact commit + closed authority binding
  -> amended-candidate-delegated
  -> expected PASS（formal candidate verification は required）

AFTER
  arbitrary extra frozen byte / unlisted delta
  -> C-9 FAIL
```

fixture は Class A の code-bearing delta と Class B の publication binding を含む candidate-shaped Git repository を合成する。production candidate OID、candidate_id、real blob allowlist は実装へ hard-code していない。

## 回帰結果

Commit A を作成する前の全回帰、および clean worktree の exact implementation commit `4c21eb7082b612ace0f552a71eed1d1eadad90b3` に対する全回帰で、次を確認した。

```text
historical fixed-base invariant                 PASS
moving-base rejection                          PASS
valid candidate-shaped delta                   PASS
arbitrary frozen-byte mutation                 PASS (fail-closed)
unlisted delta                                 PASS (fail-closed)
claims mutation                                PASS (fail-closed)
expected mutation                              PASS (fail-closed)
candidate authority missing                    PASS (fail-closed)
candidate authority malformed                  PASS (fail-closed)
listed blob mismatch                           PASS (fail-closed)
moving/unresolvable candidate identity         PASS (fail-closed)
non-vacuity                                    PASS
no hard-coded production candidate truth       PASS
C-8 closed-world contract                      PASS
producer full regression                       All Shakedown regression checks PASS.
```

実行 command:

```powershell
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -File .\shakedown\tests\Test-K8ShakedownRegression.ps1
```

clean exact-commit run の終了コードは `0` である。既存 test の削除、skip 追加、C-9 bypass は行っていない。

## 不変事項と残る境界

- forbidden candidate paths (`Study01/`, `bootstrap/`, `docs/k8-study01-amended-candidate-attestation.json`, `docs/k8-candidates/`): 変更なし
- `k8-bootstrap-v4`: 変更なし
- `k8-bootstrap-v5`: NOT CREATED
- candidate commit: NOT CREATED
- candidate ref: NOT CREATED
- ledger: NOT CREATED
- K8-S2: NOT AUTHORIZED

本レポートは実装者側の結果であり、独立 acceptance ではない。独立レビュー対象は Commit A `4c21eb7082b612ace0f552a71eed1d1eadad90b3` である。状態は `AUTHORED / PENDING INDEPENDENT EXACT-COMMIT REVIEW` とする。
