"""Checks Apple status retries without credentials or network requests."""
import io
import unittest
from unittest.mock import patch, MagicMock
from urllib.error import HTTPError
from verify_app_store_build import read_json_with_retry

class AppleRetryTests(unittest.TestCase):
    @patch('verify_app_store_build.time.sleep')
    @patch('verify_app_store_build.urllib.request.urlopen')
    def test_timeout_then_success(self, open_url, sleep):
        response = MagicMock()
        response.__enter__.return_value = io.StringIO('{"data": []}')
        open_url.side_effect = [TimeoutError(), response]
        self.assertEqual(read_json_with_retry('request'), {'data': []})
        self.assertEqual(open_url.call_count, 2)
        sleep.assert_called_once_with(5)

    @patch('verify_app_store_build.time.sleep')
    @patch('verify_app_store_build.urllib.request.urlopen')
    def test_server_failure_retries(self, open_url, sleep):
        response = MagicMock()
        response.__enter__.return_value = io.StringIO('{"data": []}')
        open_url.side_effect = [HTTPError('url', 503, 'unavailable', {}, None), response]
        self.assertEqual(read_json_with_retry('request'), {'data': []})

    @patch('verify_app_store_build.urllib.request.urlopen')
    def test_auth_error_fails_immediately(self, open_url):
        open_url.side_effect = HTTPError('url', 401, 'unauthorized', {}, None)
        with self.assertRaises(HTTPError):
            read_json_with_retry('request')
        self.assertEqual(open_url.call_count, 1)

    @patch('verify_app_store_build.time.sleep')
    @patch('verify_app_store_build.urllib.request.urlopen', side_effect=TimeoutError())
    def test_exhausted_retries_explain_upload_uncertainty(self, open_url, sleep):
        with self.assertRaisesRegex(RuntimeError, 'Check App Store Connect before re-uploading'):
            read_json_with_retry('request')
        self.assertEqual(open_url.call_count, 4)
        self.assertEqual(sleep.call_count, 3)

    @patch('verify_app_store_build.urllib.request.urlopen')
    def test_malformed_payload_is_not_hidden(self, open_url):
        response = MagicMock()
        response.__enter__.return_value = io.StringIO('invalid')
        open_url.return_value = response
        with self.assertRaises(ValueError):
            read_json_with_retry('request')
        self.assertEqual(open_url.call_count, 1)

if __name__ == '__main__':
    unittest.main()
