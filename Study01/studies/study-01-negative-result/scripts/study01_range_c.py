#!/usr/bin/env python3
"""Formal Range C observation producer; exactly one validator invocation.

The observation and packaging phases are separated.  `observe` retains raw
bytes and typed mechanical facts.  The promoted
`k8_rangec_formal_package.py build --formal-attempt-dir` command later combines
those facts with the three human-authored narrative files.
"""
import argparse, hashlib, importlib.metadata, json, shutil, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path

PIN = "1d0fa75725078100e9da2e8492ca977ba8e89d95"
ACCEPTED_EXITS = (0, 1)


def run(argv, cwd=None, check=True, text=True):
    p=subprocess.run(argv,cwd=cwd,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=text)
    if check and p.returncode: raise RuntimeError(f"command failed ({p.returncode}): {argv!r}: {p.stderr}")
    return p


def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def dump(path,obj): path.parent.mkdir(parents=True,exist_ok=True); path.write_text(json.dumps(obj,indent=2)+"\n",encoding="utf-8",newline="\n")


def candidate(candidate_id, kind, source, fact, reason, artifacts, observed_utc):
    return {"candidate_id":candidate_id,"class":kind,"observed_utc":observed_utc,
            "source":source,"observed_fact":fact,"reason_surfaced":reason,
            "related_artifacts":[{"kind":"run-local","path":p} for p in artifacts]}


def deviation_candidates(observation, environment, accepted_exits, observed_utc):
    accepted_exits=tuple(accepted_exits)
    obs=observation["observations"][0]; result=[]
    if obs["exit_code"] == 0 and obs["stderr"]["bytes"] > 0:
        result.append(candidate("dc-001","internal-inconsistency",{"record":"validate.observation.json","field":"observations[0]"},
            f"exit_code = 0 was retained alongside {obs['stderr']['bytes']} byte(s) on stderr.",
            "Two retained facts of the same observation cannot both hold: exit 0 reports no rejection while stderr is non-empty.",
            ["validate.observation.json","validate.stderr.txt"],observed_utc))
    if len(accepted_exits) > 1:
        next_id=f"dc-{len(result)+1:03d}"
        declared=", ".join(str(value) for value in accepted_exits)
        result.append(candidate(next_id,"multi-valued-acceptance",{"record":"validate.observation.json","field":"observations[0].exit_code"},
            f"The validator exited {obs['exit_code']}; this call site declares accepted exits [{declared}].",
            "The call site declares more than one accepted exit code, so which occurred is decision-relevant; neither outcome is judged here.",
            ["validate.observation.json","validate.stdout.txt"],observed_utc))
    for entry in environment["versions"]:
        if entry["status"] != "succeeded":
            result.append(candidate(f"dc-{len(result)+1:03d}","incomplete-observation",
                {"record":"range-c-environment.json","field":f"versions[{entry['name']}].status"},
                f"The resolved version of '{entry['name']}' was not observed: status '{entry['status']}', value '{entry['value']}'.",
                "A typed environment field contracted for observation was unavailable.",
                ["range-c-environment.json"],observed_utc))
    for which in ("source","disposable"):
        if not (environment.get("worktree",{}).get(which) or {}).get("head"):
            result.append(candidate(f"dc-{len(result)+1:03d}","incomplete-observation",
                {"record":"range-c-environment.json","field":f"worktree.{which}.head"},
                f"The {which} validator worktree HEAD was not observed.",
                "A typed environment field contracted for observation is missing.",
                ["range-c-environment.json"],observed_utc))
    return result


def bind_producer_records(producer, records, evidence):
    names=("range-c-environment.json","deviation-candidates.json")
    for name in names: shutil.copyfile(records/name,evidence/name)
    paths=[producer/"run-records"/n for n in names]+[producer/"run-evidence"/n for n in names]
    lines=[f"{sha(p)}  {p.relative_to(producer).as_posix()}\n" for p in paths]
    (producer/"producer-records.sha256").write_text("".join(lines),encoding="utf-8",newline="\n")


