"""CLI contract tests without opening a real app or writing real user data."""
import contextlib
import io
import json
from pathlib import Path
import runpy
import struct
import sys
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[2] / 'agents/AgentSupport/revclip/scripts/revclip'
MODULE = runpy.run_path(str(SCRIPT))


class SocketProbe:
    def __init__(self):
        payload = json.dumps({'ok': True, 'result': {'values': {'max_history_size': 30}}}).encode()
        self.incoming = bytearray(struct.pack('!I', len(payload)) + payload)
        self.sent = b''
    def __enter__(self): return self
    def __exit__(self, *args): pass
    def settimeout(self, value): self.timeout = value
    def connect(self, path): self.path = path
    def sendall(self, data): self.sent += data
    def recv(self, length):
        result = bytes(self.incoming[:min(length, 3)])
        del self.incoming[:len(result)]
        return result


class CLIContractTests(unittest.TestCase):
    def invoke(self, arguments):
        probe = SocketProbe()
        class Stat:
            st_mode = 0o140600
            st_uid = MODULE['os'].getuid()
        with patch.object(sys, 'argv', ['revclip', *arguments]), \
             patch.object(Path, 'lstat', return_value=Stat()), \
             patch.object(MODULE['socket'], 'socket', return_value=probe), \
             contextlib.redirect_stdout(io.StringIO()) as output:
            result = MODULE['main']()
        size = struct.unpack('!I', probe.sent[:4])[0]
        self.assertEqual(size, len(probe.sent[4:]))
        return result, json.loads(probe.sent[4:]), probe, json.loads(output.getvalue())

    def test_settings_json_typed_values_and_explicit_target(self):
        result, request, probe, response = self.invoke(['--app','Revclip','settings-set','--json','{"max_history_size":30,"auto_expiry_enabled":false}'])
        self.assertEqual(result, 0)
        self.assertEqual(request, {'op':'settings-set','values':{'max_history_size':30,'auto_expiry_enabled':False}})
        self.assertTrue(probe.path.endswith('/Revclip/cli.sock'))
        self.assertTrue(response['ok'])

    def test_get_key_and_action(self):
        self.assertEqual(self.invoke(['settings-get','--key','appearance'])[1], {'op':'settings-get','key':'appearance'})
        self.assertEqual(self.invoke(['app-action','permissions'])[1], {'op':'app-action','action':'permissions'})

    def test_legacy_default_still_demo(self):
        self.assertTrue(self.invoke(['folders'])[2].path.endswith('/revclip-demo/cli.sock'))

    def test_report_explicit_consent_and_transport_deadline(self):
        _, request, probe, _ = self.invoke(['--app','Revclip','bug-report','--title','Bug','--description','Steps','--consent-source-info'])
        self.assertEqual(request, {'op':'bug-report','title':'Bug','description':'Steps','contact':'','source_info_consent':True})
        self.assertEqual(probe.timeout,25)

    def test_report_without_consent_never_connects(self):
        with patch.object(sys,'argv',['revclip','bug-report','--title','Bug','--description','Steps']), patch.object(MODULE['socket'],'socket') as socket, contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit): MODULE['main']()
            socket.assert_not_called()

    def test_report_rejects_empty_and_overlong_before_connecting(self):
        for text in (' ', 'x'*2501, '😀'*1251):
            with patch.object(sys,'argv',['revclip','bug-report','--title','Bug','--description',text,'--consent-source-info']), patch.object(MODULE['socket'],'socket') as socket:
                with self.assertRaises(ValueError): MODULE['main']()
                socket.assert_not_called()

    def test_invalid_settings_stop_before_connecting(self):
        for value in ['[]','null','{}','{"x":NaN}','{"x":1,"x":2}']:
            with self.subTest(value=value), patch.object(sys,'argv',['revclip','settings-set','--json',value]), patch.object(MODULE['socket'],'socket') as socket:
                with self.assertRaises(ValueError): MODULE['main']()
                socket.assert_not_called()

    def test_title_only_does_not_include_body(self):
        request = self.invoke(['update','example','--title','New title'])[1]
        self.assertEqual(request, {'op':'update','id':'example','title':'New title'})

    def test_short_read_reports_closed_connection(self):
        probe = SocketProbe()
        probe.incoming.clear()
        with self.assertRaises(ConnectionError): MODULE['receive'](probe,4)


if __name__ == '__main__': unittest.main()
