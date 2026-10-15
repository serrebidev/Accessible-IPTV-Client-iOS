"""Regression checks for probe false positives; no native media dependency."""
import threading
import unittest
from unittest.mock import patch
import urllib.error

from run_probe import CopyHub, check_producer, drain


def sample(elapsed=1, time=1000, event='sample', demux=100, state='playing', **extra):
    return dict(elapsed=elapsed, time=time, event=event, demuxReadBytes=demux, state=state, **extra)


class ProbeChecks(unittest.TestCase):
    def test_running_producer_and_complete_fixture(self):
        check_producer([sample()], None, False, False)
        check_producer([sample(time=27000)], 0, True, False)

    def test_producer_failure_and_truncated_fixture(self):
        for samples, code, eof in [([], None, False), ([sample()], 1, False),
                                    ([sample(state='error')], None, False),
                                    ([sample(success=False)], 0, False), ([sample()], None, True)]:
            with self.subTest(samples=samples, code=code, eof=eof):
                with self.assertRaises(AssertionError):
                    check_producer(samples, code, eof, False)

    def test_seek_requires_later_native_time_and_demux_progress(self):
        request = sample(elapsed=12, time=18000, event='seekRequested')
        check_producer([request, sample(elapsed=15, time=20000, demux=200)], None, False, True)
        for later in [[], [sample(elapsed=12.1, time=18000)],
                      [sample(elapsed=15, time=15000, demux=200)],
                      [sample(elapsed=15, time=26000, demux=200)],
                      [sample(elapsed=15, time=20000, demux=100)],
                      [sample(elapsed=20, time=20000, demux=200)]]:
            with self.subTest(later=later), self.assertRaises(AssertionError):
                check_producer([request] + later, None, False, True)

    def test_midstream_error_never_retries_and_splices_streams(self):
        hub = CopyHub()

        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *_):
                pass

            def read1(self, _):
                if not hub.data:
                    return b'first Matroska prefix'
                raise urllib.error.URLError('connection lost')

        with patch('run_probe.urllib.request.urlopen', return_value=Response()) as opened:
            drain('http://127.0.0.1:12345/relay.mkv', hub, threading.Event())
        self.assertEqual(opened.call_count, 1)
        self.assertEqual(hub.data, b'first Matroska prefix')
        self.assertTrue(hub.done)
        self.assertIsNotNone(hub.error)
        self.assertFalse(hub.eof)


if __name__ == '__main__':
    unittest.main()