def observe(a):
    source=a.source.resolve(); attempt=a.attempt_dir.resolve()
    attempt_record=json.loads((attempt/"attempt.json").read_text(encoding="utf-8-sig"))
    attempt_id=attempt_record.get("attempt_id") or attempt.name
    producer=attempt/"range-c-producer"/a.validation_id
    evidence=producer/"run-evidence"; records=producer/"run-records"; disposable=producer/"worktree"
    if producer.exists(): raise RuntimeError(f"refusing to reuse existing Range C producer directory: {producer}")
    evidence.mkdir(parents=True); records.mkdir(parents=True)
    if run(["git","-C",str(source),"status","--porcelain"]).stdout.strip(): raise RuntimeError("Range C source checkout is dirty")
    head=run(["git","-C",str(source),"rev-parse","HEAD"]).stdout.strip()
    if head != PIN: raise RuntimeError(f"Range C source HEAD {head} != pinned {PIN}")
    run(["git","clone","--no-hardlinks",str(source),str(disposable)])
    run(["git","-C",str(disposable),"checkout","--detach",PIN])
    base=disposable/"manifests"/"power-grid-reference.yaml"
    negative=disposable/"manifests"/"power-grid-reference.range-c-negative.yaml"
    shutil.copyfile(base,negative)
    patch_source=Path(__file__).parents[1]/"experiments"/"range-c-negative-manifest"/"power-grid-reference.range-c-negative.patch"
    derived=disposable/"range-c-derived.patch"
    derived.write_text(patch_source.read_text(encoding="utf-8").replace("power-grid-reference.yaml","power-grid-reference.range-c-negative.yaml"),encoding="utf-8",newline="")
    run(["git","apply","--ignore-space-change","--check",str(derived)],cwd=disposable)
    run(["git","apply","--ignore-space-change",str(derived)],cwd=disposable)
    shutil.copyfile(negative,evidence/negative.name); shutil.copyfile(derived,evidence/derived.name)
    clean = not bool(run(["git","-C",str(disposable),"status","--porcelain"]).stdout.strip())
    started=datetime.now(timezone.utc).isoformat()
    argv=[sys.executable,"platform/cli.py","validate","manifests/power-grid-reference.range-c-negative.yaml"]
    proc=run(argv,cwd=disposable,check=False,text=False)
    (evidence/"validate.stdout.txt").write_bytes(proc.stdout)
    (evidence/"validate.stderr.txt").write_bytes(proc.stderr)
    if proc.returncode not in ACCEPTED_EXITS: raise RuntimeError(f"validator apparatus failure: exit {proc.returncode}")
    obs={"schema":"k8-command-observation/1","observations":[{"argv":argv,"exit_code":proc.returncode,
         "timestamp_utc":started,"stdout":{"path":"validate.stdout.txt","bytes":len(proc.stdout),"sha256":sha(evidence/"validate.stdout.txt")},
         "stderr":{"path":"validate.stderr.txt","bytes":len(proc.stderr),"sha256":sha(evidence/"validate.stderr.txt")}}]}
    dump(evidence/"validate.observation.json",obs)
    versions=[]
    for name,value in (("git",run(["git","--version"]).stdout.strip()),("python",sys.version.split()[0]),
                       ("pydantic",importlib.metadata.version("pydantic")),("pyyaml",importlib.metadata.version("PyYAML"))):
        versions.append({"name":name,"value":value,"status":"succeeded","phase":"range-c-run","observed_utc":started,"source":"formal-observe","probe_argv":[]})
    env={"schema":"k8shakedown-range-c-environment/1","attempt_id":attempt_id,"validation_id":a.validation_id,"range":"c",
         "validator_source":{"pinned_commit":PIN},"worktree":{"source":{"head":head,"clean":True},"disposable":{"head":PIN,"clean":clean}},
         "versions":versions,"observed_utc":started}
    dump(records/"range-c-environment.json",env)
    candidates=deviation_candidates(obs,env,ACCEPTED_EXITS,started)
    dump(records/"deviation-candidates.json",{"schema":"k8shakedown-deviation-candidates/1","attempt_id":attempt_id,
         "validation_id":a.validation_id,"range":"c","generated_utc":started,
         "note":"Machine-surfaced candidates only; whether a candidate is a deviation and any declaration of None are human judgments in deviations.md.",
         "candidates":candidates})
    bind_producer_records(producer,records,evidence)
    print(json.dumps({"validation_id":a.validation_id,"producer":str(producer),"run_evidence":str(evidence),"run_records":str(records),
                      "validator_exit_code":proc.returncode,"candidates_surfaced":len(candidates),
                      "producer_manifest":str(producer/"producer-records.sha256")},indent=2))


def main():
    p=argparse.ArgumentParser(); p.add_argument("--source",type=Path,required=True); p.add_argument("--attempt-dir",type=Path,required=True); p.add_argument("--validation-id",required=True)
    a=p.parse_args()
    try: observe(a)
    except (RuntimeError,OSError,KeyError) as e: p.error(str(e))
if __name__=="__main__": main()
