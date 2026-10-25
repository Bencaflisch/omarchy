#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
require_command python3

if [[ -z ${OMARCHY_SPEEDTEST_BINARY:-} ]]; then
  skip "native speed-test checks need OMARCHY_SPEEDTEST_BINARY pointing to a built helper"
  exit 0
fi

python3 <<'PY'
import concurrent.futures
import http.server
import json
import os
import pathlib
import shlex
import signal
import sys
import subprocess
import tempfile
import threading
import time
import urllib.request
from urllib.parse import parse_qs, urlsplit

root = pathlib.Path(os.environ['ROOT'])
connections = int(os.environ.get("OMARCHY_SPEEDTEST_CONNECTIONS", "8"))
helper = os.environ.get('SPEEDTEST_HELPER_UNDER_TEST', str(root / 'bin/omarchy-network-speedtest'))
lock = threading.Lock()
records = []
measured_start = None
measured_end = None
request_sizes = []
noise_bytes = 0
bad_ack = False
broken_down = False
download_delay = 0.015
download_chunk = 65536
fixed_latency = 0.0

class Handler(http.server.BaseHTTPRequestHandler):
  protocol_version = 'HTTP/1.1'
  def log_message(self, *_):
    pass
  def handle(self):
    try:
      super().handle()
    except (BrokenPipeError, ConnectionResetError):
      pass
  def do_GET(self):
    global noise_bytes, measured_start, measured_end
    path = urlsplit(self.path)
    time.sleep(fixed_latency)
    if path.path == '/latency':
      self.send_response(204)
      self.end_headers()
      return
    noise = path.path == '/noise'
    size = 8388608 if noise else int(parse_qs(path.query)['bytes'][0])
    measured = self.headers.get('X-Speedtest-Phase') == 'measure'
    if not noise and measured:
      with lock:
        request_sizes.append(size)
        measured_start = time.monotonic() if measured_start is None else measured_start
    self.send_response(200)
    self.send_header('Content-Length', str(size))
    self.end_headers()
    sent = 0
    try:
      limit = size // 2 if broken_down and not noise else size
      while sent < limit:
        chunk = bytes(min(65536 if noise else download_chunk, limit - sent))
        self.wfile.write(chunk)
        self.wfile.flush()
        sent += len(chunk)
        with lock:
          if noise:
            noise_bytes += len(chunk)
          elif measured:
            records.append(('down', len(chunk)))
            measured_end = time.monotonic()
        time.sleep(0.006 if noise else download_delay)
      if broken_down and not noise:
        self.close_connection = True
    except (BrokenPipeError, ConnectionResetError):
      self.close_connection = True
  def do_POST(self):
    global measured_start, measured_end
    measured = self.headers.get("X-Speedtest-Phase") == "measure"
    if measured:
      with lock:
        measured_start = time.monotonic() if measured_start is None else measured_start
    time.sleep(fixed_latency)
    size = int(self.headers['Content-Length'])
    received = 0
    while received < size:
      chunk = self.rfile.read(min(65536, size - received))
      if not chunk:
        self.close_connection = True
        return
      received += len(chunk)
      time.sleep(0.015)
    body = json.dumps({'acceptedBytes' if self.path == '/upload' else 'bytes': received - 1 if bad_ack else received}).encode()
    if measured:
      with lock:
        records.append(('up', received))
        measured_end = time.monotonic()
    try:
      self.send_response(200)
      self.send_header('Content-Length', str(len(body)))
      self.end_headers()
      self.wfile.write(body)
      self.wfile.flush()
    except (BrokenPipeError, ConnectionResetError):
      self.close_connection = True

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
server.daemon_threads = True
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f'http://127.0.0.1:{server.server_port}'
env = dict(os.environ, OMARCHY_PATH=str(root), OMARCHY_SPEEDTEST_URL=base)

def launch(direction):
  return subprocess.Popen([helper, direction], env=env, stdout=subprocess.PIPE,
    stderr=subprocess.PIPE, text=True)

def run(direction):
  proc = launch(direction)
  out, err = proc.communicate(timeout=15)
  assert proc.returncode == 0, (direction, out, err)
  values = [float(line) for line in out.splitlines()]
  assert len(values) > 2 and all(value >= 0 for value in values), out
  return values[-1]

def noise(stop):
  while not stop.is_set():
    try:
      with urllib.request.urlopen(base + '/noise', timeout=3) as response:
        while not stop.is_set() and response.read(65536):
          pass
    except (OSError, ValueError):
      return

