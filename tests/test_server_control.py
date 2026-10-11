import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import server_control as control


class GracefulShutdownTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.config = self.root / 'Pal/Saved/Config/WindowsServer/PalWorldSettings.ini'
        self.config.parent.mkdir(parents=True)
        self.config.write_text('[/Script/Pal.PalGameWorldSettings]\n'
                               'OptionSettings=(RESTAPIEnabled=True,RESTAPIPort=8212,AdminPassword="fixture-secret")')
        self.paths = {'root': str(self.root)}
        self.target = {'pid': 41, 'path': str(self.root / 'PalServer.exe'), 'started_ticks': '10001'}
        self.clock = 0
        self.send = Mock()
        self.listener = {'LocalAddress': '127.0.0.1', 'LocalPort': 8212, 'OwningProcess': 41}
        self.shell = Mock(return_value=json.dumps([self.listener]))

    def sleep(self, n):
        self.clock += n

    def run_stop(self, processes):
        return control.graceful_stop(self.paths, [self.target], processes=processes,
            shell=self.shell, send=self.send, timeout=2, clock=lambda: self.clock, sleep=self.sleep)

    def test_acceptance_requires_process_exit_not_http_acceptance(self):
        processes = Mock(side_effect=[[self.target], [self.target], []])
        self.run_stop(processes)
        self.send.assert_called_once_with(8212, 'fixture-secret')
        self.assertEqual(processes.call_count, 3)

    def test_stubborn_process_is_left_running_and_fails(self):
        with self.assertRaisesRegex(RuntimeError, 'left running'):
            self.run_stop(lambda: [self.target])
        self.send.assert_called_once()
        self.assertNotIn('Stop-Process', self.shell.call_args.args[0])

    def test_other_listener_never_receives_credentials(self):
        foreign = {**self.listener, 'OwningProcess': 99}
        for owners in (json.dumps([foreign]), json.dumps([self.listener, foreign]),
                       '[]', '41', '[true]'):
            with self.subTest(owners=owners):
                self.shell.return_value = owners
                with self.assertRaises(RuntimeError): self.run_stop(lambda: [self.target])
                self.send.assert_not_called()

    def test_verify_listener_accepts_ipv4_and_optional_ipv6_loopback(self):
        for rows in ([self.listener], [self.listener, {**self.listener, 'LocalAddress': '::1'}]):
            with self.subTest(rows=rows):
                self.shell.return_value = json.dumps(rows)
                self.assertEqual(control.verify_listener(8212, [self.target], self.shell), rows)
        command = self.shell.call_args.args[0]
        self.assertIn('Select-Object LocalAddress,LocalPort,OwningProcess', command)
        self.assertNotIn('-ExpandProperty', command)
        self.send.assert_not_called()

    def test_exposed_listener_refused_even_with_valid_loopback(self):
        for address in ('0.0.0.0', '::', '192.168.1.10', '2001:db8::1'):
            for mixed in (False, True):
                with self.subTest(address=address, mixed=mixed):
                    rows = ([self.listener] if mixed else []) + [{**self.listener, 'LocalAddress': address}]
                    self.shell.return_value = json.dumps(rows)
                    with self.assertRaises(RuntimeError):
                        self.run_stop(lambda: [self.target])
                    self.send.assert_not_called()

    def test_explicit_ipv4_destination_required(self):
        for address in ('::1', '127.0.0.2'):
            with self.subTest(address=address):
                self.shell.return_value = json.dumps([{**self.listener, 'LocalAddress': address}])
                with self.assertRaises(RuntimeError):
                    self.run_stop(lambda: [self.target])
                self.send.assert_not_called()

    def test_mismatched_or_malformed_listener_fields_refused(self):
        invalid = [
            {**self.listener, 'LocalPort': port} for port in (8213, '8212', True, None)
        ] + [
            {**self.listener, 'LocalAddress': address} for address in ('localhost', '', None, 123)
        ] + [
            {**self.listener, 'OwningProcess': pid} for pid in ('41', True, None)
        ] + [
            {key: value for key, value in self.listener.items() if key != missing}
            for missing in self.listener
        ]
        for row in invalid:
            with self.subTest(row=row):
                self.shell.return_value = json.dumps([self.listener, row])
                with self.assertRaises(RuntimeError):
                    self.run_stop(lambda: [self.target])
                self.send.assert_not_called()

    def test_verify_listener_rejects_invalid_port_before_shell(self):
        for port in (0, 65536, True, '8212; unwanted'):
            with self.subTest(port=port):
                with self.assertRaises(ValueError):
                    control.verify_listener(port, [self.target], self.shell)
                self.shell.assert_not_called()

    def test_recycled_pid_before_request_refused(self):
        replacement = {**self.target, 'started_ticks': '10002'}
        with self.assertRaisesRegex(RuntimeError, 'identity changed'):
            self.run_stop(lambda: [replacement])
        self.send.assert_not_called()

    def test_restart_after_request_is_not_shutdown_success(self):
        replacement = {**self.target, 'started_ticks': '10002'}
        with self.assertRaisesRegex(RuntimeError, 'identity changed'):
            self.run_stop(Mock(side_effect=[[self.target], [replacement]]))
        self.send.assert_called_once()

    def test_post_request_enumeration_failure_is_not_success(self):
        with self.assertRaisesRegex(RuntimeError, 'enumeration failed'):
            self.run_stop(Mock(side_effect=[[self.target], RuntimeError('enumeration failed')]))

    def test_disabled_missing_ambiguous_config_never_sends(self):
        original = self.config.read_text()
        for text in (original.replace('True', 'False'), original.replace('8212', '0'),
                     original.replace('fixture-secret', ''), original + '\nRESTAPIEnabled=True'):
            with self.subTest(text=text):
                self.config.write_text(text)
                with self.assertRaises(ValueError): self.run_stop(lambda: [self.target])
                self.send.assert_not_called()
                self.shell.assert_not_called()

    def test_transport_stays_loopback_without_proxy_or_redirect(self):
        response = Mock(status=200)
        opener = Mock()
        opener.open.return_value.__enter__ = Mock(return_value=response)
        opener.open.return_value.__exit__ = Mock(return_value=False)
        with patch.object(control.urllib.request, 'build_opener', return_value=opener) as build:
            control.send_shutdown(8212, 'fixture-secret')
        request = opener.open.call_args.args[0]
        self.assertEqual(request.full_url, 'http://127.0.0.1:8212/v1/api/shutdown')
        self.assertEqual(request.method, 'POST')
        self.assertEqual(build.call_args.args[0].proxies, {})
        self.assertIsInstance(build.call_args.args[1], control.NoRedirect)
        with self.assertRaises(RuntimeError):
            build.call_args.args[1].redirect_request(None,None,302,'',{},'https://elsewhere.invalid')

    def test_transport_error_is_sanitized_and_not_retried(self):
        opener = Mock()
        opener.open.side_effect = RuntimeError('fixture-secret untrusted error')
        with patch.object(control.urllib.request, 'build_opener', return_value=opener):
            with self.assertRaises(RuntimeError) as caught:
                control.send_shutdown(8212, 'fixture-secret')
        self.assertNotIn('fixture-secret', str(caught.exception))
        opener.open.assert_called_once()

    def test_inactive_or_malformed_configuration_never_sends(self):
        original = self.config.read_text()
        for text in (
            original.replace('OptionSettings=', ';OptionSettings='),
            original.replace('/Script/Pal.PalGameWorldSettings', 'OtherSection'),
            original.replace('RESTAPIPort=8212,', '').replace(
                'fixture-secret', 'fixture-secret,RESTAPIPort=8212'),
            original.replace('"fixture-secret"', '"fixture-secret"junk'),
            original.replace('"fixture-secret"', '"fixture-secret'),
            original.replace('RESTAPIPort=8212', 'RESTAPIPort="8212"junk'),
        ):
            with self.subTest(text=text):
                self.config.write_text(text)
                with self.assertRaises(ValueError):
                    self.run_stop(lambda: [self.target])
                self.send.assert_not_called()
                self.shell.assert_not_called()

    def test_quoted_field_names_are_password_data(self):
        secret = 'fixture-secret,RESTAPIPort=9999,RESTAPIEnabled=False'
        self.config.write_text(self.config.read_text().replace('fixture-secret', secret))
        self.run_stop(Mock(side_effect=[[self.target], []]))
        self.send.assert_called_once_with(8212, secret)

    def test_real_like_config_with_nested_crossplay_platforms(self):
        self.config.write_text(
            '[/Script/Pal.PalGameWorldSettings]\n'
            'OptionSettings=(Difficulty=None,DayTimeSpeedRate=1.000000,'
            'ServerName="Local test",ServerDescription="text (with commas, too)",'
            'CrossplayPlatforms=(Steam,Xbox,PS5,Mac),RESTAPIEnabled=True,'
            'RESTAPIPort=8212,AdminPassword="fixture-secret",'
            'Extra=(Nested=(RESTAPIPort=9999,AdminPassword="decoy"),'
            'Text="escaped \\" quote, RESTAPIEnabled=False"),bIsPvP=False)')
        self.run_stop(Mock(side_effect=[[self.target], []]))
        self.send.assert_called_once_with(8212, 'fixture-secret')

    def test_empty_unquoted_unrelated_fields_allow_disabled_config(self):
        for unrelated in ('DenyTechnologyList=,Other= ', 'Other= ,DenyTechnologyList='):
            with self.subTest(unrelated=unrelated):
                self.config.write_text(
                    '[/Script/Pal.PalGameWorldSettings]\n'
                    'OptionSettings=(CrossplayPlatforms=(Steam,Xbox,PS5,Mac),'
                    'RESTAPIEnabled=False,RESTAPIPort=8212,AdminPassword="",' + unrelated + ')')
                with self.assertRaisesRegex(ValueError, '^local REST shutdown is disabled; refusing force termination$'):
                    self.run_stop(lambda: [self.target])
                self.send.assert_not_called()
                self.shell.assert_not_called()

    def test_empty_unrelated_fields_preserve_required_field_validation(self):
        original = self.config.read_text()
        self.config.write_text(original[:-1] + ',DenyTechnologyList=)')
        self.assertEqual(control.rest_config(self.root), (8212, 'fixture-secret'))
        for field in ('RESTAPIEnabled=True', 'RESTAPIPort=8212', 'AdminPassword="fixture-secret"'):
            with self.subTest(field=field):
                self.config.write_text(original.replace(field, field.split('=')[0] + '=')[:-1]
                                       + ',DenyTechnologyList=)')
                with self.assertRaises(ValueError):
                    self.run_stop(lambda: [self.target])
                self.send.assert_not_called()
                self.shell.assert_not_called()

    def test_nested_fields_cannot_supply_shutdown_configuration(self):
        original = self.config.read_text()
        for field in ('RESTAPIEnabled=True', 'RESTAPIPort=8212', 'AdminPassword="fixture-secret"'):
            with self.subTest(field=field):
                self.config.write_text(original.replace(field, 'Extra=(' + field + ')'))
                with self.assertRaises(ValueError):
                    self.run_stop(lambda: [self.target])
                self.send.assert_not_called()
                self.shell.assert_not_called()

    def test_unbalanced_or_malformed_nested_values_are_refused(self):
        original = self.config.read_text()
        for value in ('(Steam,Xbox', '(Steam,Xbox))', '(Steam)junk',
                      '(Text="unterminated)', '(Nested=(Steam)'):
            with self.subTest(value=value):
                self.config.write_text(original[:-1] + ',Extra=' + value + ')')
                with self.assertRaises(ValueError):
                    self.run_stop(lambda: [self.target])
                self.send.assert_not_called()
                self.shell.assert_not_called()

    def test_shutdown_fields_cannot_be_nested_values(self):
        original = self.config.read_text()
        for value in ('RESTAPIEnabled=True', 'RESTAPIPort=8212', 'AdminPassword="fixture-secret"'):
            name, scalar = value.split('=', 1)
            with self.subTest(field=name):
                self.config.write_text(original.replace(value, name + '=(' + scalar + ')'))
                with self.assertRaises(ValueError):
                    self.run_stop(lambda: [self.target])
                self.send.assert_not_called()

    def test_commented_settings_do_not_override_active_settings(self):
        self.config.write_text(';RESTAPIEnabled=False\n;AdminPassword="old"\n' + self.config.read_text())
        self.run_stop(Mock(side_effect=[[self.target], []]))
        self.send.assert_called_once_with(8212, 'fixture-secret')

    def test_transport_setup_exception_is_sanitized(self):
        with patch.object(control.urllib.request, 'build_opener', side_effect=RuntimeError('fixture-secret')):
            with self.assertRaises(RuntimeError) as caught:
                control.send_shutdown(8212, 'fixture-secret')
        self.assertNotIn('fixture-secret', str(caught.exception))

    def test_invalid_password_encoding_is_sanitized(self):
        with patch.object(control.urllib.request, 'build_opener') as build:
            with self.assertRaises(RuntimeError) as caught:
                control.send_shutdown(8212, 'fixture-secret\ud800')
        self.assertNotIn('fixture-secret', str(caught.exception))
        build.assert_not_called()

    def test_invalid_transport_port_cannot_change_destination(self):
        for port in ('8212@elsewhere.invalid', True, 0, 65536):
            with self.subTest(port=port), patch.object(control.urllib.request, 'build_opener') as build:
                with self.assertRaises(RuntimeError):
                    control.send_shutdown(port, 'fixture-secret')
                build.assert_not_called()

    def test_invalid_settings_fail_before_owner_query(self):
        original = self.config.read_text()
        for text in (
            original.replace('8212', '9' * 5000),
            original.replace('8212', '\u00b2'),
            original.replace('8212', '65536'),
            original.replace('8212', '8212,restapiport=8213'),
            original + '\n' + original,
            original.replace('OptionSettings=', '+OptionSettings='),
            original.replace('fixture-secret', 'fixture\\secret'),
            original.replace('fixture-secret', 'fixture\x7fsecret'),
        ):
            with self.subTest(case=text[:80]):
                self.config.write_text(text)
                with self.assertRaises(ValueError):
                    self.run_stop(lambda: [self.target])
                self.send.assert_not_called()
                self.shell.assert_not_called()

    def test_invalid_config_encoding_fails_without_send(self):
        self.config.write_bytes(b'fixture-secret\xff')
        with self.assertRaises(ValueError) as caught:
            self.run_stop(lambda: [self.target])
        self.assertNotIn('fixture-secret', str(caught.exception))
        self.send.assert_not_called()
        self.shell.assert_not_called()

    def test_changed_executable_before_request_refused(self):
        replacement = {**self.target, 'path': str(self.root / 'other.exe')}
        with self.assertRaisesRegex(RuntimeError, 'identity changed'):
            self.run_stop(lambda: [replacement])
        self.send.assert_not_called()

    def test_missing_process_before_request_refused(self):
        with self.assertRaisesRegex(RuntimeError, 'identity changed'):
            self.run_stop(lambda: [])
        self.send.assert_not_called()

    def test_listener_query_failure_never_sends(self):
        for failure in (RuntimeError('enumeration failed'), 'not JSON', '{}'):
            with self.subTest(failure=failure):
                self.shell.side_effect = failure if isinstance(failure, Exception) else None
                self.shell.return_value = failure
                with self.assertRaises((RuntimeError, ValueError)):
                    self.run_stop(lambda: [self.target])
                self.send.assert_not_called()

    def test_no_targets_requires_no_config_or_network(self):
        self.config.unlink()
        processes = Mock()
        control.graceful_stop(self.paths, [], processes=processes, shell=self.shell, send=self.send)
        processes.assert_not_called()
        self.shell.assert_not_called()
        self.send.assert_not_called()


if __name__ == '__main__': unittest.main()
