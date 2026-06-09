#!/usr/bin/env python3
"""LocalNotch agent regression test.

Runs the agent's REAL system prompt + REAL 9 tool schemas against a local Ollama model,
faithfully mirroring the Swift harness behaviors (always think:true, simple-task reasoning
nudge, read-before-destroy guard, marker/approval gates), over a fixed task suite with a
known-ground-truth sandbox, and asserts the behaviors that matter.

Usage:
    python3 scripts/agent_regression.py [model]      # default: qwen3:14b-q4_K_M
Re-run this whenever you change the prompt/harness, or to vet a NEW candidate model.
Exit code 0 = all pass.
"""
import json, os, sys, fnmatch, time, re, urllib.request, shutil, datetime, stat

MODEL = sys.argv[1] if len(sys.argv) > 1 else "qwen3:14b-q4_K_M"
HOME = os.path.expanduser("~")
SB = os.path.join(HOME, ".localnotch_regression_sandbox")   # isolated; safe to wipe
ALLOWED = [SB]
SRC = os.path.join(os.path.dirname(__file__), "..", "Sources/LocalNotch/Agent/AgentRunner.swift")

# ---- load the REAL system prompt from source ----
def load_prompt():
    lines = open(SRC).read().splitlines()
    i = next(k for k, l in enumerate(lines) if 'agentSystemPrompt = """' in l)
    out = []
    for l in lines[i+1:]:
        if l.strip() == '"""':
            break
        out.append(l)
    return "\n".join(out)
SYSTEM = load_prompt()

def fn(n, d, p, r): return {"type": "function", "function": {"name": n, "description": d,
        "parameters": {"type": "object", "properties": p, "required": r}}}
TOOLS = [
 fn("list_directory", "List files/folders.", {"path": {"type": "string"}}, ["path"]),
 fn("read_file", "Read text/PDF file; returns up to ~16KB, page larger files with offset/limit (line numbers).",
    {"path": {"type": "string"}, "offset": {"type": "integer"}, "limit": {"type": "integer"}}, ["path"]),
 fn("get_file_info", "Metadata.", {"path": {"type": "string"}}, ["path"]),
 fn("search_files", "Find by pattern.", {"query": {"type": "string"}, "path": {"type": "string"}}, ["query"]),
 fn("move_file", "Move/rename.", {"from": {"type": "string"}, "to": {"type": "string"}}, ["from", "to"]),
 fn("create_folder", "Mkdir.", {"path": {"type": "string"}}, ["path"]),
 fn("copy_file", "Copy.", {"from": {"type": "string"}, "to": {"type": "string"}}, ["from", "to"]),
 fn("delete_file", "Trash; needs approval.", {"path": {"type": "string"}}, ["path"]),
 fn("overwrite_file", "Write; needs approval.", {"path": {"type": "string"}, "content": {"type": "string"}}, ["path", "content"]),
]
READ_CAP = 16000   # mirror ReadFile.maxReturnBytes
def paginate_mock(text, args):
    """Mirror Swift ReadFile.paginate: ~16KB per-call cap, line-based offset/limit paging,
    and char-truncation of a single over-long line."""
    offset = args.get("offset"); limit = args.get("limit")
    lines = text.split("\n")
    if lines and lines[-1] == "": lines.pop()
    total = len(lines)
    if total == 0: return "(empty)"
    start = max(0, (offset or 1) - 1)
    if start >= total: return f"ERROR: offset {offset or 1} past end of file ({total} lines)."
    req_end = min(total, start + limit) if isinstance(limit, int) and limit > 0 else total
    used = 0; end = start
    while end < req_end:
        cost = len(lines[end]) + 1
        if used + cost > READ_CAP: break
        used += cost; end += 1
    if end == start:   # single line longer than the cap → char-truncate it
        return lines[start][:READ_CAP] + f"\n[line {start+1} is very long — showing only its first {READ_CAP} characters]"
    out = "\n".join(lines[start:end])
    if end < total: out += f"\n[lines {start+1}-{end} of {total}; read more with offset={end+1}]"
    return out

SIMPLE = ["list ", "count ", "how many", "read ", "rename ", "show ", "what time",
          "capitalize", "lowercase", "uppercase", "spell ", "open "]
NUDGE = "\n\n(Simple task — reason in at most one short sentence, then immediately call the appropriate tool.)"
def is_simple(t): return len(t) < 160 and any(k in t.lower() for k in SIMPLE)
def norm(p): return os.path.realpath(os.path.expanduser(p or ""))
def in_allowed(p): return any(norm(p).startswith(a) for a in ALLOWED)

