#!/usr/bin/env python3
"""Unexecuted source candidate; NOT runtime authorization.

The independently reviewed workflow pins these helper bytes before starting this
supervisor with a clean environment and privilege already established. Only the
fixed --entered helper mutates a retained, validated network namespace. SDK code
is executed exclusively via Docker as 10001:10001, never in that helper.
"""

import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import select
import selectors
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tarfile
import time

BASE = "ba6f71f80f2174f342d6815f8735b1e6510f4499"
INDEX = "sha256:43ac6c60b8f89723f746e8a92ce91abd5017e627ce1ddfe4238355d3a30b772c"
CHILD = "sha256:25330af3531fb5e23318554a0aa911125b6e91b1b777edf7655501d207c067a2"
CONFIG = "sha256:88f8ba583a884279252779bbe221bf1ff2c61cf236cc973f8ca97676ae6d07f0"
IMAGE = "docker.io/library/node@" + CHILD
DOCKER = "/usr/bin/docker"
IP = "/usr/sbin/ip"
NSENTER = "/usr/bin/nsenter"
PYTHON = "/usr/bin/python3"
NODE = "/usr/local/bin/node"
HELPER = "/harness/telemetry-web-hosted-d1.cjs"
ENV = {"PATH": "/usr/local/bin:/usr/bin:/bin", "LANG": "C.UTF-8"}
INNER = ["/usr/bin/env", "-i", "PATH=/usr/local/bin:/usr/bin:/bin",
         "CI=true", "NODE_ENV=test", "TMPDIR=/tmp"]
OUTPUT_LIMIT = 2 * 1024 * 1024
REPORT_LIMIT = 1024 * 1024
BUDGETS = {"admission": 240, "acquisition": 240, "inventory": 60,
           "d1": 120, "baseline": 120, "readback": 60, "cleanup": 30}
WRAPPER = ("import sdkConfig from '/work/sdk/vitest.config.ts';\n\n"
           "export default {\n  ...sdkConfig,\n  root: '/work/sdk',\n"
           "  cacheDir: '/cache/vite',\n};\n")
SOURCE = {
    ".gitignore": "55e6f37d2bf1bc95aec20851af706b34aaec5bc5b06da984abefbead39d4d1c4",
    ".npmignore": "847d0ee4b15e4864851e97d52773d1e7d9ca830295d75bc61ad7587c46c9e12c",
    "README.md": "888132122dd4cde352fdc1a0ec37c19beba2abbe2d703c8c3c8f9f5ada802408",
    "package-lock.json": "3c7af4367ad5ffafa238be0eec9286b7674b244b7b1da238148d987ade32927d",
    "package.json": "809f5ee499d876733b855277ac09f08b59f2aed6a3cc5e3d48eaf805c80f2e48",
    "vitest.config.ts": "29659ed4097030124ab5fa732342429899f3e5e30272440f48d781ea56e9c306",
    "tsconfig.json": "598168b76b831084784f69e6496373e7a9f6cc9e6a06883e33d769223d04fb39",
    "tsup.config.ts": "9bd6653a0699fda29ee6ebd6b7e0280da5535dacf3b62e17f13e85c4c9b75409",
    "src/client.ts": "24aeb79df51f0079034eda05086a1462ab2b9698e7c0f6e4b734162ab7d020ad",
    "src/index.ts": "befc0dd1e5281476c8b045cedf8ecc392fd637d397c8df45ed78bd351b17f1f7",
    "src/queue.ts": "6f91de0d06edcea38595e4644c034e8a88925040fecd58bf89763b1955ef8d5c",
    "src/shipper.ts": "25b6c03f82e4f647ef7ff3e4535cc90e5a7b1b151cc2abaa95b230255b0a4f6a",
    "src/logger.ts": "781f11675d0bbbba0a42143c7d34f9c8304b8a658c81df04723e31eb48ba9581",
    "src/types.ts": "650c0757027d778c1e901a8163fc04d144b91e6521f8242b5740909c9ab8ed2a",
    "tests/client.test.ts": "c2c8d7c6cac9b3b03fc3857777e74f89346b8e38472c84ef25ce054ed51c6240",
    "tests/logger.test.ts": "d95fa62f05f56cd63989b57ecd7a8df600758b6c41fb1bdc28cec0a6910056ba",
    "tests/queue.test.ts": "5e844e6251f230b7f12a59afe6e5fd106d60170c68f94f1c38ef6b6e40b6aa9a",
}
TITLES = [
    "buffers events and flushes when batchSize is reached",
    "flushes on timer",
    "merges base labels and sets event label per event",
    "log() uses level label",
    "ignores reserved labels provided in constructor",
    "retries: puts batch back on fetch failure and backs off",
    "manual flush sends pending events",
    "pagehide flushes via sendBeacon when available",
    "shutdown stops the timer and flushes once",
    "flushes a below-threshold event on the next interval after an initially empty tick",
    "flushes a new small batch after a successful send followed by an empty tick",
    "preserves Financial-shaped labels and track/log performance properties through the root export",
]
TEST_COMMAND = INNER + [NODE, "/work/sdk/node_modules/vitest/vitest.mjs",
    "run", "tests/client.test.ts", "--root=/work/sdk",
    "--config=/cache/config/vitest.config.mjs", "--reporter=default", "--reporter=json",
    "--reporter=/harness/telemetry-web-hosted-reporter.mjs", "--outputFile=/reports/vitest.json",
    "--no-cache", "--retry=0", "--bail=0", "--segfaultRetry=0"]

# Each entered helper replaces itself with ONE fixed leaf. The outer supervisor's
# pidfd therefore owns nsenter -> Python validator -> ip for the entire lifetime;
# there is no nested host subprocess to escape container/host cleanup accounting.
NAMESPACE_ACTIONS = {
    "lo-down": ["link", "set", "dev", "lo", "down"],
    "lo-flush": ["address", "flush", "dev", "lo"],
    "links": ["-j", "link", "show"],
    "addresses": ["-j", "address", "show"],
    "routes4": ["-j", "-4", "route", "show", "table", "all"],
    "routes6": ["-j", "-6", "route", "show", "table", "all"],
}
_OWNERSHIP_WINDOWS = 0
_CLEANUP_WINDOWS = 0
_INTERRUPTIBLE_WINDOWS = 0


@contextmanager
def ownership_window():
    """Defer ONLY our alarm exception across acquisition/registration or reap.

    No signal masks are inherited by children. TERM/INT/HUP handlers still record
    interruption. Deadlines are not reset: check immediately after setup; errors
    leave the resource registered for the surrounding cleanup scope. Never put
    polling, network I/O, a child wait, or recursive cleanup in this window.
    """
    global _OWNERSHIP_WINDOWS
    _OWNERSHIP_WINDOWS += 1
    try:
        yield
    finally:
        _OWNERSHIP_WINDOWS -= 1


@contextmanager
def cleanup_window():
    """Do not asynchronously abort an unwind between independent releases.

    Cleanup still uses the original monotonic deadline for every child wait,
    command and directory entry. This changes exception delivery, not budgets.
    """
    global _CLEANUP_WINDOWS
    _CLEANUP_WINDOWS += 1
    try:
        yield
    finally:
        _CLEANUP_WINDOWS -= 1


@contextmanager
def interruptible_window():
    """Permit the phase alarm in fallible I/O already enclosed by attempt()."""
    global _INTERRUPTIBLE_WINDOWS
    _INTERRUPTIBLE_WINDOWS += 1
    try:
        yield
    finally:
        _INTERRUPTIBLE_WINDOWS -= 1


def attempt(errors, label, operation):
    """Independent cleanup steps must not mask the initial failure or each other."""
    try:
        return operation()
    except BaseException as error:
        errors.append(f"{label}:{type(error).__name__}:{error}")
        return None


