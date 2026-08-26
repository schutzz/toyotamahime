# Toyotamahime

Public research repository for a programme on **whether experimental results from cyber ranges can be trusted** — in particular, what has to hold before a detection experiment's "no alert" may be read as evidence about a detector at all.

Each study lives in its own directory and is self-contained: apparatus, protocol, expected results, claims, and instructions for reproducing it.

| Directory | Study | State |
| --- | --- | --- |
| [`Study01/`](./Study01/) | **Negative-result validity in an OT/ICS cyber range.** One frozen DNP3 event, an observation-valid range and a fault-injected one, and a static contract-violation manifest. | claims frozen; reproduction kit published |
| `Study02/` | planned | not yet present |

## Where to start

**If you want to reproduce Study 01 → [`Study01/README.md`](./Study01/README.md).** That is the runbook. Everything it needs is inside `Study01/`.

**If you want to know what Study 01 concluded** without running it → [`Study01/claims/claim-wording.md`](./Study01/claims/claim-wording.md). It states nine claims: six things the study establishes and three it explicitly does not. The negative ones are part of the claim, not disclaimers appended to it.

**If you want the evidence behind a specific conclusion** → the four hypothesis judgments in [`Study01/claims/`](./Study01/claims/), each naming the artifacts it reads.

## What this repository is not

It is not the research repository. Kakuriyo, the private working repository, holds the full history: every non-accepted run, every review round, every gate decision, and the evidence trees themselves. Toyotamahime carries only what publication and reproduction need, extracted from a named Kakuriyo commit and recorded in each study's provenance file.

Nothing here is a report of results that were adjusted to look better. Study 01's headline hypothesis came out **Inconclusive**, and it is published that way.

## License

Apache License 2.0 — see [LICENSE](./LICENSE).
