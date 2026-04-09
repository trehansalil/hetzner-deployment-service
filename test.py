#!/usr/bin/env python3
"""
Two-phase stress test for pageindex-mcp.

Phase 1 (connection capacity): Ramps concurrent MCP sessions to find the
ceiling before degradation. Lightweight — no tool calls, no LLM cost.

Phase 2 (tool execution): At a fixed concurrency, sends a weighted mix of
real MCP tool calls (including GPT-backed search) to measure throughput
and find bottlenecks.

Usage:
    python3 test.py phase1                      # connection capacity only
    python3 test.py phase2 --concurrency 10     # tool load at fixed level
    python3 test.py both                        # phase1 then phase2 auto
    python3 test.py both --max-llm-calls 100    # raise GPT call cap
    python3 test.py phase1 --dry-run            # show plan without executing
"""

import argparse
import asyncio
import json
import random
import signal
import sys
import time
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Optional

import aiohttp

# ─── Configuration ───────────────────────────────────────────────────────────

BASE_URL = "https://pageindex.aiwithsalil.work"
MCP_PATH = "/mcp"
BEARER_TOKEN = "dev-api-key"

# Ramp settings
DEFAULT_START_CONCURRENCY = 2
DEFAULT_STEP = 2
DEFAULT_MAX_CONCURRENCY = 50
DEFAULT_STEP_DURATION = 10  # seconds per concurrency level
DEFAULT_WARMUP = 3  # seconds warmup at each new level before measuring
DEFAULT_REQUEST_DELAY = 0.1  # seconds between requests per worker (backpressure)

# Safety thresholds
DEFAULT_CPU_LIMIT = 200  # percent (e.g., 200 = 2 cores on a 4-core box)
DEFAULT_MEM_LIMIT = 90   # percent of total node memory
DEFAULT_ERROR_RATE_LIMIT = 20  # percent
DEFAULT_P99_LIMIT = 10.0  # seconds

# Phase 2 defaults
DEFAULT_DOC_ID = "585a254f"
DEFAULT_MAX_LLM_CALLS = 50
LLM_QUERIES = ["work experience", "education", "technical skills"]

# Tool mix weights (must sum to 1.0)
TOOL_WEIGHTS = [
    ("recent_documents", 0.2),
    ("get_document", 0.2),
    ("get_page_content", 0.2),
    ("get_document_structure", 0.2),
    ("find_relevant_documents", 0.2),
]

# Monitoring
METRIC_POLL_INTERVAL = 1  # seconds between kubectl top checks

# MCP protocol constants
MCP_ACCEPT = "application/json, text/event-stream"
MCP_CONTENT_TYPE = "application/json"
MCP_PROTOCOL_VERSION = "2025-03-26"


# ─── Data Classes ────────────────────────────────────────────────────────────

@dataclass
class StepResult:
    concurrency: int
    total_requests: int
    successful: int
    failed: int
    error_rate: float
    avg_latency: float
    p50_latency: float
    p95_latency: float
    p99_latency: float
    min_latency: float
    max_latency: float
    rps: float
    node_cpu: str
    node_cpu_pct: int
    node_mem_pct: int
    status_codes: dict
    duration: float


@dataclass
class ToolResult:
    """Latency tracking per tool type for Phase 2."""
    tool_name: str
    latencies: list[float] = field(default_factory=list)
    successes: int = 0
    failures: int = 0

    @property
    def total(self) -> int:
        return self.successes + self.failures

    @property
    def error_rate(self) -> float:
        return round(self.failures / self.total * 100, 1) if self.total else 0.0

    def percentile(self, p: float) -> float:
        if not self.latencies:
            return 0.0
        s = sorted(self.latencies)
        idx = int(len(s) * p / 100)
        return s[min(idx, len(s) - 1)]


@dataclass
class ServerMetrics:
    cpu_millicores: int = 0
    cpu_percent: int = 0
    mem_bytes: int = 0
    mem_percent: int = 0
    last_updated: float = 0.0


