#!/usr/bin/env python3
"""Tests for the Kingdom auth service.

Run: python3 -m unittest discover -s kingdom/auth -v
These run without root, without tailscale and without any game data: the identity lookup is
injected, so what is under test is the part that has to be right — hashing, the audit chain,
lockouts, and the promise that no plaintext secret ever reaches the disk.
"""

from __future__ import annotations

import json
import os
import stat
import tempfile
import unittest
from pathlib import Path

import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from kos_auth import (  # noqa: E402
    Account,
    AuditLog,
    AuthService,
    Identity,
    IdentityError,
    IdentityResolver,
    check_secret,
    hash_secret,
    new_secret,
    parse_whois,
)

# Captured from `tailscale whois` on this box: our own node, and one of Robby's shared devices
# (note the empty machine Name — shared devices report none, which is why display falls back).
WHOIS_SELF = """Machine:
  Name:          beelink.tail96c9e1.ts.net
  ID:            nESEeBiRPP11CNTRL
  Addresses:     [100.102.189.126/32 fd7a:115c:a1e0::7039:bd7f/128]
User:
  Name:     liamdev631@gmail.com
  ID:       7230364925941255
"""

WHOIS_SHARED = """Machine:
  Name:          
  ID:            n8Uf25YMwv11CNTRL
  Addresses:     [100.109.247.50/32 fd7a:115c:a1e0::532d:f733/128]
User:
  Name:     nahxprpht@gmail.com
  ID:       6123606715262792
"""

LIAM_IP = "100.102.189.126"
ROBBY_IP = "100.109.247.50"


def fake_resolver(fail_for: set[str] | None = None) -> IdentityResolver:
    """Resolve the two real identities without touching the network."""
    fail_for = fail_for or set()

    def runner(argv: list[str]) -> str:
        ip = argv[-1]
        if ip in fail_for or ip not in (LIAM_IP, ROBBY_IP):
            raise IdentityError("not a tailnet address")
        return WHOIS_SELF if ip == LIAM_IP else WHOIS_SHARED

    return IdentityResolver(runner=runner)


class TempStore(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.store = Path(self._tmp.name) / "kos-auth"
        self.service = AuthService(self.store, resolver=fake_resolver())

    def tearDown(self) -> None:
        self._tmp.cleanup()


class TestParsing(unittest.TestCase):
    def test_parses_own_node(self) -> None:
        identity = parse_whois(WHOIS_SELF)
        self.assertIsNotNone(identity)
        assert identity is not None
        self.assertEqual(identity.user_id, "7230364925941255")
        self.assertEqual(identity.node_id, "nESEeBiRPP11CNTRL")
        self.assertEqual(identity.login, "liamdev631@gmail.com")
        self.assertEqual(identity.display_default, "beelink")

    def test_shared_device_without_machine_name_falls_back_to_login(self) -> None:
        identity = parse_whois(WHOIS_SHARED)
        assert identity is not None
        self.assertEqual(identity.user_id, "6123606715262792")
        self.assertEqual(identity.display_default, "nahxprpht")

    def test_garbage_is_not_an_identity(self) -> None:
        self.assertIsNone(parse_whois("Machine:\n  Name: x\n"))


class TestSecrets(unittest.TestCase):
    def test_secret_is_readable_but_strong(self) -> None:
        secret = new_secret()
        groups = secret.split("-")
        self.assertEqual(len(groups), 4)
        self.assertTrue(all(len(g) == 5 for g in groups))
        # 20 chars from a 32-symbol alphabet is ~100 bits; two draws never collide.
        self.assertNotEqual(secret, new_secret())

    def test_hash_round_trip_and_rejection(self) -> None:
        salt, digest, params = hash_secret("ABCDE-FGHIJ-KLMNP-QRSTU")
        self.assertTrue(check_secret("ABCDE-FGHIJ-KLMNP-QRSTU", salt, digest, params))
        self.assertFalse(check_secret("ABCDE-FGHIJ-KLMNP-QRSTV", salt, digest, params))

    def test_same_secret_hashes_differently(self) -> None:
        first = hash_secret("SAME-SECR-ETXX-XXXXX")
        second = hash_secret("SAME-SECR-ETXX-XXXXX")
        self.assertNotEqual(first[1], second[1], "salts must make equal secrets look different")


class TestEnrollment(TempStore):
    def test_first_contact_mints_a_password_and_shows_it_once(self) -> None:
        result = self.service.enroll(ROBBY_IP)
        self.assertEqual(result["status"], "created")
        self.assertEqual(result["user_id"], "6123606715262792")
        self.assertEqual(result["display"], "nahxprpht")
        self.assertIn("secret", result)

        again = self.service.enroll(ROBBY_IP)
        self.assertEqual(again["status"], "exists")
        self.assertNotIn("secret", again, "a second connect must never re-reveal the password")

    def test_password_is_never_stored_or_logged_in_plain(self) -> None:
        secret = self.service.enroll(ROBBY_IP)["secret"]
        accounts = (self.store / "accounts.json").read_text(encoding="utf-8")
        audit = (self.store / "audit.jsonl").read_text(encoding="utf-8")
        self.assertNotIn(secret, accounts)
        self.assertNotIn(secret, audit)
        self.assertIn("scrypt", json.dumps(json.loads(accounts)["users"]["6123606715262792"]["params"]))

    def test_state_files_are_private(self) -> None:
        self.service.enroll(ROBBY_IP)
        mode = stat.S_IMODE(os.stat(self.store / "accounts.json").st_mode)
        self.assertEqual(mode, 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(self.store).st_mode), 0o700)

    def test_second_device_of_same_user_shares_the_account(self) -> None:
        self.service.enroll(ROBBY_IP)
        # Robby's other shared device: same user id, different node -> same account.
        other_node = Identity(user_id="6123606715262792", node_id="nOtherNode1111", login="nahxprpht@gmail.com", machine="")
        self.service.resolver = IdentityResolver(runner=lambda argv: (
            "Machine:\n  Name: x\n  ID: nOtherNode1111\nUser:\n  Name: nahxprpht@gmail.com\n  ID: 6123606715262792\n"
        ))
        result = self.service.enroll("100.84.99.22")
        self.assertEqual(result["status"], "exists")
        self.assertIn("nOtherNode1111", self.service._accounts["6123606715262792"].nodes)
        self.assertIsNotNone(other_node)


