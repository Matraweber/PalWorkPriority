"""Graceful shutdown of an already configured local test server, never force kill.

Uses Palworld's /v1/api/shutdown. Does not enable REST, change passwords, or
contact remote servers. Process ownership must be proved before sending secrets.
"""
import base64
import ipaddress
import json
import re
import time
import urllib.request
from pathlib import Path


def _value_end(body, start):
    """Skip one scalar, quoted string or balanced tuple without reading its fields."""
    def quoted_end(pos):
        pos += 1
        while pos < len(body):
            if body[pos] == '\\':
                pos += 2  # Escaped quotes cannot expose commas or parentheses.
            elif body[pos] == '"':
                return pos + 1
            else:
                pos += 1
        raise ValueError('unterminated local shutdown configuration string')

    if start >= len(body) or body[start] == ',':
        return start  # Unreal permits empty unquoted values, e.g. DenyTechnologyList=.
    if body[start] == '"':
        return quoted_end(start)
    if body[start] == '(':
        depth, pos = 1, start + 1
        while pos < len(body):
            if body[pos] == '"':
                pos = quoted_end(pos)
                continue
            if body[pos] == '(':
                depth += 1
            elif body[pos] == ')':
                depth -= 1
                if depth == 0:
                    return pos + 1
            pos += 1
        raise ValueError('unbalanced local shutdown configuration tuple')
    match = re.match(r'[^",()\r\n]+', body[start:])
    if not match:
        raise ValueError('malformed local shutdown configuration value')
    return start + match.end()


def rest_config(root):
    path = Path(root) / 'Pal/Saved/Config/WindowsServer/PalWorldSettings.ini'
    try:
        text = path.read_text(encoding='utf-8-sig')
    except (OSError, UnicodeError):
        raise ValueError('local shutdown configuration could not be read') from None
    # Read one active Unreal settings tuple, not field-like text in comments,
    # other sections or quoted passwords. Unsupported syntax fails closed.
    section, options = None, []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith((';', '#')):
            continue
        if line.startswith('['):
            section = line.casefold()
            continue
        if section != '[/script/pal.palgameworldsettings]':
            continue
        key, sep, value = line.partition('=')
        key = key.strip().casefold()
        if key in {'restapienabled', 'restapiport', 'adminpassword'}:
            raise ValueError('local shutdown fields must be inside OptionSettings')
        if key.lstrip('+-.!') == 'optionsettings':
            if key != 'optionsettings' or not sep:
                raise ValueError('unsupported local shutdown configuration')
            options.append(value.strip())
    if len(options) != 1 or not options[0].startswith('(') or not options[0].endswith(')'):
        raise ValueError('missing or ambiguous local shutdown OptionSettings')
    body, fields, pos = options[0][1:-1], {}, 0
    token = re.compile(r'\s*([A-Za-z_][A-Za-z_0-9]*)\s*=\s*')
    while pos < len(body):
        match = token.match(body, pos)
        if not match:
            raise ValueError('malformed local shutdown OptionSettings')
        end = _value_end(body, match.end())
        name, value = match[1].casefold(), body[match.end():end].strip()
        pos = end
        while pos < len(body) and body[pos].isspace():
            pos += 1
        if pos < len(body):
            if body[pos] != ',' or not body[pos + 1:].strip():
                raise ValueError('malformed local shutdown OptionSettings')
            pos += 1
        if name in fields:
            raise ValueError('ambiguous or malformed local shutdown OptionSettings')
        # Unrelated tuples are opaque. Required shutdown fields must be scalar.
        fields[name] = (None if value.startswith('(') else
                        value[1:-1] if value.startswith('"') else value)

    def field(name):
        if fields.get(name.casefold()) is None:
            raise ValueError('missing or ambiguous local shutdown configuration: ' + name)
        return fields[name.casefold()]
    if field('RESTAPIEnabled').lower() != 'true':
        raise ValueError('local REST shutdown is disabled; refusing force termination')
    port = field('RESTAPIPort')
    if not re.fullmatch(r'[0-9]{1,5}', port) or not 1 <= int(port) <= 65535:
        raise ValueError('invalid local shutdown port')
    secret = field('AdminPassword')
    if not secret or '\\' in secret or any(ord(c) < 32 or ord(c) == 127 for c in secret):
        # Do not guess Unreal escape decoding when constructing credentials.
        raise ValueError('local shutdown authentication is unavailable')
    return int(port), secret


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise RuntimeError('local shutdown redirected; refusing credential forwarding')