# ─── Metric Collector ────────────────────────────────────────────────────────

class MetricCollector:
    """Polls `kubectl top node` in background to get server metrics."""

    def __init__(self):
        self.metrics = ServerMetrics()
        self._running = False
        self._task: Optional[asyncio.Task] = None
        self.history: list[ServerMetrics] = []

    async def start(self):
        self._running = True
        self._task = asyncio.create_task(self._poll_loop())

    async def stop(self):
        self._running = False
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass

    async def _poll_loop(self):
        while self._running:
            try:
                await self._fetch_metrics()
            except Exception:
                pass
            await asyncio.sleep(METRIC_POLL_INTERVAL)

    async def _fetch_metrics(self):
        proc = await asyncio.create_subprocess_exec(
            "kubectl", "top", "node", "--no-headers",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, _ = await proc.communicate()
        if proc.returncode != 0:
            return

        line = stdout.decode().strip().split("\n")[0]
        parts = line.split()
        if len(parts) < 5:
            return

        # NAME  CPU(cores)  CPU%  MEMORY(bytes)  MEMORY%
        cpu_str = parts[1]  # e.g., "648m"
        cpu_pct_str = parts[2].rstrip("%")
        mem_pct_str = parts[4].rstrip("%")

        cpu_m = int(cpu_str.rstrip("m")) if cpu_str.endswith("m") else int(cpu_str) * 1000

        self.metrics = ServerMetrics(
            cpu_millicores=cpu_m,
            cpu_percent=int(cpu_pct_str),
            mem_percent=int(mem_pct_str),
            last_updated=time.time(),
        )
        self.history.append(ServerMetrics(
            cpu_millicores=cpu_m,
            cpu_percent=int(cpu_pct_str),
            mem_percent=int(mem_pct_str),
            last_updated=time.time(),
        ))

    def get_cpu_percent_absolute(self) -> int:
        return self.metrics.cpu_millicores // 10


# ─── MCP Session ─────────────────────────────────────────────────────────────

class MCPSession:
    """Manages a single MCP session: handshake, tool calls, session reuse."""

    def __init__(self, http_session: aiohttp.ClientSession, base_url: str):
        self.http = http_session
        self.url = f"{base_url}{MCP_PATH}"
        self.session_id: Optional[str] = None
        self.affinity_cookie: Optional[str] = None
        self._req_counter = 0

    def _next_id(self) -> str:
        self._req_counter += 1
        return str(self._req_counter)

    def _headers(self) -> dict:
        h = {
            "Authorization": f"Bearer {BEARER_TOKEN}",
            "Accept": MCP_ACCEPT,
            "Content-Type": MCP_CONTENT_TYPE,
        }
        if self.session_id:
            h["Mcp-Session-Id"] = self.session_id
        return h

    def _cookies(self) -> Optional[dict]:
        if self.affinity_cookie:
            return {"mcp_affinity": self.affinity_cookie}
        return None

    async def initialize(self) -> tuple[bool, float]:
        """Perform MCP initialize + initialized handshake.

        Returns (success, latency_seconds).
        """
        start = time.monotonic()
        try:
            # Step 1: initialize
            body = json.dumps({
                "jsonrpc": "2.0",
                "id": self._next_id(),
                "method": "initialize",
                "params": {
                    "protocolVersion": MCP_PROTOCOL_VERSION,
                    "capabilities": {},
                    "clientInfo": {"name": "stress-test", "version": "1.0.0"},
                },
            })
            async with self.http.post(
                self.url, headers=self._headers(), data=body, cookies=self._cookies()
            ) as resp:
                if resp.status != 200:
                    return False, time.monotonic() - start

                # Extract session ID from headers
                self.session_id = resp.headers.get("Mcp-Session-Id")

                # Extract affinity cookie
                set_cookie = resp.headers.get("Set-Cookie", "")
                if "mcp_affinity=" in set_cookie:
                    for part in set_cookie.split(";"):
                        part = part.strip()
                        if part.startswith("mcp_affinity="):
                            self.affinity_cookie = part.split("=", 1)[1]
                            break

                await resp.read()

            # Step 2: notifications/initialized
            notif = json.dumps({
                "jsonrpc": "2.0",
                "method": "notifications/initialized",
            })
            async with self.http.post(
                self.url, headers=self._headers(), data=notif, cookies=self._cookies()
            ) as resp:
                await resp.read()

            return True, time.monotonic() - start
        except Exception:
            return False, time.monotonic() - start

    async def call_tool(self, tool_name: str, arguments: dict) -> tuple[bool, float]:
        """Call an MCP tool. Returns (success, latency_seconds)."""
        start = time.monotonic()
        try:
            body = json.dumps({
                "jsonrpc": "2.0",
                "id": self._next_id(),
                "method": "tools/call",
                "params": {"name": tool_name, "arguments": arguments},
            })
            async with self.http.post(
                self.url, headers=self._headers(), data=body, cookies=self._cookies()
            ) as resp:
                await resp.read()
                success = resp.status == 200
                return success, time.monotonic() - start
        except Exception:
            return False, time.monotonic() - start


# ─── Base Stress Test ────────────────────────────────────────────────────────

class BaseStressTest:
    """Shared logic for both phases: metrics, thresholds, ramp loop, printing."""

    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.collector = MetricCollector()
        self.results: list[StepResult] = []
        self.stop_reason: Optional[str] = None
        self._stop = False

    def _check_thresholds(self) -> Optional[str]:
        cpu_abs = self.collector.get_cpu_percent_absolute()
        mem_pct = self.collector.metrics.mem_percent

        if cpu_abs >= self.args.cpu_limit:
            return f"CPU {cpu_abs}% >= limit {self.args.cpu_limit}%"
        if mem_pct >= self.args.mem_limit:
            return f"Memory {mem_pct}% >= limit {self.args.mem_limit}%"

        if self.results:
            last = self.results[-1]
            if last.error_rate >= self.args.error_rate_limit:
                return f"Error rate {last.error_rate}% >= limit {self.args.error_rate_limit}%"
            if last.p99_latency >= self.args.p99_limit:
                return f"P99 latency {last.p99_latency}s >= limit {self.args.p99_limit}s"

        return None

    async def _monitor(self, until: float):
        """Check thresholds every 500ms until the given monotonic time."""
        while time.monotonic() < until and not self._stop:
            breach = self._check_thresholds()
            if breach:
                self.stop_reason = breach
                self._stop = True
                return
            await asyncio.sleep(0.5)

    def _compute_step_result(
        self, concurrency: int, latencies: list[float],
        status_codes: dict[int, int], duration: float,
    ) -> Optional[StepResult]:
        if not latencies:
            return None

        latencies.sort()
        total = len(latencies)
        failed = sum(v for k, v in status_codes.items() if k == 0 or k >= 500)

        def pct(p: float) -> float:
            idx = int(len(latencies) * p / 100)
            return latencies[min(idx, len(latencies) - 1)]

        result = StepResult(
            concurrency=concurrency,
            total_requests=total,
            successful=total - failed,
            failed=failed,
            error_rate=round(failed / total * 100, 1) if total else 0,
            avg_latency=round(sum(latencies) / total, 3),
            p50_latency=round(pct(50), 3),
            p95_latency=round(pct(95), 3),
            p99_latency=round(pct(99), 3),
            min_latency=round(latencies[0], 3),
            max_latency=round(latencies[-1], 3),
            rps=round(total / duration, 1) if duration > 0 else 0,
            node_cpu=f"{self.collector.metrics.cpu_millicores}m",
            node_cpu_pct=self.collector.get_cpu_percent_absolute(),
            node_mem_pct=self.collector.metrics.mem_percent,
            status_codes=dict(status_codes),
            duration=round(duration, 1),
        )
        self.results.append(result)
        return result

    def print_step(self, result: StepResult):
        print(f"\n{'─' * 72}")
        print(f"  Concurrency: {result.concurrency}")
        print(f"  Requests:    {result.total_requests} "
              f"({result.successful} ok, {result.failed} failed, "
              f"{result.error_rate}% error rate)")
        print(f"  Throughput:  {result.rps} req/s")
        print(f"  Latency:     avg={result.avg_latency}s  "
              f"p50={result.p50_latency}s  p95={result.p95_latency}s  "
              f"p99={result.p99_latency}s")
        print(f"               min={result.min_latency}s  max={result.max_latency}s")
        print(f"  Status:      {result.status_codes}")
        print(f"  Node CPU:    {result.node_cpu} ({result.node_cpu_pct}% absolute)")
        print(f"  Node Memory: {result.node_mem_pct}%")
        print(f"{'─' * 72}")

    def print_summary(self, title: str = "STRESS TEST SUMMARY"):
        if not self.results:
            print("\nNo results collected.")
            return

        print(f"\n{'=' * 80}")
        print(f"  {title}")
        if self.stop_reason:
            print(f"  Stopped: {self.stop_reason}")
        print(f"{'=' * 80}")

        print(f"{'Conc':>5} {'Reqs':>6} {'OK':>6} {'Fail':>5} {'Err%':>5} "
              f"{'RPS':>7} {'Avg':>7} {'P50':>7} {'P95':>7} {'P99':>7} "
              f"{'CPU':>6} {'Mem%':>5}")
        print(f"{'-' * 80}")

        for r in self.results:
            print(f"{r.concurrency:>5} {r.total_requests:>6} {r.successful:>6} "
                  f"{r.failed:>5} {r.error_rate:>4.1f}% {r.rps:>7.1f} "
                  f"{r.avg_latency:>6.3f}s {r.p50_latency:>6.3f}s "
                  f"{r.p95_latency:>6.3f}s {r.p99_latency:>6.3f}s "
                  f"{r.node_cpu:>6} {r.node_mem_pct:>4}%")

        best = self.results[0]
        for r in self.results:
            if r.error_rate < 10 and r.p99_latency < self.args.p99_limit:
                best = r

        print(f"\n  Recommended max concurrency: {best.concurrency}")
        print(f"  At that level: {best.rps} req/s, "
              f"p99={best.p99_latency}s, "
              f"error_rate={best.error_rate}%, "
              f"CPU={best.node_cpu}")
        print(f"{'=' * 80}")

    async def _start_metrics(self):
        await self.collector.start()
        print("Waiting for initial metrics...", end="", flush=True)
        for _ in range(10):
            if self.collector.metrics.last_updated > 0:
                break
            await asyncio.sleep(1)
        print(f" CPU={self.collector.metrics.cpu_millicores}m, "
              f"Mem={self.collector.metrics.mem_percent}%")

    async def _preflight_check(self) -> bool:
        """Returns True if OK to proceed, False if threshold already breached."""
        breach = self._check_thresholds()
        if breach:
            print(f"\nABORT: Server already at/above threshold: {breach}")
            await self.collector.stop()
            return False
        return True

    def _handle_sigint(self):
        print("\n\nCtrl+C received — stopping gracefully...")
        self.stop_reason = "User interrupted (Ctrl+C)"
        self._stop = True

    def get_recommended_concurrency(self) -> int:
        """Return the best concurrency found, for passing to Phase 2."""
        best = self.results[0] if self.results else None
        if not best:
            return self.args.start
        for r in self.results:
            if r.error_rate < 10 and r.p99_latency < self.args.p99_limit:
                best = r
        return best.concurrency


# ─── Phase 1: Connection Capacity ────────────────────────────────────────────

class Phase1ConnectionTest(BaseStressTest):
    """Ramp concurrent MCP sessions to find the connection ceiling."""

    async def run_step(
        self, http_session: aiohttp.ClientSession, concurrency: int,
    ) -> Optional[StepResult]:
        latencies: list[float] = []
        status_codes: dict[int, int] = defaultdict(int)
        step_start = time.monotonic()

        # Warmup
        print(f"  Warming up ({self.args.warmup}s)...", end="", flush=True)
        warmup_end = step_start + self.args.warmup

        async def warmup_worker():
            while time.monotonic() < warmup_end and not self._stop:
                sess = MCPSession(http_session, BASE_URL)
                ok, _ = await sess.initialize()
                if self.args.request_delay > 0:
                    await asyncio.sleep(self.args.request_delay)

        await asyncio.gather(
            *[warmup_worker() for _ in range(concurrency)],
            self._monitor(warmup_end),
        )
        print(" done")

        if self._stop:
            return None

        # Measurement
        print(f"  Measuring ({self.args.step_duration}s)...", end="", flush=True)
        measure_end = time.monotonic() + self.args.step_duration

        async def measure_worker():
            while time.monotonic() < measure_end and not self._stop:
                sess = MCPSession(http_session, BASE_URL)
                ok, lat = await sess.initialize()
                latencies.append(lat)
                status_codes[200 if ok else 0] += 1
                if self.args.request_delay > 0:
                    await asyncio.sleep(self.args.request_delay)

        await asyncio.gather(
            *[measure_worker() for _ in range(concurrency)],
            self._monitor(measure_end),
        )
        print(" done")

        duration = time.monotonic() - step_start - self.args.warmup
        return self._compute_step_result(concurrency, latencies, status_codes, duration)

    async def run(self) -> int:
        """Run Phase 1. Returns recommended concurrency."""
        args = self.args
        print(f"Phase 1: Connection Capacity Test")
        print(f"  Target:          {BASE_URL}{MCP_PATH}")
        print(f"  Concurrency:     {args.start} -> {args.max_concurrency} (step {args.step})")
        print(f"  Step duration:   {args.step_duration}s (+ {args.warmup}s warmup)")
        print(f"  CPU limit:       {args.cpu_limit}%")
        print(f"  Memory limit:    {args.mem_limit}%")
        print()

        if args.dry_run:
            steps = list(range(args.start, args.max_concurrency + 1, args.step))
            print(f"  Would test {len(steps)} levels: {steps}")
            print(f"  Estimated time: {len(steps) * (args.step_duration + args.warmup + 5)}s")
            return args.start

        loop = asyncio.get_event_loop()
        loop.add_signal_handler(signal.SIGINT, self._handle_sigint)

        await self._start_metrics()
        if not await self._preflight_check():
            return args.start

        connector = aiohttp.TCPConnector(
            limit=args.max_concurrency + 10,
            ttl_dns_cache=300,
            force_close=True,
        )
        timeout = aiohttp.ClientTimeout(total=60)

        async with aiohttp.ClientSession(
            connector=connector, timeout=timeout
        ) as http_session:
            concurrency = args.start
            while concurrency <= args.max_concurrency and not self._stop:
                print(f"\n>>> Level {concurrency} concurrent sessions")
                result = await self.run_step(http_session, concurrency)

                if result:
                    self.print_step(result)

                breach = self._check_thresholds()
                if breach:
                    self.stop_reason = breach
                    self._stop = True
                    print(f"\n  THRESHOLD BREACHED: {breach}")
                    print("  Stopping to protect server.")
                    break

                concurrency += args.step

                if not self._stop and concurrency <= args.max_concurrency:
                    print(f"  Cooldown 5s before next level...", flush=True)
                    await asyncio.sleep(5)

        await self.collector.stop()

        if not self.stop_reason and not self._stop:
            self.stop_reason = f"Reached max concurrency ({args.max_concurrency})"

        self.print_summary("PHASE 1: CONNECTION CAPACITY SUMMARY")
        recommended = self.get_recommended_concurrency()
        print(f"\n  Use --concurrency {recommended} for Phase 2\n")
        return recommended


# ─── Phase 2: Tool Execution Load ────────────────────────────────────────────

class Phase2ToolTest(BaseStressTest):
    """Fixed concurrency, weighted tool call mix, per-tool breakdown."""

    def __init__(self, args: argparse.Namespace):
        super().__init__(args)
        self.tool_results: dict[str, ToolResult] = {
            name: ToolResult(tool_name=name) for name, _ in TOOL_WEIGHTS
        }
        self._llm_call_count = 0
        self._llm_lock = asyncio.Lock()

    def _pick_tool(self) -> tuple[str, dict]:
        """Weighted random tool selection. Returns (tool_name, arguments)."""
        r = random.random()
        cumulative = 0.0
        chosen = TOOL_WEIGHTS[-1][0]
        for name, weight in TOOL_WEIGHTS:
            cumulative += weight
            if r <= cumulative:
                chosen = name
                break

        doc_id = self.args.doc_id

        if chosen == "recent_documents":
            return chosen, {"page": 1, "page_size": 10}
        elif chosen == "get_document":
            return chosen, {"doc_id": doc_id}
        elif chosen == "get_page_content":
            return chosen, {"doc_id": doc_id, "pages": "1"}
        elif chosen == "get_document_structure":
            return chosen, {"doc_id": doc_id}
        elif chosen == "find_relevant_documents":
            query = random.choice(LLM_QUERIES)
            return chosen, {"query": query}
        return chosen, {}

    async def _maybe_call_tool(
        self, mcp: MCPSession,
    ) -> Optional[tuple[str, bool, float]]:
        """Pick and call a tool, respecting LLM call cap.

        Returns (tool_name, success, latency) or None if LLM cap reached
        and an LLM tool was picked (retries with a non-LLM tool).
        """
        tool_name, arguments = self._pick_tool()

        if tool_name == "find_relevant_documents":
            async with self._llm_lock:
                if self._llm_call_count >= self.args.max_llm_calls:
                    # Cap reached — substitute a lightweight tool
                    tool_name = "recent_documents"
                    arguments = {"page": 1, "page_size": 10}
                else:
                    self._llm_call_count += 1

        ok, lat = await mcp.call_tool(tool_name, arguments)
        return tool_name, ok, lat

    async def run_step(
        self,
        sessions: list[MCPSession],
        concurrency: int,
    ) -> Optional[StepResult]:
        latencies: list[float] = []
        status_codes: dict[int, int] = defaultdict(int)
        step_start = time.monotonic()

        # Warmup
        print(f"  Warming up ({self.args.warmup}s)...", end="", flush=True)
        warmup_end = step_start + self.args.warmup

        async def warmup_worker(mcp: MCPSession):
            while time.monotonic() < warmup_end and not self._stop:
                await self._maybe_call_tool(mcp)
                if self.args.request_delay > 0:
                    await asyncio.sleep(self.args.request_delay)

        await asyncio.gather(
            *[warmup_worker(sessions[i % len(sessions)]) for i in range(concurrency)],
            self._monitor(warmup_end),
        )
        print(" done")

        if self._stop:
            return None

        # Measurement
        print(f"  Measuring ({self.args.step_duration}s)...", end="", flush=True)
        measure_end = time.monotonic() + self.args.step_duration

        async def measure_worker(mcp: MCPSession):
            while time.monotonic() < measure_end and not self._stop:
                result = await self._maybe_call_tool(mcp)
                if result:
                    tool_name, ok, lat = result
                    latencies.append(lat)
                    status_codes[200 if ok else 0] += 1
                    tr = self.tool_results[tool_name]
                    tr.latencies.append(lat)
                    if ok:
                        tr.successes += 1
                    else:
                        tr.failures += 1
                if self.args.request_delay > 0:
                    await asyncio.sleep(self.args.request_delay)

        await asyncio.gather(
            *[measure_worker(sessions[i % len(sessions)]) for i in range(concurrency)],
            self._monitor(measure_end),
        )
        print(" done")

        duration = time.monotonic() - step_start - self.args.warmup
        return self._compute_step_result(concurrency, latencies, status_codes, duration)

    def print_tool_breakdown(self):
        print(f"\n{'=' * 80}")
        print("  PER-TOOL BREAKDOWN")
        print(f"{'=' * 80}")
        print(f"{'Tool':<28} {'Reqs':>5} {'Avg':>7} {'P50':>7} "
              f"{'P95':>7} {'P99':>7} {'Err%':>6}")
        print(f"{'-' * 80}")

        for name, _ in TOOL_WEIGHTS:
            tr = self.tool_results[name]
            if tr.total == 0:
                continue
            avg = round(sum(tr.latencies) / len(tr.latencies), 3) if tr.latencies else 0
            print(f"{name:<28} {tr.total:>5} {avg:>6.3f}s "
                  f"{tr.percentile(50):>6.3f}s {tr.percentile(95):>6.3f}s "
                  f"{tr.percentile(99):>6.3f}s {tr.error_rate:>5.1f}%")

        print(f"\n  LLM calls used: {self._llm_call_count}/{self.args.max_llm_calls}")
        print(f"{'=' * 80}")

    async def run(self):
        args = self.args
        concurrency = args.concurrency

        print(f"Phase 2: Tool Execution Load Test")
        print(f"  Target:          {BASE_URL}{MCP_PATH}")
        print(f"  Concurrency:     {concurrency} (fixed)")
        print(f"  Step duration:   {args.step_duration}s (+ {args.warmup}s warmup)")
        print(f"  Doc ID:          {args.doc_id}")
        print(f"  Max LLM calls:   {args.max_llm_calls}")
        print(f"  CPU limit:       {args.cpu_limit}%")
        print(f"  Memory limit:    {args.mem_limit}%")
        print()

        if args.dry_run:
            print(f"  Would run at concurrency {concurrency}")
            print(f"  Tool mix: {', '.join(f'{n} ({w:.0%})' for n, w in TOOL_WEIGHTS)}")
            return

        loop = asyncio.get_event_loop()
        loop.add_signal_handler(signal.SIGINT, self._handle_sigint)

        await self._start_metrics()
        if not await self._preflight_check():
            return

        connector = aiohttp.TCPConnector(
            limit=concurrency + 10,
            ttl_dns_cache=300,
            force_close=True,
        )
        timeout = aiohttp.ClientTimeout(total=120)

        async with aiohttp.ClientSession(
            connector=connector, timeout=timeout
        ) as http_session:
            # Establish MCP sessions
            print(f"Establishing {concurrency} MCP sessions...", end="", flush=True)
            sessions: list[MCPSession] = []
            for _ in range(concurrency):
                if self._stop:
                    break
                sess = MCPSession(http_session, BASE_URL)
                ok, _ = await sess.initialize()
                if ok:
                    sessions.append(sess)
                else:
                    print(f"\n  WARNING: session init failed, continuing with {len(sessions)}")
            print(f" {len(sessions)} ready")

            if not sessions:
                print("ABORT: Could not establish any MCP sessions.")
                await self.collector.stop()
                return

            # Single step at fixed concurrency
            print(f"\n>>> Running at concurrency {concurrency}")
            result = await self.run_step(sessions, concurrency)
            if result:
                self.print_step(result)

        await self.collector.stop()

        if not self.stop_reason and not self._stop:
            self.stop_reason = "Completed"

        self.print_summary("PHASE 2: TOOL EXECUTION SUMMARY")
        self.print_tool_breakdown()


# ─── CLI ─────────────────────────────────────────────────────────────────────

def add_shared_args(p: argparse.ArgumentParser):
    """Add arguments shared by both phases."""
    p.add_argument("--start", type=int, default=DEFAULT_START_CONCURRENCY,
                   help=f"Starting concurrency (default: {DEFAULT_START_CONCURRENCY})")
    p.add_argument("--step", type=int, default=DEFAULT_STEP,
                   help=f"Concurrency step size (default: {DEFAULT_STEP})")
    p.add_argument("--max-concurrency", type=int, default=DEFAULT_MAX_CONCURRENCY,
                   help=f"Max concurrency ceiling (default: {DEFAULT_MAX_CONCURRENCY})")
    p.add_argument("--step-duration", type=int, default=DEFAULT_STEP_DURATION,
                   help=f"Seconds to measure at each level (default: {DEFAULT_STEP_DURATION})")
    p.add_argument("--warmup", type=int, default=DEFAULT_WARMUP,
                   help=f"Warmup seconds per step (default: {DEFAULT_WARMUP})")
    p.add_argument("--cpu-limit", type=int, default=DEFAULT_CPU_LIMIT,
                   help=f"Absolute CPU%% threshold (default: {DEFAULT_CPU_LIMIT})")
    p.add_argument("--mem-limit", type=int, default=DEFAULT_MEM_LIMIT,
                   help=f"Memory%% threshold (default: {DEFAULT_MEM_LIMIT})")
    p.add_argument("--error-rate-limit", type=int, default=DEFAULT_ERROR_RATE_LIMIT,
                   help=f"Error rate%% threshold (default: {DEFAULT_ERROR_RATE_LIMIT})")
    p.add_argument("--p99-limit", type=float, default=DEFAULT_P99_LIMIT,
                   help=f"P99 latency threshold in seconds (default: {DEFAULT_P99_LIMIT})")
    p.add_argument("--request-delay", type=float, default=DEFAULT_REQUEST_DELAY,
                   help=f"Delay between requests per worker (default: {DEFAULT_REQUEST_DELAY})")
    p.add_argument("--dry-run", action="store_true",
                   help="Show test plan without executing")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Two-phase MCP stress test with auto-stop on server overload"
    )
    sub = p.add_subparsers(dest="phase", required=True)

    # phase1
    p1 = sub.add_parser("phase1", help="Connection capacity test")
    add_shared_args(p1)

    # phase2
    p2 = sub.add_parser("phase2", help="Tool execution load test")
    add_shared_args(p2)
    p2.add_argument("--concurrency", type=int, default=10,
                    help="Fixed session count (default: 10)")
    p2.add_argument("--doc-id", default=DEFAULT_DOC_ID,
                    help=f"Document ID for tool calls (default: {DEFAULT_DOC_ID})")
    p2.add_argument("--max-llm-calls", type=int, default=DEFAULT_MAX_LLM_CALLS,
                    help=f"Max find_relevant_documents calls (default: {DEFAULT_MAX_LLM_CALLS})")

    # both
    pb = sub.add_parser("both", help="Phase 1 then Phase 2")
    add_shared_args(pb)
    pb.add_argument("--concurrency", type=int, default=None,
                    help="Override Phase 2 concurrency (default: use Phase 1 result)")
    pb.add_argument("--doc-id", default=DEFAULT_DOC_ID,
                    help=f"Document ID for tool calls (default: {DEFAULT_DOC_ID})")
    pb.add_argument("--max-llm-calls", type=int, default=DEFAULT_MAX_LLM_CALLS,
                    help=f"Max find_relevant_documents calls (default: {DEFAULT_MAX_LLM_CALLS})")

    return p.parse_args()


async def main():
    args = parse_args()

    if args.phase == "phase1":
        test = Phase1ConnectionTest(args)
        await test.run()

    elif args.phase == "phase2":
        if not hasattr(args, "concurrency") or args.concurrency is None:
            args.concurrency = 10
        test = Phase2ToolTest(args)
        await test.run()

    elif args.phase == "both":
        # Phase 1
        p1 = Phase1ConnectionTest(args)
        recommended = await p1.run()

        if p1._stop and p1.stop_reason and "User interrupted" in p1.stop_reason:
            return

        # Phase 2 — use Phase 1 result unless overridden
        if args.concurrency is None:
            args.concurrency = recommended
        print(f"\n{'#' * 80}")
        print(f"  Proceeding to Phase 2 with concurrency={args.concurrency}")
        print(f"{'#' * 80}\n")

        # Reset stop state for Phase 2
        p2 = Phase2ToolTest(args)
        await p2.run()


if __name__ == "__main__":
    asyncio.run(main())
