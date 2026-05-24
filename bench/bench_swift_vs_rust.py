#!/usr/bin/env python3
"""
Run the upstream ripgrep benchsuite scenarios with two contestants:
the installed Rust `rg` and the Swift port at `.build/release/ripgrep`.

We exec the upstream benchsuite source so its `bench_*` functions and
`Command`/`Benchmark` types are loaded into a private namespace. Then we
override `Command` to intercept every `rg` invocation, build a paired
`swift-ripgrep` command with the same args, and run hyperfine on the pair.
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


def load_benchsuite(path):
    src = Path(path).read_text()
    ns = {"__name__": "_loaded_benchsuite", "__file__": str(path)}
    code = compile(src, str(path), "exec")
    exec(code, ns)
    return ns


def collect_benchmarks(ns, suite_dir, rg_path, swift_rg_path):
    real_Command = ns["Command"]
    captured = []
    current_bench = {"name": ""}

    class CaptureCommand(real_Command):
        def __init__(self, name, args, env=None, cwd=None):
            super().__init__(name, args, env=env, cwd=cwd)
            if not args or not isinstance(args, list):
                return
            if args[0] != "rg":
                return
            swift_args = [swift_rg_path] + list(args[1:])
            rg_args = [rg_path] + list(args[1:])
            captured.append({
                "bench": current_bench["name"],
                "label": name,
                "rg_args": rg_args,
                "swift_args": swift_args,
                "cwd": cwd,
                "env": env or {},
            })

    ns["Command"] = CaptureCommand
    bench_funcs = sorted(k for k in ns if k.startswith("bench_"))
    for func_name in bench_funcs:
        current_bench["name"] = func_name[len("bench_"):]
        try:
            ns[func_name](suite_dir)
        except Exception as exc:
            print(f"  [skip] {func_name}: {exc}", file=sys.stderr)
            continue
    return captured


def quote(arg):
    if not arg:
        return "''"
    if any(c in arg for c in [" ", "'", '"', "\\", "$", "`", "(", ")", "[", "]", "*", "?", "|", "&", ";"]):
        return "'" + arg.replace("'", "'\"'\"'") + "'"
    return arg


def run_hyperfine(case, warmup, runs, json_dir):
    safe_label = case['label'].replace(' ', '_').replace('(', '').replace(')', '')
    json_path = Path(json_dir) / f"{case['bench']}--{safe_label}.json"
    rg_cmd = " ".join(quote(a) for a in case["rg_args"])
    swift_cmd = " ".join(quote(a) for a in case["swift_args"])
    args = [
        "hyperfine",
        "--style", "none",
        "--warmup", str(warmup),
        "--runs", str(runs),
        "--export-json", str(json_path),
        "-n", f"rg ({case['label']})",
        rg_cmd,
        "-n", f"swift-ripgrep ({case['label']})",
        swift_cmd,
    ]
    env = {**os.environ, **(case["env"] or {})}
    result = subprocess.run(args, cwd=case["cwd"], env=env, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"  [hyperfine failed: {case['bench']} / {case['label']}]")
        print(result.stderr.strip(), file=sys.stderr)
        return None
    if not json_path.exists():
        return None
    return json.loads(json_path.read_text())


def fmt_ms(seconds):
    ms = seconds * 1000
    if ms >= 1000:
        return f"{ms/1000:6.3f} s"
    return f"{ms:7.2f} ms"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--suite-dir", required=True)
    ap.add_argument("--rg", required=True)
    ap.add_argument("--swift-rg", required=True)
    ap.add_argument("--benchsuite", default="/tmp/swift-rg-bench/benchsuite.py")
    ap.add_argument("--out", required=True)
    ap.add_argument("--warmup", type=int, default=2)
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--filter", default=None)
    args = ap.parse_args()

    if not Path(args.rg).is_file():
        sys.exit(f"rg not found at {args.rg}")
    if not Path(args.swift_rg).is_file():
        sys.exit(f"swift-rg not found at {args.swift_rg}")

    out_dir = Path(args.out)
    json_dir = out_dir / "hyperfine"
    json_dir.mkdir(parents=True, exist_ok=True)

    ns = load_benchsuite(args.benchsuite)
    cases = collect_benchmarks(ns, args.suite_dir, args.rg, args.swift_rg)
    if args.filter:
        wanted = set(args.filter.split(","))
        cases = [c for c in cases if c["bench"] in wanted]
    print(f"Collected {len(cases)} bench/label pairs to run.")

    results = []
    for i, case in enumerate(cases, 1):
        label = f"{case['bench']} / {case['label']}"
        print(f"[{i}/{len(cases)}] {label}", flush=True)
        data = run_hyperfine(case, args.warmup, args.runs, json_dir)
        if data is None:
            continue
        rg_res, swift_res = data["results"]
        rg_med = rg_res["median"]
        sw_med = swift_res["median"]
        ratio = sw_med / rg_med if rg_med > 0 else float("inf")
        results.append({
            "bench": case["bench"],
            "label": case["label"],
            "rg_median_s": rg_med,
            "rg_stddev_s": rg_res.get("stddev", 0.0),
            "swift_median_s": sw_med,
            "swift_stddev_s": swift_res.get("stddev", 0.0),
            "ratio": ratio,
        })
        print(f"   rg     median {fmt_ms(rg_med)}   |   swift-rg median {fmt_ms(sw_med)}   |   swift/rg = {ratio:5.2f}x", flush=True)

    summary_path = out_dir / "summary.json"
    summary_path.write_text(json.dumps(results, indent=2))

    md_lines = ["| Benchmark | Label | rg median | swift-rg median | swift/rg |",
                "|---|---|---:|---:|---:|"]
    for r in results:
        md_lines.append(
            f"| `{r['bench']}` | {r['label']} | {fmt_ms(r['rg_median_s'])} | "
            f"{fmt_ms(r['swift_median_s'])} | **{r['ratio']:.2f}x** |"
        )
    md_path = out_dir / "summary.md"
    md_path.write_text("\n".join(md_lines) + "\n")
    print(f"\nSummary table written to {md_path}")
    print(f"Raw hyperfine JSON in {json_dir}")
    print("\n" + "\n".join(md_lines))


if __name__ == "__main__":
    main()
