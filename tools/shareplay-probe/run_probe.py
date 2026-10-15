"""Feasibility test only: one VLC producer, three local consumers, no real provider.

This exercises remuxing and a bounded byte copy, not Apple's Journal transport.
Run on macOS after building the adjacent Swift package.
"""
import argparse
import base64
import contextlib
import http.server
import json
from pathlib import Path
import socket
import subprocess
import threading
import time
import urllib.error
import urllib.request

MAX_BYTES = 64 * 1024 * 1024
AUTH = 'Basic ' + base64.b64encode(b'probe:probe-only').decode()


def free_port():
    with socket.socket() as connection:
        connection.bind(('127.0.0.1', 0))
        return connection.getsockname()[1]


def fixture_files(root):
    root.mkdir(parents=True, exist_ok=True)
    base = root / 'movie.mp4'
    subprocess.run([
        'ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
        '-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=25',
        '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
        '-t', '28', '-c:v', 'libx264', '-preset', 'ultrafast',
        '-b:v', '8M', '-minrate', '8M', '-maxrate', '8M', '-bufsize', '8M',
        '-x264-params', 'nal-hrd=cbr:filler=1:keyint=50:min-keyint=50:scenecut=0',
        '-c:a', 'aac', '-b:a', '128k', '-movflags', '+faststart', str(base),
    ], check=True)
    for name in ('live.ts', 'movie.mkv'):
        subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
                        '-i', str(base), '-c', 'copy', str(root / name)], check=True)
    (root / 'hls').mkdir(exist_ok=True)
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
                    '-i', str(base), '-c', 'copy', '-hls_time', '2',
                    '-hls_playlist_type', 'vod', str(root / 'hls' / 'index.m3u8')], check=True)


class Provider(http.server.BaseHTTPRequestHandler):
    """Local test provider. The host marker is instrumentation, not authentication."""
    def log_message(self, *_):
        pass

    def do_GET(self):
        marker = self.headers.get('User-Agent', '')
        with self.server.guard:
            self.server.requests.append({'path': self.path, 'userAgent': marker,
                                         'range': self.headers.get('Range')})
        if marker != 'IPTVHostProbe/1':
            self.send_error(403)
            return
        name = self.path.split('?', 1)[0].lstrip('/')
        path = (self.server.root / name).resolve()
        if not path.is_relative_to(self.server.root) or not path.is_file():
            self.send_error(404)
            return
        size = path.stat().st_size
        start, end = 0, size - 1
        header = self.headers.get('Range')
        if header:
            try:
                first, last = header.removeprefix('bytes=').split('-', 1)
                start, end = int(first), int(last) if last else end
                if start < 0 or end < start or start >= size:
                    raise ValueError('range')
                end = min(end, size - 1)
            except ValueError:
                self.send_error(416)
                return
        self.send_response(206 if header else 200)
        self.send_header('Content-Length', str(end - start + 1))
        self.send_header('Accept-Ranges', 'bytes')
        if header:
            self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
        mime = 'application/vnd.apple.mpegurl' if path.suffix == '.m3u8' else (
            'video/mp2t' if path.suffix == '.ts' else 'video/mp4' if path.suffix == '.mp4' else 'video/x-matroska')
        self.send_header('Content-Type', mime)
        self.end_headers()
        with self.server.guard:
            self.server.active += 1
            self.server.peak = max(self.server.peak, self.server.active)
        try:
            with path.open('rb') as stream:
                stream.seek(start)
                remaining = end - start + 1
                while remaining:
                    data = stream.read(min(64 * 1024, remaining))
                    if not data:
                        break
                    self.wfile.write(data)
                    remaining -= len(data)
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            with self.server.guard:
                self.server.active -= 1


class CopyHub:
    def __init__(self):
        self.data = bytearray()
        self.guard = threading.Condition()
        self.done = False
        self.error = None
        self.first_byte = None
        self.eof = False

    def append(self, data):
        with self.guard:
            if len(self.data) + len(data) > MAX_BYTES:
                raise ValueError('64 MiB probe buffer exceeded')
            self.data.extend(data)
            if self.first_byte is None:
                self.first_byte = time.monotonic()
            self.guard.notify_all()

    def finish(self):
        with self.guard:
            self.done = True
            self.guard.notify_all()