class TestLogin(TempStore):
    def test_correct_password_authenticates(self) -> None:
        secret = self.service.enroll(ROBBY_IP)["secret"]
        result = self.service.verify(ROBBY_IP, secret)
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["display"], "nahxprpht")

    def test_unknown_identity_is_told_to_enroll(self) -> None:
        result = self.service.verify(ROBBY_IP, "ANY-THIN-GHERE-XXXXX")
        self.assertEqual(result["status"], "enroll")

    def test_wrong_password_locks_out_after_repeated_failures(self) -> None:
        secret = self.service.enroll(ROBBY_IP)["secret"]
        for attempt in range(4):
            self.assertEqual(self.service.verify(ROBBY_IP, "WRONG-WRONG-WRONG-WRONG")["status"], "denied")
        locked = self.service.verify(ROBBY_IP, "WRONG-WRONG-WRONG-WRONG")
        self.assertEqual(locked["status"], "locked")
        self.assertGreater(locked["retry_after"], 0)
        # The lockout holds even for the right password — otherwise it is not a lockout.
        self.assertEqual(self.service.verify(ROBBY_IP, secret)["status"], "locked")

    def test_a_node_cannot_borrow_another_identity(self) -> None:
        """The point of the design: Liam's IP cannot authenticate as Robby's account."""
        robbys_secret = self.service.enroll(ROBBY_IP)["secret"]
        as_liam = self.service.verify(LIAM_IP, robbys_secret)
        self.assertEqual(as_liam["status"], "enroll", "Liam's node must not find Robby's account")

    def test_ip_that_is_not_on_the_tailnet_is_refused(self) -> None:
        with self.assertRaises(IdentityError):
            self.service.verify("203.0.113.7", "WHAT-EVER-HERE-XXXXX")


class TestAudit(unittest.TestCase):
    def test_chain_verifies_and_detects_edits(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            log = AuditLog(Path(tmp) / "audit.jsonl")
            log.append("enroll", user_id="1")
            log.append("login-ok", user_id="1")
            log.append("login-failed", user_id="2")
            ok, count, problem = log.verify()
            self.assertTrue(ok, problem)
            self.assertEqual(count, 3)

            lines = (Path(tmp) / "audit.jsonl").read_text(encoding="utf-8").splitlines()
            tampered = json.loads(lines[1])
            tampered["event"] = "login-ok-nothing-to-see-here"
            lines[1] = json.dumps(tampered, sort_keys=True, separators=(",", ":"))
            (Path(tmp) / "audit.jsonl").write_text("\n".join(lines) + "\n", encoding="utf-8")

            ok, count, problem = log.verify()
            self.assertFalse(ok)
            self.assertEqual(count, 2)
            self.assertIn("hash mismatch", problem or "")

    def test_deleting_a_line_is_detected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "audit.jsonl"
            log = AuditLog(path)
            log.append("a")
            log.append("b")
            log.append("c")
            lines = path.read_text(encoding="utf-8").splitlines()
            path.write_text("\n".join([lines[0], lines[2]]) + "\n", encoding="utf-8")
            ok, _, problem = log.verify()
            self.assertFalse(ok)
            self.assertIn("does not follow", problem or "")


class TestAdmin(TempStore):
    def test_reset_needs_the_token_and_reissues_a_password(self) -> None:
        self.service.enroll(ROBBY_IP)
        self.assertEqual(self.service.admin_reset("not-the-token", "6123606715262792")["status"], "forbidden")
        result = self.service.admin_reset(self.service.admin_token(), "6123606715262792")
        self.assertEqual(result["status"], "reset")
        self.assertEqual(self.service.verify(ROBBY_IP, result["secret"])["status"], "ok")

    def test_status_never_exposes_hashes(self) -> None:
        self.service.enroll(ROBBY_IP)
        rendered = json.dumps(self.service.status())
        account = self.service._accounts["6123606715262792"]
        self.assertNotIn(account.hash, rendered)
        self.assertNotIn(account.salt, rendered)
        self.assertTrue(self.service.status()["audit"]["ok"])

    def test_admin_token_file_is_private(self) -> None:
        self.service.admin_token()
        self.assertEqual(stat.S_IMODE(os.stat(self.store / "admin.token").st_mode), 0o600)


class TestCli(TempStore):
    def test_cli_identify_and_enroll_round_trip(self) -> None:
        import subprocess

        script = Path(__file__).resolve().parent / "kos_auth.py"
        env = dict(os.environ, KOS_AUTH_DIR=str(self.store))
        # The real CLI resolves through tailscale, which cannot answer for a fake IP, so this
        # asserts the failure path and its exit code rather than inventing an identity.
        proc = subprocess.run(
            [sys.executable, str(script), "--store", str(self.store), "identify", "--ip", "203.0.113.7"],
            capture_output=True, text=True, env=env, timeout=60,
        )
        self.assertEqual(proc.returncode, 2)
        self.assertIn('"status":"error"', proc.stdout)

        proc = subprocess.run(
            [sys.executable, str(script), "--store", str(self.store), "status"],
            capture_output=True, text=True, env=env, timeout=60,
        )
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(json.loads(proc.stdout)["accounts"], [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
