- **Added the `INTERVIEW_PROBE_MODEL` setting** (`workflows/scripts/build/build.config.sh`,
  registered in `workflows/scripts/config/setting-registry.tsv`), naming the
  model tier for `/interview`'s fact-probe subagent — a `: "${VAR:=}"` seam
  defaulting to the same mechanical tier as `PIPELINE_DRIVE_MODEL`, so a
  personal or per-host override never touches the tracked file (#1938).
