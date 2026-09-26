"""Keep loopback fixture startup independent of host DNS configuration."""

from http.server import BaseHTTPRequestHandler
import socket
import unittest
from unittest.mock import patch

from player_fixtures import LoopbackHTTPServer


class FixtureServerTest(unittest.TestCase):
    def test_server_listens_without_reverse_dns(self):
        with patch('socket.getfqdn', side_effect=AssertionError('DNS must not run')):
            with LoopbackHTTPServer(('127.0.0.1', 0), BaseHTTPRequestHandler) as server:
                self.assertEqual(server.server_name, '127.0.0.1')
                self.assertGreater(server.server_port, 0)
                with socket.create_connection(server.server_address, timeout=2):
                    pass


if __name__ == '__main__':
    unittest.main()