class Consumer(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path not in ('/host.mkv', '/guest1.mkv', '/guest2.mkv'):
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header('Content-Type', 'video/x-matroska')
        self.end_headers()
        hub, offset = self.server.hub, 0
        try:
            while True:
                with hub.guard:
                    hub.guard.wait_for(lambda: len(hub.data) > offset or hub.done)
                    if len(hub.data) == offset and hub.done:
                        return
                    data = bytes(hub.data[offset:offset + 65536])
                self.wfile.write(data)
                offset += len(data)
        except (BrokenPipeError, ConnectionResetError):
            pass


def drain(url, hub, stop):
    deadline = time.monotonic() + 30
    try:
        while not stop.is_set():
            try:
                request = urllib.request.Request(url, headers={'Authorization': AUTH})
                with urllib.request.urlopen(request, timeout=30) as response:
                    while not stop.is_set():
                        data = response.read1(65536)
                        if not data:
                            hub.eof = True
                            return
                        hub.append(data)
                return
            except (urllib.error.URLError, TimeoutError, ConnectionError):
                if hub.data or time.monotonic() >= deadline:
                    raise
                stop.wait(0.1)
    except Exception as error:
        hub.error = str(error)
    finally:
        hub.finish()


def stop_process(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def check_producer(samples, exit_code, eof, seek):
    if exit_code not in (None, 0) or not samples or any(item['state'] == 'error' for item in samples):
        raise AssertionError('Producer failed during observation')
    if any(item.get('success') is False for item in samples):
        raise AssertionError('Producer reported failure')
    if eof and max(item['time'] for item in samples) < 26_000:
        raise AssertionError('Producer output ended before the 28-second fixture finished')
    if seek:
        requests = [item for item in samples if item['event'] == 'seekRequested']
        if len(requests) != 1:
            raise AssertionError('Expected one producer seek')
        request = requests[0]
        # The setter echoes the requested time immediately. Require later demux progress too.
        later = [item for item in samples if item['event'] == 'sample'
                 and item['elapsed'] >= request['elapsed'] + 2
                 and item['elapsed'] <= request['elapsed'] + 6]
        if not any(19_000 <= item['time'] <= 18_000 + (item['elapsed'] - request['elapsed']) * 1000 + 2000
                   and item['demuxReadBytes'] > request['demuxReadBytes']
                   for item in later):
            raise AssertionError('No observed playback and demux progress after seeking to 18 seconds')


def run_case(binary, name, path, provider, output):
    case = output / name
    case.mkdir()
    hub, stop = CopyHub(), threading.Event()
    with provider.guard:
        provider.requests = []
        provider.peak = 0
    producer_port = free_port()
    separator = '&' if '?' in path else '?'
    source_url = f'http://127.0.0.1:{provider.server_port}/{path}{separator}private=PROBE_ONLY_PROVIDER_SECRET'
    producer_url = f'http://127.0.0.1:{producer_port}/relay.mkv'
    started = time.monotonic()
    with contextlib.ExitStack() as resources:
        log = resources.enter_context((case / 'producer.jsonl').open('w'))
        errors = resources.enter_context((case / 'producer.stderr').open('w'))
        args = [str(binary), 'producer', source_url, str(producer_port), '45']
        if name == 'mp4-seek':
            args += ['12', '18']
        producer = subprocess.Popen(args, stdout=log, stderr=errors)
        resources.callback(stop_process, producer)
        resources.callback(hub.finish)
        resources.callback(stop.set)
        thread = threading.Thread(target=drain, args=(producer_url, hub, stop), daemon=True)
        thread.start()
        with hub.guard:
            hub.guard.wait_for(lambda: len(hub.data) >= 262144 or hub.done, timeout=32)
        if len(hub.data) < 262144:
            raise AssertionError(f'{name}: no usable remux bytes after 32s; {hub.error}')
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Consumer)
        server.daemon_threads = True
        server.hub = hub
        threading.Thread(target=server.serve_forever, daemon=True).start()
        resources.callback(server.server_close)
        resources.callback(server.shutdown)
        consumers = []
        duration = 18 if name == 'mp4-seek' else 12
        for who in ('host', 'guest1', 'guest2'):
            data = resources.enter_context((case / f'{who}.jsonl').open('w'))
            err = resources.enter_context((case / f'{who}.stderr').open('w'))
            url = f'http://127.0.0.1:{server.server_port}/{who}.mkv'
            consumer = subprocess.Popen([str(binary), 'consumer', url, str(duration)], stdout=data, stderr=err)
            resources.callback(stop_process, consumer)
            consumers.append(consumer)
        consumers_started = time.monotonic() - started
        # Diagnostics must not delay consumers while the finite fixture accumulates in the hub.
        listeners = subprocess.run(['lsof', '-nP', '-a', '-p', str(producer.pid),
                                    '-iTCP:' + str(producer_port), '-sTCP:LISTEN'],
                                   text=True, capture_output=True, check=True, timeout=10).stdout
        (case / 'listeners.txt').write_text(listeners)
        if '127.0.0.1:' not in listeners or '*:' in listeners:
            raise AssertionError('Producer must listen only on loopback')
        try:
            urllib.request.urlopen(producer_url, timeout=3)
        except urllib.error.HTTPError as error:
            if error.code != 401:
                raise
        else:
            raise AssertionError('Producer output is accessible without HTTP authentication')
        diagnostics_finished = time.monotonic() - started
        exits = [process.wait(timeout=duration + 10) for process in consumers]
        elapsed = time.monotonic() - started
        producer_exit = producer.poll()
        samples = [json.loads(line) for line in (case / 'producer.jsonl').read_text().splitlines(keepends=True)
                   if line.endswith('\n')]
        stop.set()
        hub.finish()
        with provider.guard:
            requests = list(provider.requests)
            peak = provider.peak
        result = {'case': name, 'consumerExits': exits, 'receivedBytes': len(hub.data),
                  'firstByteSeconds': hub.first_byte - started, 'elapsedSeconds': elapsed,
                  'consumersStartedSeconds': consumers_started,
                  'diagnosticsFinishedSeconds': diagnostics_finished,
                  'peakProviderHttpRequests': peak, 'providerRequests': requests,
                  'providerHttpRequestCount': len(requests),
                  'journalTransportTested': False, 'error': hub.error,
                  'producerExit': producer_exit, 'producerEOF': hub.eof}
        (case / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        if not requests or any(item['userAgent'] != 'IPTVHostProbe/1' for item in requests):
            raise AssertionError('Guest accessed provider, or producer never opened provider')
        if any(exits):
            raise AssertionError(f'{name}: one or more consumers failed to decode; {result}')
        if hub.error:
            raise AssertionError(hub.error)
        check_producer(samples, producer_exit, hub.eof, name == 'mp4-seek')
        if b'PROBE_ONLY_PROVIDER_SECRET' in hub.data:
            raise AssertionError('Provider URL marker leaked into remuxed media')
        if name != 'mp4-seek' and len(hub.data) > 1_016_000 * (elapsed + 4) * 1.4:
            raise AssertionError('VOD producer outran the real-time input clock')
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    root = args.output / 'fixtures'
    fixture_files(root)
    provider = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    provider.daemon_threads = True
    provider.root, provider.guard = root.resolve(), threading.Lock()
    provider.requests, provider.active, provider.peak = [], 0, 0
    threading.Thread(target=provider.serve_forever, daemon=True).start()
    results, failures = [], []
    try:
        for name, path in [('ts', 'live.ts'), ('hls', 'hls/index.m3u8'),
                           ('mp4', 'movie.mp4'), ('mkv', 'movie.mkv'),
                           ('catchup', 'live.ts?start=100&stop=200'), ('mp4-seek', 'movie.mp4')]:
            try:
                result = run_case(args.binary.resolve(), name, path, provider, args.output)
                results.append(result)
                print(f'{name}: local decode passed; provider requests {result["providerHttpRequestCount"]}; '
                      f'first byte {result["firstByteSeconds"]:.2f}s', flush=True)
            except Exception as error:
                failures.append({'case': name, 'error': str(error)})
                print(f'{name}: FAIL {error}', flush=True)
    finally:
        provider.shutdown()
        provider.server_close()
    summary = {'passed': results, 'failed': failures,
               'requestedFeatureReady': False,
               'limits': ['Local transport only: Apple Journal/FaceTime not exercised.',
                          'Host marker is instrumentation, not authentication.',
                          'One producer playback session; HLS/range requests may use several HTTP connections.',
                          'Basic H264/AAC fixtures; other codecs, track changes, and device backgrounding untested.']}
    (args.output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    raise SystemExit(bool(failures))


if __name__ == '__main__':
    main()
