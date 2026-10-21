"""Select upstream tests without changing their setup, cleanup, or expectations."""
import ast
import configparser
import json
from pathlib import Path
import sys

scope, target = sys.argv[1:]
if scope not in {"full", "focus", "tail", "unresolved", "after-fault", "probe", "resume"}:
    raise SystemExit("Invalid test scope")

focus = {
    "device_access": {"device_access_create", "device_access_attach",
                      "device_access_add", "device_access_import"},
    "fault": {"auto_online_001_pos", "suspend_on_probe_errors",
              "suspend_resume_single", "zpool_status_-s"},
    "replacement": {"attach_resilver_sit_out"},
    "reservation": {"reservation_009_pos", "reservation_010_pos",
                    "reservation_012_pos", "reservation_016_pos"},
    "slog": {"slog_replay_fs_001", "slog_replay_fs_002"},
}
stall_tail = {"suspend_on_probe_errors", "suspend_resume_single", "zpool_status_-s"}
output = configparser.RawConfigParser()
selected = []
for name in ("common.run", "linux.run"):
    source = configparser.RawConfigParser()
    source.read(Path("/usr/share/zfs/runfiles") / name)
    if not source.sections():
        raise SystemExit(f"Missing upstream runfile: {name}")
    output["DEFAULT"].update(source.defaults())
    for section in source.sections():
        directory = section.split(":", 1)[0]
        group = directory.removeprefix("tests/functional/")
        tests = ast.literal_eval(source.get(section, "tests", fallback="[]"))
        if scope in {"probe", "resume"}:
            wanted = "suspend_on_probe_errors" if scope == "probe" else "suspend_resume_single"
            tests = [test for test in tests if group == "fault" and test == wanted]
        elif scope in {"focus", "unresolved"}:
            tests = [test for test in tests if test in focus.get(group, set())]
            if scope == "unresolved":
                tests = [test for test in tests if test not in
                         {"suspend_on_probe_errors", "suspend_resume_single"}]
        elif scope == "after-fault":
            if directory <= "tests/functional/fault":
                tests = []
        elif scope == "tail":
            # The original LTS run completed scrub_after_resilver in fault,
            # then stopped. Execution is ordered by directory, not runfile order.
            if directory == "tests/functional/fault":
                tests = [test for test in tests if test in stall_tail]
            elif directory < "tests/functional/fault":
                tests = []
        if not tests:
            continue
        output[section] = dict(source.items(section, raw=True))
        output[section]["tests"] = repr(tests)
        selected.extend(f"{section}/{test}" for test in tests)
if not selected:
    raise SystemExit("Selection contains no tests")
with open(target, "w") as stream:
    output.write(stream)
Path(target + ".json").write_text(json.dumps({"scope": scope, "tests": selected}, indent=2) + "\n")
print(f"Selected {len(selected)} upstream test cases: {scope}")