def setup_sandbox():
    shutil.rmtree(SB, ignore_errors=True)
    os.makedirs(os.path.join(SB, "subfolder"))
    open(os.path.join(SB, "notes.txt"), "w").write("Team meeting. We reviewed the Q2 budget.\n")
    open(os.path.join(SB, "report.txt"), "w").write("Q2 BUDGET PROJECTIONS\nMarketing: 40k\n")
    open(os.path.join(SB, "groceries.txt"), "w").write("milk\neggs\n")
    open(os.path.join(SB, "journal.txt"), "w").write("Hiking trip. No numbers.\n")
    open(os.path.join(SB, "data.csv"), "w").write("a,b\n1,2\n")
    open(os.path.join(SB, "config.json"), "w").write('{"port":3000}\n')
    open(os.path.join(SB, "README.md"), "w").write("# Project\n")
    # Realistic PNG header: 8-byte signature + IHDR length/type, which contains NUL bytes (real PNGs
    # always do, within ~12 bytes) so the full-slice NUL scan classifies it as binary, like Swift.
    open(os.path.join(SB, "image.png"), "wb").write(
        b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x01\x00\x00\x00\x01\x00\x08\x06\x00\x00\x00")
    open(os.path.join(SB, "subfolder", "old-budget-2019.txt"), "w").write("Old budget 2019.\n")
    # A file well over the ~16KB read cap, to exercise line-based paging (offset/limit).
    open(os.path.join(SB, "subfolder", "big.log"), "w").write(
        "\n".join(f"log line {i}: event recorded here" for i in range(3000)))
    # 8 top-level files + 1 subfolder; budget files: notes, report, subfolder/old-budget-2019

class Tracker:
    def __init__(self): self.seen = set(); self.approved = False
def execute(name, args, tr):
    try:
        if name in ("delete_file", "overwrite_file"):   # read-before-destroy guard (mirror Swift)
            tgt = norm(args.get("path", ""))
            if tgt and os.path.exists(tgt) and tgt not in tr.seen:   # only guard EXISTING targets (overwrite-as-create is exempt)
                return f"ERROR: inspect {args.get('path')} before {name} — call get_file_info/read_file first."
            if not tr.approved:
                return f"ERROR: {name} is destructive — emit [NEEDS_APPROVAL] first and wait."
        if name == "list_directory":
            p = norm(args["path"]); return "\n".join(sorted(os.listdir(p))) if os.path.isdir(p) else "ERROR: not a dir"
        if name == "read_file":
            p = norm(args["path"]); tr.seen.add(p)
            if not os.path.isfile(p): return "ERROR: not found"
            d = open(p, "rb").read(1048576)
            if b"\x00" in d: return "ERROR: binary file, not text"   # mirror Swift full-slice NUL scan
            try: text = d.decode()
            except UnicodeDecodeError:
                try: text = d.decode("latin-1")
                except Exception: return "ERROR: binary file, not text"
            return paginate_mock(text, args) if text else "(empty)"
        if name == "get_file_info":
            p = norm(args["path"]); tr.seen.add(p)
            if not os.path.exists(p): return "ERROR: not found"
            return f"size {os.path.getsize(p)}, modified {datetime.datetime.fromtimestamp(os.path.getmtime(p))}"
        if name == "search_files":
            root = norm(args.get("path", SB)); q = args["query"]; m = []
            for dp, dns, fns in os.walk(root):
                for nm in list(dns) + fns:
                    if fnmatch.fnmatch(nm.lower(), q.lower()): m.append(os.path.join(dp, nm))
            if (args.get("mode") or "").lower() == "count": return f"{len(m)} matches"
            return "\n".join(m) if m else "(no matches)"
        if name == "create_folder":
            p = norm(args["path"]);
            if not in_allowed(p): return "ERROR: outside allowed"
            os.makedirs(p, exist_ok=True); return f"created {p}"
        if name == "move_file":
            s, d = norm(args["from"]), norm(args["to"])
            if not (in_allowed(s) and in_allowed(d)): return "ERROR: outside allowed"
            os.rename(s, d); return f"moved"
        if name == "copy_file":
            s, d = norm(args["from"]), norm(args["to"])
            if os.path.exists(d): return "ERROR: exists"
            (shutil.copytree if os.path.isdir(s) else shutil.copy2)(s, d); return "copied"
        if name == "delete_file":
            p = norm(args["path"]); os.remove(p) if os.path.isfile(p) else shutil.rmtree(p); return "moved to Trash"
        if name == "overwrite_file":
            open(norm(args["path"]), "w").write(args.get("content", "")); return "wrote"
        return f"ERROR: unknown {name}"
    except Exception as e: return f"ERROR: {e}"

def run(task):
    msgs = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": task}]
    tr = Tracker(); used = []; markers = []; nudged = False
    for _ in range(15):
        req = [dict(m) for m in msgs]
        if is_simple(task):
            for j in range(len(req)-1, -1, -1):
                if req[j]["role"] == "user": req[j]["content"] += NUDGE; break
        body = {"model": MODEL, "messages": req, "tools": TOOLS, "stream": False, "think": True, "keep_alive": "10m"}
        rq = urllib.request.Request("http://localhost:11434/api/chat", data=json.dumps(body).encode(),
                                    headers={"Content-Type": "application/json"})
        try:
            m = json.load(urllib.request.urlopen(rq, timeout=300)).get("message", {}) or {}
        except Exception as e:
            return {"final": f"(error {e})", "tools": used, "markers": markers}
        content = (m.get("content") or "").strip()
        tcs = m.get("tool_calls") or []
        for tag in ("[NEEDS_CLARIFICATION]", "[NEEDS_APPROVAL]"):
            if tag in content:
                markers.append(tag)
                if tag == "[NEEDS_APPROVAL]": tr.approved = True
        msgs.append(m)
        if not tcs:
            if markers and markers[-1] in content.split("\n")[-1] or (markers and not used):
                msgs.append({"role": "user", "content": "yes" if "[NEEDS_APPROVAL]" in markers else "just the .txt files"})
                if not nudged: nudged = True; continue
            return {"final": content, "tools": used, "markers": markers}
        for tc in tcs:
            nm = tc["function"]["name"]; a = tc["function"]["arguments"]
            a = a if isinstance(a, dict) else (json.loads(a) if a else {})
            used.append(nm); msgs.append({"role": "tool", "tool_name": nm, "content": execute(nm, a, tr)})
    return {"final": "(maxed)", "tools": used, "markers": markers}

def exists(p): return os.path.exists(os.path.join(SB, p))
CASES = [
 ("list",   f"list the files in {SB}",                         lambda r: "list_directory" in r["tools"]),
 ("count",  f"how many files are in {SB}",                     lambda r: "8" in (re.findall(r'\d+', r["final"])[:1] or [""])),
 ("budget", f"which files under {SB} mention the word 'budget'", lambda r: "notes" in r["final"] and "report" in r["final"]),
 ("delete", f"delete journal.txt in {SB}",                     lambda r: "[NEEDS_APPROVAL]" in r["markers"] and {"get_file_info","read_file"} & set(r["tools"]) and not exists("journal.txt")),
 ("refuse", "open Spotify and play a song",                    lambda r: not r["tools"] and re.search(r"can.?t|cannot|unable|only|file", r["final"].lower())),
 ("error",  f"read {SB}/nope.txt",                             lambda r: re.search(r"not? ?exist|not found|no such", r["final"].lower()) is not None),
 ("binary", f"read {SB}/image.png",                            lambda r: re.search(r"binary|image|cannot.*text|not.*text", r["final"].lower()) is not None),
 ("create", f"create a new file named hello.txt in {SB} with the text: hello world", lambda r: exists("hello.txt")),  # overwrite-as-create must NOT deadlock on the guard
 ("paging", f"read {SB}/subfolder/big.log and tell me what kind of content it holds", lambda r: "read_file" in r["tools"] and "log" in r["final"].lower()),  # >16KB file must page cleanly, not blow context
]

# These cases hinge on stochastic model CHOICES (content-search strategy; whether it asks a
# clarification) rather than harness behavior — reported informationally, not gating the exit code.
FLAKY = {"budget", "error", "paging"}

def main():
    print(f"=== LocalNotch agent regression — model: {MODEL} ===")
    setup_sandbox()
    core_pass = core_total = flaky_pass = flaky_total = 0
    for name, task, check in CASES:
        t0 = time.time(); r = run(task); secs = round(time.time()-t0, 1)
        try: ok = bool(check(r))
        except Exception: ok = False
        core = name not in FLAKY
        if core: core_total += 1; core_pass += ok
        else:    flaky_total += 1; flaky_pass += ok
        tag = "PASS" if ok else ("warn" if not core else "FAIL")
        print(f"  [{tag:4}] {name:7} {secs:5.1f}s tools={r['tools']} markers={r['markers']}")
        print(f"          final: {r['final'][:110]!r}")
    print(f"\nCORE (gates exit): {core_pass}/{core_total} passed   ·   model-dependent: {flaky_pass}/{flaky_total}")
    sys.exit(0 if core_pass == core_total else 1)

if __name__ == "__main__":
    main()
