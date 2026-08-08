#!/usr/bin/env python3
"""Portable generated-corpus benchmark for Swift and Rust ripgrep binaries."""

from __future__ import annotations

import argparse
import json
import math
import os
import platform
import statistics
import subprocess
import tempfile
import time
from pathlib import Path


def generate_corpus(root: Path, corpus_mib: int, tree_mib: int) -> tuple[Path, Path]:
    single = root / "single.txt"
    ordinary = (
        b"The quick brown fox crosses a deterministic benchmark haystack while Watson waits. "
        b"0123456789abcdefghijklmnopqrstuvwxyz\n"
    )
    match = b"A rare Sherlock Holmes clue appears beside WATSON and Baker Street.\n"
    target_bytes = corpus_mib * 1024 * 1024
    written = 0
    line_number = 0
    with single.open("wb", buffering=1024 * 1024) as output:
        while written < target_bytes:
            line = match if line_number % 4096 == 0 else ordinary
            output.write(line)
            written += len(line)
            line_number += 1

    tree = root / "tree"
    tree.mkdir()
    target_tree_bytes = tree_mib * 1024 * 1024
    file_count = max(64, min(512, tree_mib * 4))
    bytes_per_file = max(1, target_tree_bytes // file_count)
    for index in range(file_count):
        directory = tree / f"group-{index % 16:02d}"
        directory.mkdir(exist_ok=True)
        path = directory / f"fixture-{index:04d}.txt"
        written = 0
        line_number = 0
        with path.open("wb", buffering=256 * 1024) as output:
            while written < bytes_per_file:
                line = match if (index + line_number) % 1024 == 0 else ordinary
                output.write(line)
                written += len(line)
                line_number += 1
    return single, tree


def cases(single: Path, tree: Path) -> list[dict[str, object]]:
    base = ["--no-config", "--color", "never"]
    return [
        {"name": "literal", "args": base + ["Sherlock Holmes", str(single)]},
        {"name": "literal_no_mmap", "args": base + ["--no-mmap", "Sherlock Holmes", str(single)]},
        {"name": "literal_count", "args": base + ["-c", "Sherlock Holmes", str(single)]},
        {"name": "literal_case_insensitive_count", "args": base + ["-i", "-c", "sherlock holmes", str(single)]},
        {"name": "word_count", "args": base + ["-w", "-c", "Watson", str(single)]},
        {"name": "alternation_count", "args": base + ["-c", "Sherlock Holmes|Baker Street", str(single)]},
        {"name": "regex_count", "args": base + ["-c", r"[A-Z][a-z]+\s+Holmes", str(single)]},
        {"name": "no_match", "args": base + ["ZEBRA_NEVER_PRESENT_8675309", str(single)]},
        {"name": "recursive_literal_count", "args": base + ["--sort", "path", "-c", "Sherlock Holmes", str(tree)]},
        {"name": "recursive_files_with_matches", "args": base + ["--sort", "path", "-l", "Sherlock Holmes", str(tree)]},
        {"name": "recursive_no_match", "args": base + ["--sort", "path", "ZEBRA_NEVER_PRESENT_8675309", str(tree)]},
        {"name": "file_listing", "args": base + ["--sort", "path", "--files", str(tree)]},
    ]


def invoke(binary: Path, arguments: list[str], capture: bool) -> tuple[int, bytes, bytes, float]:
    start = time.perf_counter()
    # Pipes are intentional even for timed runs. Windows' NUL device is a
    # character device, which selects a different output path than a regular
    # redirected stream. Benchmark output is sparse, so pipe transfer is small.
    result = subprocess.run([str(binary), *arguments], capture_output=True, check=False)
    stdout, stderr = (result.stdout, result.stderr) if capture else (b"", b"")
    return result.returncode, stdout, stderr, time.perf_counter() - start


def ensure_parity(rg: Path, swift_rg: Path, benchmark_cases: list[dict[str, object]]) -> None:
    for case in benchmark_cases:
        arguments = case["args"]
        assert isinstance(arguments, list)
        rust = invoke(rg, arguments, capture=True)
        swift = invoke(swift_rg, arguments, capture=True)
        if rust[:3] != swift[:3]:
            name = case["name"]
            raise SystemExit(
                f"benchmark parity failed for {name}: "
                f"Rust status/stdout/stderr={rust[0]}/{len(rust[1])}/{len(rust[2])}, "
                f"Swift={swift[0]}/{len(swift[1])}/{len(swift[2])}"
            )


def benchmark_case(
    rg: Path,
    swift_rg: Path,
    case: dict[str, object],
    warmup: int,
    runs: int,
) -> dict[str, object]:
    arguments = case["args"]
    assert isinstance(arguments, list)
    for _ in range(warmup):
        invoke(rg, arguments, capture=False)
        invoke(swift_rg, arguments, capture=False)

    samples: dict[str, list[float]] = {"rust": [], "swift": []}
    for run in range(runs):
        order = (("rust", rg), ("swift", swift_rg))
        if run % 2:
            order = tuple(reversed(order))
        for contestant, binary in order:
            status, _, _, elapsed = invoke(binary, arguments, capture=False)
            if status not in {0, 1}:
                raise SystemExit(f"{contestant} failed with status {status} in {case['name']}")
            samples[contestant].append(elapsed)

    rust_median = statistics.median(samples["rust"])
    swift_median = statistics.median(samples["swift"])
    return {
        "name": case["name"],
        "arguments": arguments,
        "rust_median_s": rust_median,
        "swift_median_s": swift_median,
        "ratio": swift_median / rust_median,
        "rust_samples_s": samples["rust"],
        "swift_samples_s": samples["swift"],
    }


def markdown(results: list[dict[str, object]], metadata: dict[str, object]) -> str:
    ratios = [float(result["ratio"]) for result in results]
    geometric_mean = math.exp(sum(math.log(ratio) for ratio in ratios) / len(ratios))
    lines = [
        f"### Swift vs Rust ripgrep — {metadata['platform']}",
        "",
        f"Swift: `{metadata['swift_version']}`  ",
        f"Rust baseline: `{metadata['rust_version']}`  ",
        f"Corpus: {metadata['corpus_mib']} MiB single file + {metadata['tree_mib']} MiB tree  ",
        f"Geometric mean Swift/Rust ratio: **{geometric_mean:.3f}x**",
        "",
        "| Benchmark | Rust median | Swift median | Swift/Rust |",
        "|---|---:|---:|---:|",
    ]
    for result in results:
        lines.append(
            f"| `{result['name']}` | {float(result['rust_median_s']) * 1000:.2f} ms | "
            f"{float(result['swift_median_s']) * 1000:.2f} ms | "
            f"**{float(result['ratio']):.3f}x** |"
        )
    return "\n".join(lines) + "\n"


def version(binary: Path) -> str:
    result = subprocess.run([str(binary), "--version"], capture_output=True, text=True, check=True)
    return result.stdout.splitlines()[0]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rg", required=True, type=Path)
    parser.add_argument("--swift-rg", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--warmup", type=int, default=2)
    parser.add_argument("--runs", type=int, default=7)
    parser.add_argument("--corpus-mib", type=int, default=128)
    parser.add_argument("--tree-mib", type=int, default=32)
    parser.add_argument("--fail-above", type=float)
    args = parser.parse_args()

    rg = args.rg.resolve()
    swift_rg = args.swift_rg.resolve()
    if not rg.is_file() or not swift_rg.is_file():
        raise SystemExit(f"missing benchmark binary: rg={rg}, swift-rg={swift_rg}")
    args.out.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="swift-rg-ci-bench-") as temp_name:
        single, tree = generate_corpus(Path(temp_name), args.corpus_mib, args.tree_mib)
        benchmark_cases = cases(single, tree)
        print("Checking byte-for-byte benchmark parity...", flush=True)
        ensure_parity(rg, swift_rg, benchmark_cases)
        results = []
        for index, case in enumerate(benchmark_cases, 1):
            print(f"[{index}/{len(benchmark_cases)}] {case['name']}", flush=True)
            result = benchmark_case(rg, swift_rg, case, args.warmup, args.runs)
            results.append(result)
            print(f"  Swift/Rust {float(result['ratio']):.3f}x", flush=True)

    metadata = {
        "platform": f"{platform.system()} {platform.machine()}",
        "python": platform.python_version(),
        "rust_version": version(rg),
        "swift_version": version(swift_rg),
        "corpus_mib": args.corpus_mib,
        "tree_mib": args.tree_mib,
        "warmup": args.warmup,
        "runs": args.runs,
    }
    payload = {"metadata": metadata, "results": results}
    (args.out / "summary.json").write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    report = markdown(results, metadata)
    (args.out / "summary.md").write_text(report, encoding="utf-8")
    print("\n" + report)

    step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if step_summary:
        with Path(step_summary).open("a", encoding="utf-8") as output:
            output.write(report)

    if args.fail_above is not None:
        regressions = [result for result in results if float(result["ratio"]) > args.fail_above]
        if regressions:
            names = ", ".join(f"{r['name']} ({float(r['ratio']):.3f}x)" for r in regressions)
            raise SystemExit(f"performance threshold {args.fail_above:.3f}x exceeded: {names}")


if __name__ == "__main__":
    main()