try:
  for direction in ('down', 'up'):
    with lock:
      records.clear()
      noise_bytes = 0
      measured_start = measured_end = None
    stop = threading.Event()
    background = threading.Thread(target=noise, args=(stop,), daemon=True)
    background.start()
    started = time.monotonic()
    measured = run(direction)
    elapsed = time.monotonic() - started
    stop.set()
    background.join(timeout=3)
    with lock:
      transferred = sum(size for kind, size in records if kind == direction)
      elapsed = measured_end - measured_start
      background_bytes = noise_bytes
    expected = transferred * 8 / elapsed / 1_000_000
    assert expected > 0 and 0.8 * expected <= measured <= 1.2 * expected, (measured, expected)
    assert background_bytes > transferred / 4, (background_bytes, transferred)
    print(f'ok - {direction} counts only test payloads despite unrelated traffic', flush=True)

  download_delay = 0.24
  run('down')
  download_delay = 0.015
  print('ok - slow healthy downloads are not defeated by payload growth', flush=True)

  download_chunk = 1024
  download_delay = 0.07
  run('down')
  download_chunk = 65536
  download_delay = 0.015
  print('ok - minimum payload is not started when it cannot finish', flush=True)

  fixed_latency = 0.05
  download_delay = 0.0
  with lock:
    request_sizes.clear()
  run('down')
  with lock:
    assert any(size >= 1048576 for size in request_sizes), 'fast latent links grow past 64 KiB'
  fixed_latency = 0.0
  download_delay = 0.015
  print('ok - fixed request latency does not prevent connection saturation', flush=True)

  bad_ack = True
  proc = launch('up')
  out, err = proc.communicate(timeout=8)
  assert proc.returncode != 0 and 'acknowledge' in err, (out, err)
  bad_ack = False
  print('ok - uploads require exact server acknowledgement', flush=True)

  broken_down = True
  proc = launch('down')
  out, err = proc.communicate(timeout=8)
  assert proc.returncode != 0 and ('[18]' in err or 'Incomplete' in err), (out, err)
  broken_down = False
  print('ok - truncated downloads fail instead of producing a result', flush=True)

  for hard in (False, True):
    proc = launch('up')
    assert proc.stdout.readline().strip(), 'helper reached measurement'
    children = subprocess.run(['ps', '-eo', 'pid=,ppid='], text=True, capture_output=True, check=True).stdout
    assert not any(int(line.split()[1]) == proc.pid for line in children.splitlines()), 'helper has no child transfer processes'
    proc.kill() if hard else proc.terminate()
    proc.communicate(timeout=3)
    assert proc.returncode != 0, "external cancellation is not success"
    print(f'ok - {"SIGKILL" if hard else "SIGTERM"} cannot leave child transfer workers', flush=True)
  with tempfile.TemporaryDirectory() as temporary:
    temporary = pathlib.Path(temporary)
    marker = temporary / 'waiting'
    release = temporary / 'release'
    shim = temporary / 'held-speedtest'
    shim.write_text('#!/bin/bash\n' + f'touch {shlex.quote(str(marker))}\n' +
      f'while [[ ! -e {shlex.quote(str(release))} ]]; do sleep 0.01; done\n' +
      f'exec {shlex.quote(env["OMARCHY_SPEEDTEST_BINARY"])} "$@"\n')
    shim.chmod(0o755)
    held_env = dict(env, OMARCHY_SPEEDTEST_BINARY=str(shim))
    parent = subprocess.Popen(['bash', '-c', '"$1" up & echo $!; wait', 'bash', helper],
      env=held_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    child_pid = int(parent.stdout.readline())
    try:
      deadline = time.monotonic() + 3
      while not marker.exists() and time.monotonic() < deadline:
        time.sleep(0.01)
      assert marker.exists(), 'native startup held before network access'
      with lock:
        before = len(records)
      parent.kill()
      release.touch()
      parent.communicate(timeout=3)
      with lock:
        assert len(records) == before, 'orphan never opened a test connection'
      print('ok - parent death during native startup prevents network access', flush=True)
    finally:
      parent.kill() if parent.poll() is None else None
      try:
        os.kill(child_pid, signal.SIGKILL)
      except ProcessLookupError:
        pass
finally:
  server.shutdown()
  server.server_close()
PY