def send_shutdown(port, secret):
    try:
        if type(port) is not int or not 1 <= port <= 65535:
            raise ValueError('invalid local shutdown port')
        request = urllib.request.Request(
            f'http://127.0.0.1:{port}/v1/api/shutdown',
            data=json.dumps({'waittime': 1, 'message': 'Local test shutdown'}).encode(),
            headers={'Content-Type': 'application/json', 'Authorization': 'Basic ' +
                     base64.b64encode(('admin:' + secret).encode()).decode()}, method='POST')
        # No environment proxies or redirects. Ownership is sampled before
        # connect; this cannot atomically bind the socket to the selected PID.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        with opener.open(request, timeout=5) as response:
            if response.status != 200:
                raise RuntimeError('local shutdown was not accepted')
    except Exception:
        # Never print response bodies, URLs supplied by peers, or credentials.
        raise RuntimeError('local shutdown request failed; no force termination attempted') from None


def identity(rows):
    return {(r['pid'], r['path'].casefold(), r['started_ticks']) for r in rows}


def verify_listener(port, targets, shell):
    """Require selected owners, loopback-only bindings and our IPv4 destination.

    This is a listener snapshot, not an atomic binding of a future connection
    to a process. The caller must also recheck selected process identities.
    """
    if type(port) is not int or not 1 <= port <= 65535:
        raise ValueError('invalid local shutdown port')
    pids = {row['pid'] for row in targets}
    # Keep every address; collapsing to owner PIDs conceals exposed listeners.
    raw = shell("$ErrorActionPreference='Stop'; "
                f"$listeners=@(Get-NetTCPConnection -State Listen -LocalPort {port} -ErrorAction Stop | "
                "Select-Object LocalAddress,LocalPort,OwningProcess); "
                "ConvertTo-Json -InputObject @($listeners) -Compress")
    try:
        listeners = json.loads(raw)
    except (ValueError, TypeError):
        raise RuntimeError('local shutdown listener enumeration is invalid') from None
    if not isinstance(listeners, list) or not listeners:
        raise RuntimeError('local shutdown listener enumeration is unavailable')
    ipv4_destination = False
    for row in listeners:
        if (not isinstance(row, dict) or type(row.get('LocalPort')) is not int
                or row['LocalPort'] != port or type(row.get('OwningProcess')) is not int
                or row['OwningProcess'] not in pids or not isinstance(row.get('LocalAddress'), str)):
            raise RuntimeError('local shutdown listener port or ownership is unverified')
        try:
            address = ipaddress.ip_address(row['LocalAddress'])
        except ValueError:
            raise RuntimeError('local shutdown listener address is invalid') from None
        if not address.is_loopback:
            raise RuntimeError('local shutdown listener is not loopback-only')
        ipv4_destination = ipv4_destination or row['LocalAddress'] == '127.0.0.1'
    if not ipv4_destination:
        raise RuntimeError('local shutdown requires an explicit 127.0.0.1 listener')
    return listeners


def graceful_stop(paths, targets, *, processes, shell, send=send_shutdown,
                  timeout=60, clock=time.monotonic, sleep=time.sleep):
    if not targets:
        return
    port, secret = rest_config(paths['root'])
    expected = identity(targets)
    verify_listener(port, targets, shell)
    if identity(processes()) != expected:
        raise RuntimeError('server identity changed before shutdown')
    send(port, secret)
    deadline = clock() + timeout
    while True:
        current = identity(processes())
        if not current:
            return  # Exit observed, not a claim that settings were durable.
        if not current <= expected:
            raise RuntimeError('server identity changed while awaiting shutdown')
        if clock() >= deadline:
            raise RuntimeError('server did not exit after graceful shutdown; left running')
        sleep(min(0.5, max(0, deadline-clock())))