class Failure(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise Failure(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def pair(fd):
    info = os.fstat(fd)
    return [str(info.st_dev), str(info.st_ino)]


def ns_pair(path="/proc/self/ns/net"):
    fd = None
    try:
        with ownership_window():
            fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC)
        return pair(fd)
    finally:
        if fd is not None:
            with ownership_window():
                os.close(fd)


def json_bytes(data):
    # Duplicated keys are ambiguous evidence, not last-key-wins input.
    def unique(items):
        result = {}
        for key, value in items:
            require(key not in result, "duplicate JSON key")
            result[key] = value
        return result
    return json.loads(data, object_pairs_hook=unique)


class Bounded:
    """One cumulative deadline/output budget per phase; no shell or group signals.

    Direct children are pinned with pidfds before any wait/reap. On failure only
    that handle is signalled. Docker descendants are stopped through exact CID
    cleanup, never through a stale CLI PID/PGID. No cleanup-by-job-teardown claim.
    """
    def __init__(self):
        self.phase = None
        self.deadline = 0
        self.used = 0
        self.records = []
        self.interrupted = None
        self.log = bytearray()
        self.children = []

    def begin(self, phase, elapsed=0):
        require(phase in BUDGETS, "unknown phase")
        self.phase = phase
        self.used = 0
        self.deadline = time.monotonic() + BUDGETS[phase] - elapsed
        def expired(_signum, _frame):
            if not _OWNERSHIP_WINDOWS and (not _CLEANUP_WINDOWS or _INTERRUPTIBLE_WINDOWS):
                raise Failure(f"{phase}:deadline")
        signal.signal(signal.SIGALRM, expired)
        signal.setitimer(signal.ITIMER_REAL, max(0.001, self.deadline - time.monotonic()))
        self.check()

    def check(self):
        require(time.monotonic() < self.deadline, f"{self.phase}:deadline")
        require(self.interrupted is None, f"interrupted:{self.interrupted}")

    def reap(self, child):
        process = child["process"]
        if process is None or child["reaped"]:
            return
        # waitpid and bookkeeping are indivisible with respect to our alarm. A
        # reaped numeric PID is NEVER signalled, even if a later operation fails.
        with ownership_window():
            try:
                pid, status = os.waitpid(process.pid, os.WNOHANG)
            except ChildProcessError:
                child["reaped"] = True
                process.returncode = 255
                raise Failure("unexpected external reap: process ownership lost")
            if pid:
                child["reaped"] = True
                child["receipt"]["waitStatus"] = status
                process.returncode = os.waitstatus_to_exitcode(status)
                child["receipt"]["exit"] = process.returncode

    @cleanup_window()
    def finish_child(self, child, deadline):
        """Try every release, retaining live-child ownership for Harness.cleanup."""
        errors = child["receipt"]["cleanupErrors"]
        process = child["process"]
        before = len(errors)
        attempt(errors, "reap-before-signal", lambda: self.reap(child))
        if process is not None and not child["reaped"]:
            def terminate():
                with ownership_window():
                    if child["handle"] is not None:
                        try:
                            signal.pidfd_send_signal(child["handle"], signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    else:
                        # Only a pidfd-setup failure reaches this fallback. No
                        # other waiter is installed; an unreaped direct child
                        # reserves its PID. Any wait ambiguity disables fallback.
                        require(len(errors) == before, "numeric identity uncertain")
                        os.kill(process.pid, signal.SIGKILL)
            attempt(errors, "terminate", terminate)

            def wait_terminal():
                while not child["reaped"]:
                    self.reap(child)
                    if child["reaped"]:
                        break
                    remaining = deadline - time.monotonic()
                    require(remaining > 0, "child cleanup deadline; ownership retained")
                    descriptors = [] if child["handle"] is None else [child["handle"]]
                    select.select(descriptors, [], [], min(0.01, remaining))
            attempt(errors, "terminal-reap", wait_terminal)

        def close_slot(key, close):
            with ownership_window():
                value = child[key]
                child[key] = None  # Never retry a close against a reused FD.
                if value is not None:
                    close(value)
        attempt(errors, "selector-close", lambda: close_slot("selector", lambda value: value.close()))
        attempt(errors, "pipe-close", lambda: close_slot("pipe", lambda value: value.close()))
        if process is None or child["reaped"]:
            attempt(errors, "pidfd-close", lambda: close_slot("handle", os.close))
            with ownership_window():
                if child in self.children:
                    self.children.remove(child)
        child["receipt"]["terminal"] = process is None or child["reaped"]

    def cleanup_children(self):
        for child in list(self.children):
            attempt(child["receipt"]["cleanupErrors"], "host-child-cleanup",
                    lambda child=child: self.finish_child(child, min(self.deadline, time.monotonic() + 1)))
        require(not self.children, "host child termination/reap remains uncertain")

    @cleanup_window()
    def finalize_command(self, child, output):
        receipt = child["receipt"]
        attempt(receipt["cleanupErrors"], "command-cleanup",
                lambda: self.finish_child(child, min(self.deadline, time.monotonic() + 1)))
        receipt["bytes"], receipt["sha256"] = len(output), digest(output)
        self.log.extend(output)
        def emit():
            with interruptible_window():
                self.check()
                sys.stdout.write(output.decode("utf-8", errors="backslashreplace"))
                sys.stdout.flush()
        attempt(receipt["cleanupErrors"], "log-write-flush", emit)

    def run(self, argv, allowed=(0,), pass_fds=(), seconds=None):
        receipt = {"phase": self.phase, "argv": argv, "waitStatus": None, "exit": None,
                   "error": None, "cleanupErrors": [], "terminal": False, "bytes": 0, "sha256": None}
        child = {"process": None, "handle": None, "selector": None, "pipe": None,
                 "reaped": False, "receipt": receipt}
        output = bytearray()
        original = None
        traceback = None
        # Scope/receipt/registry precede launch and ALL partial setup operations.
        try:
            with ownership_window():
                self.records.append(receipt)
                self.children.append(child)
            self.check()
            deadline = min(self.deadline, time.monotonic() + (seconds or 1200))
            with ownership_window():
                child["process"] = subprocess.Popen(
                    argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                    env=ENV, close_fds=True, pass_fds=pass_fds, start_new_session=True)
                child["pipe"] = child["process"].stdout
                child["handle"] = os.pidfd_open(child["process"].pid)
            self.check()
            with ownership_window():
                child["selector"] = selectors.DefaultSelector()
            child["selector"].register(child["pipe"], selectors.EVENT_READ)
            self.check()
            while child["selector"].get_map():
                self.check()
                require(time.monotonic() < deadline, "command deadline")
                for key, _ in child["selector"].select(min(0.1, max(0, deadline - time.monotonic()))):
                    chunk = os.read(key.fileobj.fileno(), 65536)
                    if not chunk:
                        child["selector"].unregister(key.fileobj)
                        continue
                    require(self.used + len(chunk) <= OUTPUT_LIMIT, "phase output overflow/truncation")
                    self.used += len(chunk)
                    output.extend(chunk)
            while not child["reaped"]:
                self.check()
                require(time.monotonic() < deadline, "exit deadline")
                select.select([child["handle"]], [], [], min(0.1, max(0, deadline - time.monotonic())))
                self.reap(child)
            self.check()
            require(child["process"].returncode in allowed,
                    f"command failed: {argv[0]} exit {child['process'].returncode}")
        except BaseException as exc:
            original, traceback = exc, exc.__traceback__
            receipt["error"] = f"{type(exc).__name__}:{exc}"
        finally:
            attempt(receipt["cleanupErrors"], "command-finalizer", lambda: self.finalize_command(child, output))
        if original is not None:
            raise original.with_traceback(traceback)
        require(receipt["terminal"] and not receipt["cleanupErrors"], "command cleanup/log failure")
        return bytes(output), child["process"].returncode


def network_state(query):
    links = json_bytes(query("links"))
    addresses = json_bytes(query("addresses"))
    routes4 = json_bytes(query("routes4"))
    routes6 = json_bytes(query("routes6"))
    require(len(links) == 1 and links[0]["ifname"] == "lo", "unexpected interface")
    require("UP" not in links[0]["flags"], "loopback is UP")
    require(len(addresses) == 1 and not addresses[0].get("addr_info"), "addresses remain")
    require(not routes4 and not routes6, "routes remain")
    return {"links": links, "addresses": addresses, "routes4": routes4, "routes6": routes6}


def entered(args):
    """Trusted privileged child: no Docker/SDK invocation or arbitrary commands."""
    require(os.geteuid() == 0, "privilege must precede descriptor acquisition")
    expected, host = args.expected.split(":"), args.host.split(":")
    require(pair(args.fd) == expected == ns_pair(), "entered namespace mismatch")
    require(expected != host, "host namespace rejected")
    os.close(args.fd)  # nsenter closes its own open, not our inherited copy.
    require(args.operation in NAMESPACE_ACTIONS, "unknown fixed namespace action")
    os.execve(IP, [IP, *NAMESPACE_ACTIONS[args.operation]], ENV)


class Harness:
    def __init__(self, bootstrap_started):
        # Bookkeeping only: no root, FD, alarm, signal handler or subprocess is
        # acquired until run() has installed its encompassing cleanup finally.
        self.bootstrap_started = bootstrap_started
        self.runner = Bounded()
        self.root = None
        self.root_created = False
        self.root_identity = None
        self.root_fd = None
        self.owned_fds = set()
        self.nonce = None
        self.containers = {}
        self.pending_names = {}
        self.listeners = []
        self.host_ns = None
        self.evidence = {"schema": 1, "source": BASE, "imageIndex": INDEX, "imageChild": CHILD,
                         "config": CONFIG, "controls": [], "cleanup": False, "commands": self.runner.records}

    def own_fd(self, operation, *arguments):
        with ownership_window():
            fd = operation(*arguments)
            self.owned_fds.add(fd)
        return fd

    def release_fd(self, fd):
        with ownership_window():
            if fd in self.owned_fds:
                self.owned_fds.remove(fd)
                os.close(fd)

    def initialize(self):
        require(os.geteuid() == 0 and sys.platform == "linux", "trusted Linux root supervisor required")
        require(hasattr(os, "pidfd_open") and hasattr(signal, "pidfd_send_signal"), "pidfd support required")
        require(signal.getsignal(signal.SIGCHLD) == signal.SIG_DFL, "unexpected child reaper")
        self.runner.begin("admission", max(0, time.time() - self.bootstrap_started))
        capability = self.own_fd(os.pidfd_open, os.getpid())
        try:
            signal.pidfd_send_signal(capability, 0)
        finally:
            self.release_fd(capability)
        self.nonce = os.urandom(16).hex()
        # Choose the path before exclusive mkdir so collision failure cannot
        # register an existing root. Guard successful mkdir through registration.
        self.root = Path("/tmp") / ("telemetry-web-owned-" + self.nonce)
        with ownership_window():
            os.mkdir(self.root, 0o700)
            self.root_created = True
            self.root_fd = self.own_fd(os.open, self.root,
                                       os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
            info = os.fstat(self.root_fd)
            self.root_identity = (info.st_dev, info.st_ino)
        self.runner.check()
        self.root.chmod(0o755)
        (self.root / "owner").write_text(self.nonce)
        self.host_ns = ns_pair()
        self.sdk = self.root / "projection/sdk"
        self.acquisition = self.root / "acquisition/sdk"
        self.helpers = self.root / "helpers"
        self.wrapper = self.root / "vitest.config.mjs"
        self.wrapper.write_text(WRAPPER)
        self.wrapper.chmod(0o444)
        for name in ("config", "docker-config", "npm-cache", "expectations", "receipts"):
            (self.root / name).mkdir()
        for name in ("user.npmrc", "global.npmrc"):
            (self.root / "config" / name).write_bytes(b"")
        self.helpers.mkdir()
        for name in ("telemetry-web-hosted-baseline.py", "telemetry-web-hosted-d1.cjs",
                     "telemetry-web-hosted-reporter.mjs"):
            source = Path(__file__).parent / name
            require(source.is_file() and not source.is_symlink(), "helper missing/symlink")
            shutil.copyfile(source, self.helpers / name)
            (self.helpers / name).chmod(0o444)
        self.helper_hashes = self.hash_files(self.helpers)
        self.evidence["helpers"] = self.helper_hashes
        self.evidence["wrapper"] = {"bytes": WRAPPER, "sha256": digest(WRAPPER.encode()),
                                    "originalConfig": SOURCE["vitest.config.ts"]}

    def docker(self, *arguments, **kwargs):
        return self.runner.run([DOCKER, "--config", str(self.root / "docker-config"),
                                "--host", "unix:///var/run/docker.sock", *arguments], **kwargs)

    def inspect(self, cid):
        values = json_bytes(self.docker("inspect", "--type", "container", cid)[0])
        require(len(values) == 1 and values[0]["Id"] == cid, "full CID mismatch")
        return values[0]

    def hash_files(self, root):
        result = {}
        for directory, dirs, files in os.walk(root, followlinks=False):
            self.runner.check()
            for name in sorted(dirs + files):
                path = Path(directory) / name
                relative = str(path.relative_to(root))
                info = path.lstat()
                if stat.S_ISLNK(info.st_mode):
                    require(path.resolve().is_relative_to(root.resolve()), "dependency symlink escapes owned tree")
                    result[relative] = ["link", os.readlink(path)]
                elif stat.S_ISREG(info.st_mode):
                    require(info.st_nlink == 1, "unexpected hardlink")
                    hasher = hashlib.sha256()
                    with path.open("rb") as stream:
                        while chunk := stream.read(1024 * 1024):
                            self.runner.check()
                            hasher.update(chunk)
                    result[relative] = [stat.S_IMODE(info.st_mode), info.st_size, hasher.hexdigest()]
                else:
                    require(stat.S_ISDIR(info.st_mode), "special file in owned tree")
        return result

    def check_source(self, root):
        for name, expected in SOURCE.items():
            path = root / name
            require(path.is_file() and not path.is_symlink(), "source missing/symlink")
            require(digest(path.read_bytes()) == expected, f"source changed:{name}")
            require(stat.S_IMODE(path.stat().st_mode) == 0o644, f"source mode changed:{name}")

    def admission(self):
        for executable in (DOCKER, IP, NSENTER, PYTHON, "/usr/bin/curl"):
            require(os.access(executable, os.X_OK), f"required tool missing:{executable}")
        self.runner.run([NSENTER, "--version"])
        self.runner.run([IP, "-Version"])
        self.docker("version")
        info = json_bytes(self.docker("info", "--format", "{{json .}}")[0])
        require(info["OSType"] == "linux" and info["Architecture"] == "x86_64", "wrong daemon platform")
        require(info["CgroupVersion"] == "2", "cgroup v2 cleanup proof required")
        require(any("seccomp" in value and "builtin" in value for value in info["SecurityOptions"]),
                "builtin default seccomp unavailable")
        self.evidence["daemon"] = {key: info[key] for key in ("ServerVersion", "CgroupVersion", "SecurityOptions")}
        # Immutable child was independently resolved from INDEX; Docker verifies
        # pulled manifest/config/layers. No moving tag or alternate image fallback.
        self.docker("pull", "--platform", "linux/amd64", IMAGE)
        image = json_bytes(self.docker("image", "inspect", IMAGE)[0])[0]
        require(image["Id"] == CONFIG and image["Os"] == "linux" and image["Architecture"] == "amd64",
                "image config/platform mismatch")
        require(any(value.endswith("@" + CHILD) for value in image["RepoDigests"]), "child digest not admitted")
        require(not image["Config"].get("Volumes") and not image["Config"].get("OnBuild"), "implicit image resources")
        self.evidence["imageConfig"] = image
        archive = self.root / "source.tar.gz"
        self.runner.run(["/usr/bin/curl", "--disable", "--fail", "--silent", "--show-error", "--proto", "=https",
                         "--tlsv1.2", "--connect-timeout", "15", "--max-time", "60", "--retry", "0",
                         "--max-filesize", "4194304", "--output", str(archive),
                         f"https://codeload.github.com/LeePepe/shared-telemetry/tar.gz/{BASE}"])
        require(archive.stat().st_size <= 4194304, "source archive too large")
        self.sdk.mkdir(parents=True)
        seen = set()
        # Do not extract archive paths, links or modes. Select and hash only the
        # independently frozen 17-file SDK projection into exact trusted paths.
        with tarfile.open(archive, "r:gz") as bundle:
            for member in bundle:
                self.runner.check()
                parts = PurePosixPath(member.name).parts
                require(".." not in parts and not member.name.startswith("/"), "unsafe source archive")
                if len(parts) < 4 or parts[1:3] != ("sdks", "web") or member.isdir():
                    continue
                name = "/".join(parts[3:])
                require(name in SOURCE and name not in seen and member.isfile(), "unexpected SDK archive entry")
                # GitHub/git archive can apply 0002 to nonexecutables (0664).
                # Normalize those ordinary archive permissions to frozen 100644;
                # never accept executable, special or set-ID source entries.
                require(member.mode in (0o644, 0o664) and member.size <= REPORT_LIMIT,
                        "unexpected SDK entry mode/size")
                data = bundle.extractfile(member).read(REPORT_LIMIT + 1)
                require(digest(data) == SOURCE[name], "frozen source hash mismatch")
                target = self.sdk / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
                target.chmod(0o644)
                seen.add(name)
        require(seen == set(SOURCE), "incomplete SDK projection")
        self.check_source(self.sdk)
        self.evidence["sourceHashes"] = SOURCE
        self.evidence["archiveSHA256"] = digest(archive.read_bytes())
        (self.root / "expectations" / "source.json").write_text(json.dumps(SOURCE))

    def collision(self, name, marker):
        ids = self.docker("ps", "--all", "--quiet", "--no-trunc", "--filter", f"name=^/{name}$")[0].strip()
        require(not ids and not marker.exists(), "owned resource collision")

    def create(self, role, acquisition=False):
        name = f"telemetry-web-{self.nonce}-{role}"
        marker = self.root / f"{role}.cid"
        self.collision(name, marker)
        mounts = {"/harness": (self.helpers, False)}
        if acquisition:
            mounts.update({"/work/sdk": (self.acquisition, True),
                           "/cache": (self.root / "npm-cache", True),
                           "/run/config": (self.root / "config", False)})
        else:
            mounts.update({"/work/sdk": (self.sdk, False),
                           "/work/sdk/node_modules": (self.acquisition / "node_modules", False),
                           "/cache/config/vitest.config.mjs": (self.wrapper, False)})
        arguments = ["create", "--name", name, "--cidfile", str(marker),
            "--label", f"telemetry.owner={self.nonce}", "--label", f"telemetry.role={role}",
            "--platform", "linux/amd64", "--user", "10001:10001", "--read-only",
            "--cap-drop", "ALL", "--security-opt", "no-new-privileges=true",
            "--network", "bridge" if acquisition else "none", "--ipc", "private",
            "--restart", "no", "--pids-limit", "256", "--memory", "1g", "--memory-swap", "1g",
            "--cpus", "2", "--ulimit", "nofile=1024:1024", "--ulimit", "core=0:0",
            "--workdir", "/work/sdk", "--entrypoint", "/usr/bin/env",
            "--log-driver", "none", "--stop-timeout", "2",
            "--tmpfs", "/tmp:rw,nosuid,nodev,noexec,size=64m,uid=10001,gid=10001,mode=0700"]
        if not acquisition:
            for mount, size in (("/cache", "64m"), ("/cache/config", "16m"), ("/reports", "4m")):
                arguments += ["--tmpfs", f"{mount}:rw,nosuid,nodev,noexec,size={size},uid=10001,gid=10001,mode=0700"]
        for target, (source, writable) in mounts.items():
            value = f"type=bind,src={source},dst={target}" + ("" if writable else ",readonly")
            arguments += ["--mount", value]
        arguments += [IMAGE, "-i", "PATH=/usr/local/bin:/usr/bin:/bin", "/usr/bin/sleep", "1100"]
        # Record ownership intent before a bounded create can time out. Cleanup
        # recovers only an exact name+nonce+role CID; ambiguity remains failure.
        self.pending_names[name] = role
        output, _ = self.docker(*arguments)
        cid = output.decode().strip()
        require(re.fullmatch(r"[0-9a-f]{64}", cid), "create returned no full CID")
        require(marker.read_text().strip() == cid, "CID marker mismatch")
        record = {"cid": cid, "role": role, "name": name, "mounts": mounts,
                  "acquisition": acquisition, "nsfd": None, "pidfds": [], "cgroup": None}
        self.containers[cid] = record
        del self.pending_names[name]
        self.docker("start", cid)
        current = self.boundary(record, initial=True)
        record["pid"] = current["State"]["Pid"]
        record["started"] = current["State"]["StartedAt"]
        record["restarts"] = current["RestartCount"]
        group = Path(f"/proc/{record['pid']}/cgroup").read_text().strip()
        require(group.startswith("0::/") and "\n" not in group, "unexpected cgroup hierarchy")
        group_path = Path("/sys/fs/cgroup") / group[4:]
        require(group_path.resolve().is_relative_to(Path("/sys/fs/cgroup"))
                and group_path != Path("/sys/fs/cgroup"), "unsafe cgroup path")
        record["cgroup"] = group_path
        record["groupfd"] = self.own_fd(os.open, group_path, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
        self.pin_processes(record)
        return record

    def boundary(self, record, initial=False):
        data = self.inspect(record["cid"])
        config, host, state = data["Config"], data["HostConfig"], data["State"]
        require(config["Labels"].get("telemetry.owner") == self.nonce
                and config["Labels"].get("telemetry.role") == record["role"], "container ownership mismatch")
        require(data["Name"] == "/" + record["name"] and data["Image"] == CONFIG, "container image/name drift")
        require(state["Running"] and not state["Paused"] and not state["Restarting"]
                and not state["Dead"] and not state["OOMKilled"], "container not continuously live")
        require(config["User"] == "10001:10001" and host["ReadonlyRootfs"], "user/rootfs boundary")
        require(host["CapDrop"] == ["ALL"] and not host["CapAdd"] and not host["Privileged"], "capability boundary")
        require(host["SecurityOpt"] == ["no-new-privileges=true"], "security options/default seccomp drift")
        require(host["NetworkMode"] == ("bridge" if record["acquisition"] else "none"), "network boundary")
        require(host["PidMode"] == "" and host["IpcMode"] == "private"
                and host["UTSMode"] == "" and host["UsernsMode"] == "", "namespace boundary")
        require(host["RestartPolicy"]["Name"] == "no" and not host["AutoRemove"], "restart/removal boundary")
        require(not host["Devices"] and not host.get("DeviceRequests") and not host["PortBindings"], "unexpected host access")
        require(host["PidsLimit"] == 256 and host["Memory"] == 1073741824
                and host["MemorySwap"] == 1073741824 and host["NanoCpus"] == 2000000000, "resource limits drift")
        actual = {entry["Destination"]: (Path(entry["Source"]), entry["RW"])
                  for entry in data["Mounts"] if entry["Type"] == "bind"}
        require(actual == record["mounts"], "mount mapping drift")
        require(all(entry["Type"] in ("bind", "tmpfs") for entry in data["Mounts"]), "unowned mount")
        expected_tmpfs = {"/tmp"} if record["acquisition"] else {"/tmp", "/cache", "/cache/config", "/reports"}
        require(set(host["Tmpfs"]) == expected_tmpfs, "scratch mount drift")
        require(config["Entrypoint"] == ["/usr/bin/env"] and config["Cmd"] ==
                ["-i", "PATH=/usr/local/bin:/usr/bin:/bin", "/usr/bin/sleep", "1100"], "PID1 drift")
        if not initial:
            require(state["Pid"] == record["pid"] and state["StartedAt"] == record["started"]
                    and data["RestartCount"] == record["restarts"], "container lifecycle changed")
        return data

    def pin_processes(self, record):
        require(record["cgroup"] is not None, "missing owned cgroup")
        procs = (record["cgroup"] / "cgroup.procs").read_text().split()
        require(procs, "owned cgroup unexpectedly empty")
        for pid in procs:
            require(pid.isdecimal(), "malformed cgroup PID")
            record["pidfds"].append(self.own_fd(os.pidfd_open, int(pid)))
        return len(procs)

    def execute(self, record, command, **kwargs):
        self.boundary(record)
        result = self.docker("exec", "--user", "10001:10001", "--workdir", "/work/sdk",
                             record["cid"], *command, **kwargs)
        self.boundary(record)
        return result

    def probe(self, record, mode, values=None):
        result, _ = self.execute(record, INNER + [NODE, HELPER, mode, json.dumps(values or {})])
        require(len(result) <= REPORT_LIMIT, "control evidence oversized")
        return json_bytes(result)

    def acquire(self):
        self.runner.begin("acquisition")
        shutil.copytree(self.sdk, self.acquisition)
        for directory, dirs, files in os.walk(self.acquisition):
            os.chown(directory, 10001, 10001)
            for name in files:
                os.chown(Path(directory) / name, 10001, 10001)
        os.chown(self.root / "npm-cache", 10001, 10001)
        container = self.create("acquisition", acquisition=True)
        versions = self.probe(container, "version")
        node_pins = [value.split("=", 1)[1] for value in self.evidence["imageConfig"]["Config"]["Env"]
                     if value.startswith("NODE_VERSION=")]
        require(len(node_pins) == 1 and versions == {"node": "v" + node_pins[0], "arch": "x64", "platform": "linux"}
                and re.fullmatch(r"22\.\d+\.\d+", node_pins[0]), "image Node identity not admitted")
        npm, _ = self.execute(container, INNER + ["/usr/local/bin/npm", "--version"])
        require(re.fullmatch(rb"\d+\.\d+\.\d+\n", npm), "npm patch version evidence missing")
        self.evidence["versions"] = {**versions, "npm": npm.decode().strip()}
        command = ["/usr/bin/env", "-i", "PATH=/usr/local/bin:/usr/bin:/bin", "TMPDIR=/tmp",
            "/usr/local/bin/npm", "ci", "--prefix=/work/sdk", "--include=dev", "--include=optional",
            "--ignore-scripts", "--no-audit", "--no-fund", "--update-notifier=false",
            "--registry=https://registry.npmjs.org/", "--userconfig=/run/config/user.npmrc",
            "--globalconfig=/run/config/global.npmrc", "--cache=/cache", "--engine-strict",
            "--fetch-retries=0", "--fetch-timeout=30000"]
        self.execute(container, command)
        self.check_source(self.acquisition)
        self.check_source(self.sdk)
        for name in ("user.npmrc", "global.npmrc"):
            require((self.root / "config" / name).read_bytes() == b"", "npm config changed")
        self.stop(container)

    def inventory(self):
        self.runner.begin("inventory")
        lock = json_bytes((self.sdk / "package-lock.json").read_bytes())
        manifest = json_bytes((self.sdk / "package.json").read_bytes())
        require(lock["lockfileVersion"] == 3 and len(lock["packages"]) == 189, "lock structure changed")
        require(manifest["devDependencies"] == lock["packages"][""]["devDependencies"], "manifest/lock mismatch")
        expected = {}
        for name, item in lock["packages"].items():
            if not name:
                continue
            require(item.get("dev") and item["resolved"].startswith("https://registry.npmjs.org/")
                    and item["integrity"].startswith("sha512-"), "unsafe acquisition record")
            if all(value in item.get(field, [value]) for field, value in
                   (("os", "linux"), ("cpu", "x64"), ("libc", "glibc"))):
                expected[name] = item
        require(len(expected) == 116, "static Linux x64 glibc closure drift")
        modules = self.acquisition / "node_modules"
        require(modules.is_dir() and not modules.is_symlink(), "missing installed dependencies")
        installed = json_bytes((modules / ".package-lock.json").read_bytes())
        require(set(installed["packages"]) == set(expected), "installed closure mismatch")
        for name, item in expected.items():
            actual = installed["packages"][name]
            require(all(actual.get(key) == item[key] for key in ("version", "resolved", "integrity")),
                    f"installed lock mismatch:{name}")
            package = self.acquisition / name / "package.json"
            require(package.is_file() and not package.is_symlink(), "installed package manifest missing")
            package_json = json_bytes(package.read_bytes())
            require(package_json["version"] == item["version"], f"installed version mismatch:{name}")
        for name in ("vitest/vitest.mjs", "@esbuild/linux-x64/bin/esbuild",
                     "vite/node_modules/@esbuild/linux-x64/bin/esbuild",
                     "@rollup/rollup-linux-x64-gnu/rollup.linux-x64-gnu.node"):
            require((modules / name).is_file(), f"required entry/binary missing:{name}")
        # No imports/native loads. Freeze every installed byte/mode/link after npm
        # SRI acquisition, and compare again after the read-only payload finishes.
        self.dependencies = self.hash_files(modules)
        self.evidence["inventory"] = {"packages": {key: value["version"] for key, value in expected.items()},
                                       "treeSHA256": digest(json.dumps(self.dependencies, sort_keys=True).encode()),
                                       "entries": len(self.dependencies)}
        (self.root / "expectations" / "dependencies.json").write_text(json.dumps(self.dependencies, sort_keys=True))
        # Nested read-only mount needs a destination in the frozen SDK directory.
        (self.sdk / "node_modules").mkdir()

    def reject_host(self, fd, expected):
        require(pair(fd) == expected and expected != self.host_ns, "host/mismatched namespace rejected")

    def bind(self, record):
        self.boundary(record)
        fd = self.own_fd(os.open, f"/proc/{record['pid']}/ns/net", os.O_RDONLY | os.O_CLOEXEC)
        # Retain immediately for cleanup even if subsequent independent binding fails.
        record["nsfd"] = fd
        expected = pair(fd)
        self.reject_host(fd, expected)
        probe = self.probe(record, "namespace")
        require(probe == {"namespace": expected, "uid": 10001, "gid": 10001}, "CID/retained-FD mismatch")
        record["namespace"] = expected
        self.boundary(record)
        self.enter(record, "lower")

    def enter(self, record, operation="verify"):
        require(operation in ("lower", "verify"), "unknown namespace sequence")

        def action(name):
            self.boundary(record)
            require(pair(record["nsfd"]) == record["namespace"], "retained FD changed")
            probe = self.probe(record, "namespace")
            require(probe["namespace"] == record["namespace"], "live container namespace changed")
            self.reject_host(record["nsfd"], record["namespace"])
            output, _ = self.runner.run(
                [NSENTER, f"--net=/proc/self/fd/{record['nsfd']}", PYTHON, "-I",
                 str(self.helpers / "telemetry-web-hosted-baseline.py"), "--entered",
                 "--fd", str(record["nsfd"]), "--expected", ":".join(record["namespace"]),
                 "--host", ":".join(self.host_ns), "--operation", name],
                pass_fds=(record["nsfd"],), seconds=12)
            self.boundary(record)
            return output

        if operation == "lower":
            action("lo-down")
            action("lo-flush")
        state = network_state(action)
        self.evidence.setdefault("namespaceStates", []).append(
            {"cid": record["cid"], "namespace": record["namespace"], "state": state})

    def outside(self):
        for listener in self.listeners:
            address = listener.getsockname()
            with socket.socket(listener.family, socket.SOCK_STREAM) as client:
                client.settimeout(min(1, max(0.01, self.runner.deadline - time.monotonic())))
                client.connect(address)
                accepted, _ = listener.accept()
                accepted.close()

    def controls(self, record, stage):
        self.enter(record)
        self.outside()
        require(self.private.read_text() == self.nonce, "outside surrogate positive failed")
        values = {"nonce": self.nonce, "privatePath": str(self.private), "listeners": [
            {"host": listener.getsockname()[0], "port": listener.getsockname()[1]}
            for listener in self.listeners]}
        result = self.probe(record, "controls", values)
        require(result["namespace"] == record["namespace"]
                and result["child"]["namespace"] == record["namespace"], "control namespace mismatch")
        require(result["scratch"] and result["builtinLoad"] and result["child"]["scratch"]
                and result["child"]["fdPositive"] and result["child"]["ipcPositive"]
                and result["child"]["code"] == 0 and result["child"]["signal"] is None,
                "missing positive controls/real child exit")
        self.outside()
        self.enter(record)
        self.evidence["controls"].append({"stage": stage, "cid": record["cid"], "result": result})

    def d1(self):
        self.runner.begin("d1")
        self.private = self.root / "host-private-surrogate"
        self.private.write_text(self.nonce)
        self.private.chmod(0o600)
        for family, address in ((socket.AF_INET, "127.0.0.1"), (socket.AF_INET6, "::1")):
            with ownership_window():
                listener = socket.socket(family, socket.SOCK_STREAM)
                self.listeners.append(listener)
            self.runner.check()
            listener.settimeout(1)
            if family == socket.AF_INET6:
                listener.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            listener.bind((address, 0))
            listener.listen(8)
        self.outside()
        # Same guard as real create; synthetic occupied marker must be refused.
        marker = self.root / "synthetic-collision"
        marker.write_text(self.nonce)
        try:
            self.collision(f"telemetry-web-{self.nonce}-collision", marker)
        except Failure as error:
            require(str(error) == "owned resource collision", "wrong collision failure")
        else:
            raise Failure("collision guard allowed existing marker")
        require(marker.read_text() == self.nonce, "collision marker mutated")
        self.evidence["markerCollision"] = True
        host_fd = self.own_fd(os.open, "/proc/self/ns/net", os.O_RDONLY | os.O_CLOEXEC)
        try:
            try:
                self.reject_host(host_fd, pair(host_fd))
            except Failure:
                self.evidence["hostNamespaceRejected"] = True
            else:
                raise Failure("host namespace accepted")
        finally:
            self.release_fd(host_fd)
        # A non-namespace FD must prevent even this fixed harmless marker command.
        invalid = self.own_fd(os.open, self.root / "owner", os.O_RDONLY | os.O_CLOEXEC)
        mutation = self.root / "invalid-entry-mutation"
        try:
            _, exit_code = self.runner.run([NSENTER, f"--net=/proc/self/fd/{invalid}",
                                            "/usr/bin/touch", str(mutation)],
                                           pass_fds=(invalid,), allowed=(1,), seconds=5)
            require(exit_code == 1 and not mutation.exists(), "invalid entry reached mutation")
            self.evidence["invalidEntryRejected"] = True
        finally:
            self.release_fd(invalid)
        probe = self.create("interruption")
        # Exercise actual name collision too, without mutating the owned container.
        try:
            self.collision(probe["name"], self.root / "unused-collision-marker")
        except Failure as error:
            require(str(error) == "owned resource collision", "wrong name collision failure")
        else:
            raise Failure("live owned name collision was accepted")
        self.evidence["nameCollision"] = True
        self.bind(probe)
        self.controls(probe, "interruption-pre")
        self.docker("exec", "--detach", "--user", "10001:10001", probe["cid"],
                    *INNER, NODE, HELPER, "interrupt")
        state = self.probe(probe, "interrupt-state")
        require(state["namespace"] == probe["namespace"] and state["parent"] != state["child"]
                and state["parent"] > 1 and state["child"] > 1, "parent/child interruption readiness missing")
        require(self.pin_processes(probe) >= 3, "real interruption descendants missing")
        self.boundary(probe)
        before = pair(probe["nsfd"])
        self.stop(probe, retain_namespace=True)
        try:
            require(pair(probe["nsfd"]) == before == probe["namespace"], "retained handle lost identity")
        finally:
            self.release_fd(probe["nsfd"])
            probe["nsfd"] = None
        self.evidence["interruption"] = {"ready": state, "retainedIdentity": before, "terminalDescendants": True}
        # The terminated probe's retained namespace never authorizes payload reuse.
        self.payload = self.create("baseline")
        self.bind(self.payload)
        self.controls(self.payload, "baseline-pre")
        self.evidence["payloadBoundary"] = self.boundary(self.payload)

    def baseline(self):
        self.runner.begin("baseline")
        self.enter(self.payload)
        output, code = self.execute(self.payload, TEST_COMMAND, allowed=(1,))
        self.raw_output = output
        self.raw_exit = code
        # The exact exec record captures wait status; inspect calls around it do not.
        self.raw_record = next(record for record in reversed(self.runner.records)
                               if record["argv"][-len(TEST_COMMAND):] == TEST_COMMAND)
        require(self.raw_record["waitStatus"] == 256 and self.raw_record["error"] is None,
                "test did not exit normally with status 1")
        self.enter(self.payload)

    def reconcile(self, reports):
        envelope, result = reports["harness"], reports["vitest"]
        require(envelope["schema"] == 1 and envelope["init"] == 1 and envelope["selection"] == 1
                and envelope["completion"] == 1 and envelope["flags"] == [], "mandatory reporter hooks/flags")
        expected_path = "/work/sdk/tests/client.test.ts"
        require(envelope["paths"] == envelope["files"] == [expected_path], "reporter selection mismatch")
        require(type(envelope["initialRestarts"]) is int and envelope["initialRestarts"] >= 1,
                "initial server restart baseline missing")
        for stage in ("finished", "exit"):
            observation = envelope[stage]
            require(observation["errors"] == [] and observation["cancelling"] is False
                    and observation["restarts"] == envelope["initialRestarts"], "late errors/cancellation/restart")
        require(envelope["finished"]["suppliedErrors"] == [] and envelope["exit"]["code"] == self.raw_exit == 1,
                "exit/completion disagreement")
        settings = envelope["settings"]
        expected_settings = {"root": "/work/sdk", "environment": "happy-dom", "globals": False,
            "include": ["tests/**/*.test.ts"], "cache": False, "viteRoot": "/work/sdk",
            "viteCache": "/cache/vite", "configFile": "/cache/config/vitest.config.mjs",
            "watch": False, "retry": 0, "bail": 0, "ignoreUnhandledErrors": False,
            "coverage": False, "browser": False, "testNamePattern": None}
        require(settings == expected_settings, "resolved settings not preserved")
        for key, value in {"numTotalTests": 12, "numPassedTests": 10, "numFailedTests": 2,
                           "numPendingTests": 0, "numTodoTests": 0, "numPendingTestSuites": 0,
                           "numFailedTestSuites": 0, "success": False}.items():
            require(result[key] == value, f"JSON summary mismatch:{key}")
        require(result["numTotalTestSuites"] == result["numPassedTestSuites"]
                and result["numTotalTestSuites"] > 0, "suite counters disagree")
        require(len(result["testResults"]) == 1, "unexpected report files")
        file = result["testResults"][0]
        require(file["name"] == expected_path and file["status"] == "failed" and file["message"] == "",
                "file selection/hook/loader error")
        assertions = file["assertionResults"]
        tasks = envelope["tasks"]
        require(len(assertions) == len(tasks) == 12, "assertion/task count")
        require({value["title"] for value in assertions} == set(TITLES)
                and {value["name"] for value in tasks} == set(TITLES), "exact assertion identities mismatch")
        task_map = {value["name"]: value for value in tasks}
        # Pin source locations and literal matcher evidence, not just failure count.
        failures = {TITLES[9]: (332, 1, 0), TITLES[10]: (353, 2, 1)}
        for assertion in assertions:
            title = assertion["title"]
            ancestors = assertion["ancestorTitles"]
            # The supplied JSON serializer follows task.suite while our envelope
            # walks file.tasks. File inclusion can differ; bind either rendering
            # to the same exact file and sole frozen suite, never arbitrary names.
            require(ancestors in (["LokiTelemetry"], ["tests/client.test.ts", "LokiTelemetry"],
                                  [expected_path, "LokiTelemetry"]), "unexpected suite identity")
            require(assertion["fullName"] == " ".join(ancestors + [title]), "full assertion identity mismatch")
            task = task_map[title]
            require(task["parents"] in (["tests/client.test.ts", "LokiTelemetry"],
                                         [expected_path, "LokiTelemetry"]), "task suite identity mismatch")
            require(task["mode"] == "run" and task["retryCount"] == task["repeatCount"] == 0,
                    "skip/focus/retry/repeat detected")
            require(all(value == "pass" for value in task["hooks"].values()), "test hook not passed")
            if title in failures:
                line, expected, actual = failures[title]
                require(assertion["status"] == "failed" and task["state"] == "fail", "intended RED absent")
                require(len(assertion["failureMessages"]) == len(task["errors"]) == 1, "extra assertion errors")
                message = assertion["failureMessages"][0]
                require(re.fullmatch(r'expected "[^"]+" to be called ' + str(expected)
                                    + r' times, but got ' + str(actual) + r' times', message),
                        "wrong idle assertion failure")
                require(task["errors"][0]["name"] == "AssertionError"
                        and task["errors"][0]["message"] == message, "not a matching assertion error")
                require(assertion["location"]["line"] == line and assertion["location"]["column"] > 0,
                        "failure at wrong source location")
            else:
                require(assertion["status"] == "passed" and task["state"] == "pass"
                        and assertion["failureMessages"] == [] and task["errors"] == [], "required pass absent")
        diagnostics = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", self.raw_output.decode("utf8", "strict"))
        forbidden = ("error during close", "Unhandled Error", "Unhandled Rejection", "Uncaught Exception",
                     "close timed out", "HARNESS_REPORT_WRITE_FAILURE", "Some tests are still running",
                     "Failed to load", "failed to load", "Segmentation fault", "SIGSEGV", "timed out",
                     "ERR_MODULE_NOT_FOUND", "ERR_DLOPEN_FAILED", "cancelled", "canceled")
        require(not any(value.casefold() in diagnostics.casefold() for value in forbidden),
                "contradictory loader/global/teardown/timeout diagnostic")
        require("Test Files" in diagnostics and "Tests" in diagnostics
                and "2 failed" in diagnostics and "10 passed" in diagnostics
                and "JSON report written to /reports/vitest.json" in diagnostics,
                "complete default/JSON diagnostics missing")
        for title, (line, _, _) in failures.items():
            require(title in diagnostics and f"client.test.ts:{line}" in diagnostics,
                    "intended assertion absent from diagnostics")
        for entry in reports["scratch"]:
            name = entry["path"]
            require(name in ("/cache/config/vitest.config.mjs", "/reports/harness.json", "/reports/vitest.json")
                    or name.startswith("/cache/vite/"), f"unexpected scratch write:{name}")
        self.evidence["reports"] = reports
        self.evidence["payloadWait"] = self.raw_record

    def readback(self):
        self.runner.begin("readback")
        self.controls(self.payload, "baseline-post")
        reports = self.probe(self.payload, "reports")
        self.reconcile(reports)
        self.check_source(self.sdk)
        self.check_source(self.acquisition)
        require(self.hash_files(self.acquisition / "node_modules") == self.dependencies, "installed bytes/modes changed")
        require(self.hash_files(self.helpers) == self.helper_hashes, "trusted helper bytes changed")
        require(self.wrapper.read_bytes() == WRAPPER.encode(), "wrapper changed")
        self.enter(self.payload)
        self.runner.check()
        self.evidence["postPreservation"] = True

    def stop(self, record, retain_namespace=False):
        cid = record["cid"]
        current = self.inspect(cid)
        require(current["Config"]["Labels"].get("telemetry.owner") == self.nonce
                and current["Name"] == "/" + record["name"], "cleanup ownership mismatch")
        if current["State"]["Running"]:
            self.docker("stop", "--time", "2", cid, seconds=5)
        terminal = self.inspect(cid)
        require(not terminal["State"]["Running"] and terminal["State"]["Pid"] == 0
                and not terminal["State"]["Restarting"], "container not terminal")
        require(terminal["RestartCount"] == record.get("restarts", 0), "cleanup lifecycle ambiguity")
        for fd in record["pidfds"]:
            require(bool(select.select([fd], [], [], 0)[0]), "descendant still live")
        if record["cgroup"] is not None:
            try:
                fd = self.own_fd(lambda: os.open("cgroup.events", os.O_RDONLY | os.O_CLOEXEC,
                                                dir_fd=record["groupfd"]))
                try:
                    events = os.read(fd, 4096).decode()
                finally:
                    self.release_fd(fd)
                require("populated 0\n" in events, "owned cgroup remains populated")
            except FileNotFoundError:
                require(not record["cgroup"].exists(), "cgroup evidence ambiguous")
        self.docker("rm", cid, seconds=4)
        remaining = self.docker("ps", "--all", "--quiet", "--no-trunc", "--filter", f"id={cid}")[0].strip()
        require(not remaining, "owned container remains")
        errors = []
        for fd in record["pidfds"]:
            attempt(errors, "container-pidfd-close", lambda fd=fd: self.release_fd(fd))
        record["pidfds"] = []
        if record.get("groupfd") is not None:
            attempt(errors, "container-cgroup-close", lambda: self.release_fd(record["groupfd"]))
            record["groupfd"] = None
        if record["nsfd"] is not None and not retain_namespace:
            attempt(errors, "container-namespace-close", lambda: self.release_fd(record["nsfd"]))
            record["nsfd"] = None
        with ownership_window():
            del self.containers[cid]
            self.evidence.setdefault("terminal", []).append({"cid": cid, "state": terminal["State"],
                                                             "descendantsGone": True, "removed": True,
                                                             "handleCleanupErrors": errors})
        require(not errors, "container handle cleanup:" + repr(errors))

    def remove_owned_root(self):
        if not self.root_created:
            return  # Includes mkdir collision: the existing path is NOT ours.
        self.runner.check()
        require(not self.containers and not self.pending_names and not self.runner.children,
                "live/uncertain resource still depends on owned root")
        require(self.root.parent == Path("/tmp") and self.root.name == "telemetry-web-owned-" + self.nonce
                and not self.root.is_symlink(), "root cleanup path uncertain")
        info = self.root.lstat()
        if self.root_fd is None:
            # Failure opening the just-created directory precedes ALL writes.
            # Exclusive mkdir was recorded; only remove an empty directory, never
            # recursively traverse a root for which no retained identity exists.
            require(self.root_identity is None and stat.S_ISDIR(info.st_mode)
                    and stat.S_IMODE(info.st_mode) == 0o700 and info.st_uid == os.geteuid(),
                    "partial root identity uncertain")
            self.root.rmdir()
        else:
            require(self.root_fd in self.owned_fds, "root descriptor ownership lost")
            retained = os.fstat(self.root_fd)
            identity = (retained.st_dev, retained.st_ino)
            require((info.st_dev, info.st_ino) == identity
                    and (self.root_identity is None or self.root_identity == identity),
                    "root cleanup identity changed")
            # The root FD/exclusive-create record, not a possibly partial owner
            # file, authorizes cleanup after any initialization write/copy fails.
            self.empty_owned_directory(self.root_fd)
            self.runner.check()
            require((self.root.lstat().st_dev, self.root.lstat().st_ino) == identity,
                    "root changed before final removal")
            self.root.rmdir()
        require(not self.root.exists(), "owned scratch remains")
        self.root_created = False

    def empty_owned_directory(self, directory_fd):
        # FD-relative, no symlink traversal, and an active deadline at every
        # entry. Unlike an opaque rmtree, this remains bounded when alarm delivery
        # is deferred during cleanup so other releases can still be attempted.
        self.runner.check()
        with os.scandir(directory_fd) as entries:
            for entry in entries:
                self.runner.check()
                if entry.is_dir(follow_symlinks=False):
                    fd = self.own_fd(lambda: os.open(entry.name, os.O_RDONLY | os.O_DIRECTORY
                                                    | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=directory_fd))
                    try:
                        self.empty_owned_directory(fd)
                    finally:
                        self.release_fd(fd)
                    self.runner.check()
                    os.rmdir(entry.name, dir_fd=directory_fd)
                else:
                    os.unlink(entry.name, dir_fd=directory_fd)

    @cleanup_window()
    def cleanup(self):
        interrupted = self.runner.interrupted
        errors = []
        self.evidence["cleanupErrors"] = errors

        def recover_pending(name, role):
            data = json_bytes(self.docker("ps", "--all", "--no-trunc", "--format", "{{json .}}",
                                           "--filter", f"name=^/{name}$")[0] or b"null")
            if data is not None:
                cid = data["ID"]
                actual = self.inspect(cid)
                require(actual["Name"] == "/" + name and
                        actual["Config"]["Labels"].get("telemetry.owner") == self.nonce and
                        actual["Config"]["Labels"].get("telemetry.role") == role, "uncertain create ownership")
                self.docker("stop", "--time", "2", cid, seconds=5)
                require(not self.inspect(cid)["State"]["Running"], "pending create still running")
                self.docker("rm", cid, seconds=4)
                remaining = self.docker("ps", "--all", "--quiet", "--no-trunc", "--filter", f"id={cid}")[0].strip()
                require(not remaining, "pending create remains")
            del self.pending_names[name]
            errors.append(f"ambiguous create retained failure:{name}")

        try:
            self.runner.interrupted = None
            self.runner.begin("cleanup")
            attempt(errors, "host-children", self.runner.cleanup_children)
            for name, role in list(self.pending_names.items()):
                attempt(errors, f"pending:{name}", lambda name=name, role=role: recover_pending(name, role))
            for record in list(self.containers.values()):
                attempt(errors, f"container:{record['cid']}", lambda record=record: self.stop(record))
            if self.host_ns is not None:
                attempt(errors, "host-namespace", lambda: require(ns_pair() == self.host_ns,
                                                                  "supervisor host namespace changed"))
        except BaseException as error:
            errors.append(f"cleanup-body:{type(error).__name__}:{error}")
        finally:
            # Independent cleanup continues after failure at ANY initialization
            # stage. Keep root identity until root removal, then close every FD.
            for listener in list(self.listeners):
                def close_listener(listener=listener):
                    with ownership_window():
                        self.listeners.remove(listener)
                        listener.close()
                attempt(errors, "listener-close", close_listener)
            attempt(errors, "host-children-final", self.runner.cleanup_children)
            attempt(errors, "root-remove", self.remove_owned_root)
            for fd in list(self.owned_fds):
                attempt(errors, f"fd-close:{fd}", lambda fd=fd: self.release_fd(fd))
            attempt(errors, "cleanup-budget", self.runner.check)
            self.evidence["interrupted"] = interrupted or self.runner.interrupted
            self.evidence["cleanup"] = not errors and not self.runner.children and not self.root_created
            attempt(errors, "alarm-disarm", lambda: signal.setitimer(signal.ITIMER_REAL, 0))
            if errors:
                self.evidence["cleanup"] = False

    def run(self):
        def interrupted(signum, _frame):
            self.runner.interrupted = signum
        error = None
        try:
            for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
                signal.signal(signum, interrupted)
            self.initialize()
            self.admission()
            self.acquire()
            self.inventory()
            self.d1()
            self.baseline()
            self.readback()
        except BaseException as exc:
            error = f"{type(exc).__name__}:{exc}"
        finally:
            # Freeze the original cause BEFORE cleanup. Cleanup errors have a
            # separate channel and can never replace it with a secondary error.
            self.evidence["error"] = error
            try:
                self.cleanup()
            except BaseException as exc:
                self.evidence.setdefault("cleanupErrors", []).append(f"{type(exc).__name__}:{exc}")
                self.evidence["cleanup"] = False
        accepted = (error is None and self.evidence["cleanup"] and self.evidence.get("interrupted") is None
                    and all(not record["cleanupErrors"] and record["terminal"] for record in self.runner.records))
        self.evidence["classification"] = "BASELINE_RED_CONFIRMED" if accepted else "ADMISSION_OR_BASELINE_FAILED"
        self.evidence["logSHA256"] = digest(self.runner.log)
        receipt = json.dumps(self.evidence, sort_keys=True)
        require(len(receipt.encode()) <= REPORT_LIMIT, "final report oversized")
        print("HOSTED_BASELINE_RECEIPT=" + receipt)
        return 0 if accepted else 2


def lifecycle_regression_artifacts():
    """UNEXECUTED synthetic regression suite; not called by any CLI/workflow path.

    Every process, signal, descriptor and filesystem operation below is a fake.
    Later separately authorized validation can load this suite; authoring/static
    parsing neither imports this module nor executes these controls.
    """
    from contextlib import ExitStack
    import io
    from types import SimpleNamespace
    import unittest
    from unittest.mock import Mock, patch

    class LifecycleCases(unittest.TestCase):
        def test_spawn_setup_and_reap_matrix(self):
            for fault in ("positive", "launch", "pidfd", "selector", "register",
                          "alarm-after-launch", "post-reap", "secondary-cleanup"):
                with self.subTest(fault=fault), ExitStack() as stack:
                    runner = Bounded()
                    clock, handlers, signals, closed = [100.0], {}, [], []
                    terminal = [fault in ("positive", "post-reap")]
                    initial = OSError("injected:" + fault)
                    process = SimpleNamespace(pid=424242, returncode=None, stdout=Mock())
                    selector = Mock()
                    selector.get_map.return_value = {}
                    if fault in ("register", "secondary-cleanup"):
                        selector.register.side_effect = initial
                    if fault == "secondary-cleanup":
                        selector.close.side_effect = OSError("secondary selector close")
                        process.stdout.close.side_effect = OSError("secondary pipe close")

                    def launch(*_args, **_kwargs):
                        self.assertTrue(runner.children)  # Ownership before Popen.
                        self.assertTrue(runner.records)
                        self.assertGreater(_OWNERSHIP_WINDOWS, 0)
                        if fault == "launch":
                            raise initial
                        if fault == "alarm-after-launch":
                            clock[0] = runner.deadline + 1
                            handlers[signal.SIGALRM](signal.SIGALRM, None)
                        return process

                    def pin(_pid):
                        self.assertIs(runner.children[0]["process"], process)
                        if fault == "pidfd":
                            raise initial
                        return 42

                    def terminate(identity, _signum):
                        self.assertFalse(runner.children[0]["reaped"])
                        signals.append(identity)
                        terminal[0] = True

                    def wait(_pid, _flags):
                        return (process.pid, 0) if terminal[0] else (0, 0)

                    stack.enter_context(patch.object(time, "monotonic", side_effect=lambda: clock[0]))
                    stack.enter_context(patch.object(signal, "signal", side_effect=lambda sig, fn: handlers.update({sig: fn})))
                    stack.enter_context(patch.object(signal, "setitimer"))
                    stack.enter_context(patch.object(subprocess, "Popen", side_effect=launch))
                    stack.enter_context(patch.object(os, "pidfd_open", side_effect=pin))
                    stack.enter_context(patch.object(os, "waitpid", side_effect=wait))
                    stack.enter_context(patch.object(os, "waitstatus_to_exitcode",
                                                     side_effect=initial if fault == "post-reap" else lambda _status: 0))
                    stack.enter_context(patch.object(os, "kill", side_effect=terminate))
                    stack.enter_context(patch.object(signal, "pidfd_send_signal", side_effect=terminate))
                    stack.enter_context(patch.object(os, "close", side_effect=closed.append))
                    stack.enter_context(patch.object(select, "select", return_value=([42], [], [])))
                    stack.enter_context(patch.object(selectors, "DefaultSelector",
                                                     side_effect=initial if fault == "selector" else lambda: selector))
                    stack.enter_context(patch.object(sys, "stdout", io.StringIO()))
                    runner.begin("d1")
                    if fault == "positive":
                        self.assertEqual(runner.run(["synthetic-leaf"]), (b"", 0))
                    else:
                        with self.assertRaises(Failure if fault == "alarm-after-launch" else OSError) as caught:
                            runner.run(["synthetic-leaf"])
                        if fault != "alarm-after-launch":
                            self.assertIs(caught.exception, initial)
                    self.assertEqual(runner.children, [])
                    self.assertTrue(runner.records[0]["terminal"])
                    if fault in ("positive", "post-reap", "launch"):
                        self.assertEqual(signals, [])
                    else:
                        self.assertEqual(signals, [process.pid if fault == "pidfd" else 42])
                    if fault not in ("launch", "pidfd"):
                        self.assertEqual(closed, [42])
                    if fault == "secondary-cleanup":
                        self.assertEqual(len(runner.records[0]["cleanupErrors"]), 2)

        def test_partial_initialization_and_collision(self):
            for stage in ("before-root", "mkdir-collision", "empty-root", "partial-files", "cleanup-error"):
                with self.subTest(stage=stage), ExitStack() as stack:
                    harness = Harness(100.0)
                    initial = OSError("initial:" + stage)
                    info = SimpleNamespace(st_dev=1, st_ino=2, st_mode=stat.S_IFDIR | 0o700, st_uid=0)
                    root = Mock(parent=Path("/tmp"))
                    root.name = "telemetry-web-owned-synthetic"
                    root.is_symlink.return_value = False
                    root.lstat.return_value = info
                    root.exists.return_value = False
                    harness.nonce = "synthetic"
                    harness.root = root
                    harness.empty_owned_directory = Mock()
                    listeners = [Mock(), Mock()]
                    closed = []

                    def initialize():
                        if stage not in ("before-root", "mkdir-collision"):
                            harness.root_created = True
                        if stage in ("partial-files", "cleanup-error"):
                            harness.root_fd = 88
                            harness.root_identity = (1, 2)
                            harness.owned_fds.update((88, 89))
                            harness.listeners.extend(listeners)
                        raise initial

                    def close(fd):
                        closed.append(fd)
                        if stage == "cleanup-error" and fd == 88:
                            raise OSError("secondary fd close")

                    if stage == "cleanup-error":
                        listeners[0].close.side_effect = OSError("secondary listener close")
                    harness.initialize = initialize
                    harness.admission = Mock(side_effect=AssertionError("must not progress"))
                    stack.enter_context(patch.object(signal, "signal"))
                    stack.enter_context(patch.object(signal, "setitimer"))
                    stack.enter_context(patch.object(time, "monotonic", return_value=100.0))
                    stack.enter_context(patch.object(os, "geteuid", return_value=0))
                    stack.enter_context(patch.object(os, "fstat", return_value=info))
                    stack.enter_context(patch.object(os, "close", side_effect=close))
                    stack.enter_context(patch.object(sys, "stdout", io.StringIO()))
                    self.assertEqual(harness.run(), 2)
                    self.assertEqual(harness.evidence["error"], "OSError:" + str(initial))
                    harness.admission.assert_not_called()
                    if stage in ("before-root", "mkdir-collision"):
                        root.rmdir.assert_not_called()
                    else:
                        root.rmdir.assert_called_once()
                    if stage in ("partial-files", "cleanup-error"):
                        self.assertEqual(set(closed), {88, 89})
                        listeners[1].close.assert_called_once()
                    if stage == "cleanup-error":
                        self.assertFalse(harness.evidence["cleanup"])
                        self.assertEqual(len(harness.evidence["cleanupErrors"]), 2)

        def test_fixed_leaf_exec_and_host_rejection(self):
            for host in ("9:9", "1:2"):
                with self.subTest(host=host), ExitStack() as stack:
                    events = []
                    stack.enter_context(patch.object(os, "geteuid", return_value=0))
                    stack.enter_context(patch.dict(globals(), pair=lambda _fd: ["1", "2"],
                                                   ns_pair=lambda: ["1", "2"]))
                    stack.enter_context(patch.object(os, "close", side_effect=lambda fd: events.append(("close", fd))))
                    def replace(executable, arguments, environment):
                        events.append(("exec", executable, arguments, environment))
                        raise SystemExit(0)  # Fake exec never launches a process.
                    stack.enter_context(patch.object(os, "execve", side_effect=replace))
                    args = SimpleNamespace(fd=42, expected="1:2", host=host, operation="lo-down")
                    with self.assertRaises(Failure if host == "1:2" else SystemExit):
                        entered(args)
                    if host == "1:2":
                        self.assertEqual(events, [])
                    else:
                        self.assertEqual(events, [("close", 42),
                            ("exec", IP, [IP, "link", "set", "dev", "lo", "down"], ENV)])

    return unittest.defaultTestLoader.loadTestsFromTestCase(LifecycleCases)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--bootstrap-started", type=float)
    parser.add_argument("--entered", action="store_true")
    parser.add_argument("--fd", type=int)
    parser.add_argument("--expected")
    parser.add_argument("--host")
    parser.add_argument("--operation", choices=tuple(NAMESPACE_ACTIONS))
    args = parser.parse_args()
    require(args.run != args.entered, "select one trusted operation")
    if args.entered:
        entered(args)
        return 0
    require(args.bootstrap_started is not None and 0 <= time.time() - args.bootstrap_started < 240,
            "missing/expired bootstrap admission clock")
    return Harness(args.bootstrap_started).run()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"HOSTED_HARNESS_FAILURE:{type(error).__name__}:{error}", file=sys.stderr)
        sys.exit(2)
