"""Execute the regional failover probe with deterministic remote transport."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class FailoverTrafficTests(unittest.TestCase):
    def probe(self, mode):
        source = (REPO / "scripts/verify-azure-failover.sh").read_text()
        function = source[source.index("traffic() {"):source.index("\nwait_state() {")]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            curl = root / "curl"
            curl.write_text("""#!/usr/bin/env bash
case "$*" in
  *http://198.51.100.10/*)
    [ "$PROBE_MODE" != empty-origin ] && printf 'expected origin'
    ;;
  *http://demo.example/*)
    if [ "$PROBE_MODE" = wrong-vip ]; then printf 'unrelated content'; else printf 'expected origin'; fi
    ;;
  *http://inside.example/*)
    if [ "$PROBE_MODE" = wrong-ilb ]; then printf 'unrelated content'; else printf 'expected origin'; fi
    ;;
  *) exit 2 ;;
esac
""")
            timeout = root / "timeout"
            timeout.write_text("#!/usr/bin/env bash\nexit 0\n")
            curl.chmod(0o755)
            timeout.chmod(0o755)
            script = """set -euo pipefail
az() {
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --scripts ]; then bash -c "$2"; return; fi
    shift
  done
  return 2
}
""" + function + """
traffic rg client demo.example 10.250.0.10 inside.example 10.0.3.10 10.0.3.11 198.51.100.10
"""
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"], PROBE_MODE=mode)
            return subprocess.run(["bash", "-c", script], env=env, capture_output=True).returncode

    def test_matching_origin_passes(self):
        self.assertEqual(self.probe("healthy"), 0)

    def test_unrelated_vip_content_fails(self):
        self.assertNotEqual(self.probe("wrong-vip"), 0)

    def test_unrelated_ilb_content_fails(self):
        self.assertNotEqual(self.probe("wrong-ilb"), 0)

    def test_missing_direct_origin_fails(self):
        self.assertNotEqual(self.probe("empty-origin"), 0)


if __name__ == "__main__":
    unittest.main()
