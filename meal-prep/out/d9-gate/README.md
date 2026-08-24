# D9 (phase 3) gate evidence

Artifacts written by the phase-3 build. Regenerable; kept because a gate nobody can re-read is a
gate nobody can check.

- `parity-python.json`   - `hunt_lib.py --parity --json`, the Python half of the section 4.2 gate.
- `parity-javascript.json` - the return value of the zero-agent Workflow run of `hunt-lib-parity.js`,
  which runs the SAME `hunt-lib-vectors.json` against `hunt-lib.js` itself.
- `adapter-drill.json`   - the section 4.1a drill: every agent type dispatched once against scratch
  inputs through the headless adapter, its behavior diffed against a Workflow-dispatched twin, and
  the fixed per-dispatch overhead measured.
- `drain-drill/`         - the section 4.2 drain drill's run dir and its diff against the contract.
