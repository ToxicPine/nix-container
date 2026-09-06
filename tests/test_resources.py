"""Exercise the production account reconciler against temporary mutable partitions."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "lib/fs/nix-base/scripts/reconcile-accounts.sh"


class ResourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if os.getuid() != 0 or "RESOURCE_TEST_TOOLS" not in os.environ:
            raise RuntimeError("Run tests/resources.sh with Python, jq, util-linux and bubblewrap on PATH")
        cls.runtime = Path(os.environ["RESOURCE_TEST_TOOLS"])

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "root"
        self.etc = self.root / "data/etc"
        self.etc.mkdir(parents=True)
        for name, content in {
            "passwd": "root:x:0:0:root:/root:/bin/bash\nmanual:x:2200:2200::/home/manual:/bin/bash\n",
            "group": "root:x:0:\nmanual:x:2200:manual\n",
            "shadow": "root:!:1::::::\nmanual:password:1::::::\n",
            "gshadow": "root:!::\nmanual:!::manual\n",
            "subuid": "manual:100000:65536\nmanual:200000:65536\n",
            "subgid": "manual:100000:65536\n",
        }.items():
            (self.etc / name).write_text(content)
        self.source = Path(self.temp.name) / "source"
        self.source.write_text("first version")
        self.generation = Path(self.temp.name) / "generation"
        (self.generation / "sw/bin").mkdir(parents=True)
        self.data = {
            "users": {"alice": {"uid": 1000, "gid": 1000, "description": "Alice", "home": "/home/alice", "shell": "/bin/bash", "extraGroups": ["team"]}},
            "groups": {"alice": {"gid": 1000, "members": []}, "team": {"gid": 1500, "members": ["manual"]}},
        }
        # The production Shadow tools, NSS backend and home hook run in a
        # private mount/PID namespace. Host account files are never mounted.
        (self.root / "run").mkdir()
        (self.root / "opt").mkdir()
        self.baseline = json.loads((self.runtime / "baseline-accounts.json").read_text())
        state = self.root / "data/system/resources"
        state.mkdir(parents=True, mode=0o700)
        (self.root / "data/homes").mkdir()
        self.host_etc = self.root / "etc"
        self.host_etc.mkdir()
        (self.host_etc / "nsswitch.conf").write_text(
            "passwd: altfiles\ngroup: altfiles\nshadow: altfiles\ngshadow: altfiles\n")
        shutil.copytree(self.runtime / "hooks/etc/shadow-maint", self.host_etc / "shadow-maint", symlinks=True)
        (self.etc / "login.defs").write_text("USERGROUPS_ENAB yes\nCREATE_MAIL_SPOOL no\n")
        (self.etc / "default").mkdir()
        (self.etc / "default/useradd").write_text("CREATE_MAIL_SPOOL=no\n")
        (self.etc / "shadow").chmod(0o600)
        (self.etc / "gshadow").chmod(0o600)
        self.tools = Path(self.temp.name) / "tools"
        self.tools.mkdir()
        for command in (self.runtime / "commands/bin").iterdir():
            (self.tools / command.name).symlink_to(command.resolve())
        self.env = {**os.environ, "PATH": f"{self.tools}:{os.environ['PATH']}",
                    "LD_LIBRARY_PATH": str(self.runtime / "nss/lib")}

    def write_tool(self, name, body):
        path = self.tools / name
        if path.is_symlink():
            path.unlink()
        path.write_text(f"#!/usr/bin/env bash\nset -euo pipefail\n{body}\n")
        path.chmod(0o755)

    def bootstrap(self):
        result = self.run_isolated(["/bin/bash", str(SCRIPT), "--bootstrap"], json.dumps(self.baseline))
        if result.returncode:
            raise RuntimeError(result.stderr)

    def test_bootstrap_creates_baseline_from_empty_account_files(self):
        self.install_hm()
        for name in ("passwd", "group", "shadow", "gshadow", "subuid", "subgid"):
            (self.etc / name).write_text("")
        self.bootstrap()
        passwd = (self.etc / "passwd").read_text()
        self.assertIn("root:x:0:0:root:/root:/bin/bash", passwd)
        self.assertIn("nixbld10:x:30010:30000:", passwd)
        self.assertIn("sshd:x:65533:65533:", passwd)
        members = next(line.split(":")[3] for line in (self.etc / "group").read_text().splitlines()
                       if line.startswith("nixbld:"))
        self.assertEqual(set(members.split(",")), {f"nixbld{i}" for i in range(1, 11)})
        self.assertFalse(list((self.root / "data/homes").iterdir()))
        self.assertFalse((self.root / "data/system/resources/owned.json").exists())
        self.assertFalse((self.root / "run/current-system").is_symlink())
        self.assertEqual((self.etc / "subuid").read_text(), "")
        before = {name: (self.etc / name).read_bytes() for name in ("passwd", "group", "shadow", "gshadow")}
        self.bootstrap()
        self.assertEqual(before, {name: (self.etc / name).read_bytes() for name in before})

    def test_bootstrap_preserves_existing_accounts_and_runtime_journal(self):
        self.bootstrap()
        self.apply()
        journal = self.root / "data/system/resources/owned.json"
        before_journal = journal.read_bytes()
        passwd = self.etc / "passwd"
        passwd.write_text(passwd.read_text().replace("root:x:0:0:root:/root:/bin/bash",
                                                  "root:x:0:0:Local root:/root:/bin/sh"))
        shadow = self.etc / "shadow"
        shadow.write_text(shadow.read_text().replace("root:!:", "root:local-password:"))
        group = self.etc / "group"
        group.write_text(group.read_text().replace("nixbld:x:30000:", "nixbld:x:30000:manual,"))
        before_shadow = shadow.read_bytes()
        self.bootstrap()
        self.assertIn("root:x:0:0:Local root:/root:/bin/sh", passwd.read_text())
        self.assertIn("manual,nixbld1", group.read_text())
        self.assertEqual(before_shadow, shadow.read_bytes())
        self.assertEqual(before_journal, journal.read_bytes())
        self.assertEqual((self.root / "run/current-system").resolve(), self.generation)

    def test_bootstrap_repairs_missing_accounts_and_checks_identity_conflicts(self):
        self.bootstrap()
        result = self.run_isolated(["/bin/userdel", "sshd"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.bootstrap()
        self.assertIn("sshd:x:65533:65533:", (self.etc / "passwd").read_text())
        passwd = self.etc / "passwd"
        passwd.write_text(passwd.read_text().replace("sshd:x:65533:", "sshd:x:65000:"))
        before = passwd.read_bytes()
        with self.assertRaisesRegex(RuntimeError, "UID/GID migration"):
            self.bootstrap()
        self.assertEqual(before, passwd.read_bytes())

    def test_runtime_configuration_protects_baseline_without_bootstrap_history(self):
        baseline = self.baseline
        baseline["users"]["core-test"] = dict(baseline["users"]["sshd"], uid=42000, gid=42000)
        baseline["groups"]["core-test"] = {"gid": 42000, "members": []}
        self.data["users"]["core-test"] = baseline["users"]["core-test"]
        with self.assertRaisesRegex(RuntimeError, "built-in users"):
            self.apply()

    def test_runtime_repairs_core_accounts_without_recording_baseline(self):
        self.apply()
        result = self.run_isolated(["/bin/userdel", "sshd"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.data.update(users={}, groups={})
        self.apply()
        self.assertIn("sshd:x:65533:65533:", (self.etc / "passwd").read_text())
        self.assertIn("manual:x:2200:2200:", (self.etc / "passwd").read_text())
        self.assertNotIn("alice:", (self.etc / "passwd").read_text())
        state = self.root / "data/system/resources"
        self.assertEqual(json.loads((state / "owned.json").read_text()), {"users": {}, "groups": {}})
        self.assertEqual({p.name for p in state.iterdir()}, {"owned.json", "lock"})

    def test_unchanged_ownership_is_not_rewritten(self):
        self.apply()
        journal = self.root / "data/system/resources/owned.json"
        before = journal.stat()
        self.data["users"]["alice"]["description"] = "Updated description"
        self.apply()
        after = journal.stat()
        self.assertEqual((before.st_ino, before.st_mtime_ns), (after.st_ino, after.st_mtime_ns))
        self.assertIn("Updated description", (self.etc / "passwd").read_text())

    def test_legacy_ownership_is_reduced_to_identities(self):
        journal = self.root / "data/system/resources/owned.json"
        journal.write_text(json.dumps({**self.data, "baseline": self.baseline}))
        self.apply()
        self.assertEqual(json.loads(journal.read_text()), {
            "users": {"alice": {"uid": 1000, "gid": 1000}},
            "groups": {"alice": {"gid": 1000}, "team": {"gid": 1500}},
        })

    def test_failed_creation_can_be_withdrawn_on_next_apply(self):
        self.bootstrap()
        self.write_tool("useradd", f'''
{shlex.quote(str(self.runtime / "commands/bin/useradd"))} "$@"
echo "injected creation failure" >&2
exit 1
''')
        with self.assertRaisesRegex(RuntimeError, "injected creation failure"):
            self.apply()
        self.assertIn("alice:", (self.etc / "passwd").read_text())
        (self.tools / "useradd").unlink()
        (self.tools / "useradd").symlink_to(self.runtime / "commands/bin/useradd")
        self.data.update(users={}, groups={})
        self.apply()
        self.assertNotIn("alice:", (self.etc / "passwd").read_text())
        self.assertIn("manual:", (self.etc / "passwd").read_text())
        self.assertEqual({p.name for p in (self.root / "data/system/resources").iterdir()},
                         {"owned.json", "lock"})

    def test_nix_can_build_as_a_bootstrapped_build_user(self):
        for name in ("passwd", "group", "shadow", "gshadow", "subuid", "subgid"):
            (self.etc / name).write_text("")
        self.bootstrap()
        # Keep Nix's writable store and database inside this test's private
        # filesystem. The host store remains mounted read-only throughout.
        store_root = Path(self.temp.name) / "nix-build-root"
        result = self.run_isolated([
            "/bin/nix-build", "--store", f"local?root={store_root}",
            "--option", "sandbox", "false", "--option", "build-users-group", "nixbld",
            "--option", "substituters", "",
            "--option", "extra-sandbox-paths", "/bin/bash /bin/id /bin/cat " + (self.runtime / "command-closure/store-paths").read_text().replace("\n", " "),
            "--no-out-link", "--expr", '''builtins.derivation {
              name = "bootstrap-build-user-check";
              system = builtins.currentSystem;
              builder = "/bin/bash";
              args = [ "-c" "/bin/id -u > $out; /bin/cat /proc/self/uid_map >> $out" ];
            }'''])
        self.assertEqual(result.returncode, 0, result.stderr)
        output = store_root / result.stdout.strip().lstrip("/")
        # Nix maps the selected build user to UID 1000 inside its sandbox.
        # Check the mapping back to the container's bootstrapped build pool.
        lines = output.read_text().splitlines()
        build_uid = int(lines[0])
        mappings = [tuple(map(int, line.split())) for line in lines[1:]]
        container_uid = next(outer + build_uid - inner for inner, outer, count in mappings
                             if inner <= build_uid < inner + count)
        self.assertIn(container_uid, range(30001, 30011))

    def install_hook(self, source, destination):
        installed = self.host_etc / "shadow-maint" / destination
        installed.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, installed)
        return installed

    def apply(self):
        (self.generation / "manifest.json").write_text(json.dumps({**self.data, "baseline": self.baseline}))
        result = self.run_isolated(["/bin/bash", str(SCRIPT), str(self.generation)])
        if result.returncode:
            raise RuntimeError(result.stderr)

    def run_isolated(self, command, input_text=None):
        repo = SCRIPT.parents[4]
        command = [str(arg).replace(str(repo) + "/", "/workspace/") for arg in command]
        return subprocess.run([
            "bwrap", "--unshare-pid", "--die-with-parent",
            "--ro-bind", "/nix/store", "/nix/store",
            "--ro-bind", str(repo), "/workspace",
            "--tmpfs", "/tmp",
            "--bind", self.temp.name, self.temp.name,
            "--bind", str(self.root / "data"), "/data",
            "--bind", str(self.host_etc), "/etc",
            "--bind", str(self.root / "run"), "/run",
            "--bind", str(self.root / "opt"), "/opt",
            "--ro-bind", str(self.tools), "/bin",
            "--symlink", "/bin", "/usr/bin",
            "--symlink", "/data/homes", "/home",
            "--dir", "/var/empty", "--proc", "/proc", "--dev", "/dev",
            "--chdir", "/workspace", *command],
                                env=self.env, input=input_text, capture_output=True, text=True, timeout=30)

    def test_reconcile_remove_and_restore_preserves_mutable_state(self):
        self.apply()
        home_stat = (self.root / "data/homes/alice").stat()
        self.assertEqual((home_stat.st_uid, home_stat.st_gid), (1000, 1000))
        self.assertIn("alice:x:1000:1000:Alice:/home/alice:/bin/bash", (self.etc / "passwd").read_text())
        self.assertIn("team:x:1500:alice,manual", (self.etc / "group").read_text())
        self.assertEqual((self.root / "run/current-system").resolve(), self.generation)
        home = self.root / "data/homes/alice/keep"
        home.write_text("personal data")
        shadow = self.etc / "shadow"
        shadow.write_text(shadow.read_text().replace("alice:!:", "alice:hashed-password:"))
        self.data["users"]["alice"]["shell"] = "/bin/false"
        self.data["users"]["alice"]["extraGroups"] = []
        self.apply()
        self.assertIn("team:x:1500:manual", (self.etc / "group").read_text())
        self.assertIn("alice:hashed-password:", shadow.read_text())
        users, groups = self.data["users"], self.data["groups"]
        self.data.update(users={}, groups={})
        self.apply()
        self.assertNotIn("alice:", (self.etc / "passwd").read_text())
        self.assertEqual(home.read_text(), "personal data")
        self.assertEqual((self.etc / "subuid").read_text(), "manual:100000:65536\nmanual:200000:65536\n")
        self.data.update(users=users, groups=groups)
        self.apply()
        self.assertIn("alice:!:", shadow.read_text())
        self.assertNotIn("passwords", json.loads((self.root / "data/system/resources/owned.json").read_text()))
        self.assertEqual(shadow.stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.root / "data/system/resources/owned.json").stat().st_mode & 0o777, 0o600)

    def test_uid_mismatch_fails_without_mutating_accounts(self):
        self.apply()
        before = {p.name: p.read_bytes() for p in self.etc.iterdir() if p.is_file() and not p.is_symlink()}
        self.data["users"]["alice"]["uid"] = 1001
        with self.assertRaisesRegex(RuntimeError, "UID/GID migration"):
            self.apply()
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.etc.iterdir() if p.is_file() and not p.is_symlink()})

    def test_generic_home_permissions_do_not_require_hm(self):
        self.apply()
        home = self.root / "data/homes/alice"
        home.chmod(0o755)
        self.apply()
        self.assertEqual(home.stat().st_mode & 0o777, 0o700)
        self.assertFalse((home / ".nixcfg").exists())

    def test_duplicate_declared_ids_fail_before_writes(self):
        self.data["users"]["bob"] = dict(self.data["users"]["alice"], home="/home/bob")
        with self.assertRaisesRegex(RuntimeError, "duplicate declared UIDs"):
            self.apply()
        self.assertNotIn("alice:", (self.etc / "passwd").read_text())

    def test_shadow_lock_is_respected_and_partial_locks_released(self):
        lock = self.etc / "group.lock"
        # A live PID in the isolated namespace prevents Shadow's stale-lock recovery.
        lock.write_bytes(b"1\0")
        with self.assertRaisesRegex(RuntimeError, "lock"):
            self.apply()
        self.assertTrue(lock.exists())
        self.assertFalse((self.etc / "passwd.lock").exists())
        self.assertNotIn("alice:", (self.etc / "passwd").read_text())

    def test_removed_group_still_used_by_manual_user_is_rejected(self):
        self.apply()
        passwd = self.etc / "passwd"
        passwd.write_text(passwd.read_text().replace("manual:x:2200:2200", "manual:x:2200:1500"))
        self.data["users"]["alice"]["extraGroups"] = []
        del self.data["groups"]["team"]
        with self.assertRaisesRegex(RuntimeError, "primary group of an unmanaged user"):
            self.apply()

    def test_new_directories_have_public_parents_and_private_state(self):
        self.apply()
        for path in ("etc", "run", "data/system", "data/homes"):
            self.assertEqual((self.root / path).stat().st_mode & 0o777, 0o755, path)
        for path in ("data/system/resources", "data/homes/alice"):
            self.assertEqual((self.root / path).stat().st_mode & 0o777, 0o700, path)

    def test_invalid_account_plan_does_not_write_databases(self):
        cases = [
            (lambda: self.data["users"]["alice"].update(uid=2200), "already belongs"),
            (lambda: self.data["groups"]["team"].update(gid=2200), "already belongs"),
            (lambda: self.data["groups"].update(other={"gid": 1500, "members": []}), "duplicate declared GIDs"),
            (lambda: self.data["users"].update(root=self.data["users"].pop("alice")), "built-in users"),
        ]
        original = json.dumps(self.data)
        before = {p.name: p.read_bytes() for p in self.etc.iterdir() if p.is_file()}
        for change, message in cases:
            with self.subTest(message=message):
                self.data = json.loads(original)
                change()
                with self.assertRaisesRegex(RuntimeError, message):
                    self.apply()
                self.assertEqual(before, {p.name: p.read_bytes() for p in self.etc.iterdir() if p.is_file()})

    def test_duplicate_database_entries_and_symlinked_databases_fail(self):
        passwd = self.etc / "passwd"
        original = passwd.read_text()
        passwd.write_text(original + original.splitlines()[0] + "\n")
        with self.assertRaisesRegex(RuntimeError, "duplicate account entry"):
            self.apply()
        passwd.unlink()
        passwd.symlink_to(self.source)
        with self.assertRaisesRegex(RuntimeError, "account database is symlinked"):
            self.apply()
        self.assertEqual(self.source.read_text(), "first version")
        self.assertFalse(list(self.etc.glob("*.lock")))

    def test_retry_after_account_tool_failure_preserves_home(self):
        self.apply()
        home = self.root / "data/homes/alice/keep"
        home.write_text("personal data")
        users, groups = self.data["users"], self.data["groups"]
        self.data.update(users={}, groups={})
        self.write_tool("userdel", f'''
{shlex.quote(str(self.runtime / "commands/bin/userdel"))} "$@"
echo "injected account failure" >&2
exit 1
''')
        with self.assertRaisesRegex(RuntimeError, "injected account failure"):
            self.apply()
        self.assertNotIn("alice:", (self.etc / "passwd").read_text())
        (self.tools / "userdel").unlink()
        (self.tools / "userdel").symlink_to(self.runtime / "commands/bin/userdel")
        self.apply()
        self.data.update(users=users, groups=groups)
        self.apply()
        self.assertEqual(home.read_text(), "personal data")

    def test_baked_useradd_hook_runs_and_survives_refresh(self):
        self.bootstrap()
        hook = self.source.with_name("useradd-hook")
        hook.write_text('#!/bin/bash\nprintf "%s\\n" "$SUBJECT" >> /data/hook-ran\n')
        hook.chmod(0o755)
        installed = self.install_hook(hook, "useradd-post.d/60-test")
        self.apply()
        self.assertEqual((self.root / "data/hook-ran").read_text(), "alice\n")
        self.apply()
        self.assertEqual(installed.read_bytes(), hook.read_bytes())

    def test_userdel_hook_skips_nested_transition_but_still_handles_manual_deletion(self):
        hook = self.source.with_name("userdel-hook")
        template = (SCRIPT.parents[4] / "lib/modules/home-manager/hooks/userdel-pre").read_text()
        hook.write_text(template.replace("@runtimeShell@", "/bin/bash")
                        .replace("@jq@", shutil.which("jq"))
                        .replace("@s6rc@", "/bin/test-s6-rc"))
        hook.chmod(0o755)
        self.write_tool("test-s6-rc", 'echo called >> /data/s6-called')
        self.install_hook(hook, "userdel-pre.d/50-test")
        self.apply()
        supervision = self.root / "run/nix-supervise/system"
        supervision.mkdir(parents=True)
        (supervision / "live").symlink_to("/run/live-tree")
        (supervision / "current-service-manifest.json").write_text(json.dumps({
            "services": {"tree": {"optionPath": "tree-alice"}}
        }))
        users, groups = self.data["users"], self.data["groups"]
        self.data.update(users={}, groups={})
        self.apply()
        self.assertFalse((self.root / "data/s6-called").exists())
        self.data.update(users=users, groups=groups)
        self.apply()
        result = self.run_isolated(["/bin/userdel", "alice"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "data/s6-called").read_text(), "called\n")

    def install_hm(self):
        # Use the actual rendered HM image fragment, including its executable hooks.
        shutil.copytree(self.runtime / "hm-files/etc", self.host_etc, dirs_exist_ok=True)
        defaults = self.root / "opt/defaults"
        skeleton = defaults / "skel/.nixcfg"
        factory = defaults / "hm-user/alice"
        for directory, contents in ((skeleton, "generic skeleton"), (factory, "alice config")):
            directory.mkdir(parents=True)
            (directory / "home.nix").write_text(contents)
        (self.root / "opt/app/hm-user").mkdir(parents=True)

    def test_image_hm_hook_preserves_per_user_configuration_precedence(self):
        self.install_hm()
        self.apply()
        config = self.root / "data/homes/alice/.nixcfg/home.nix"
        self.assertEqual(config.read_text(), "alice config")
        self.assertEqual((config.stat().st_uid, config.stat().st_gid), (1000, 1000))
        self.assertTrue(config.stat().st_mode & 0o200)
        self.assertEqual(os.readlink(self.root / "opt/app/hm-user/alice"), "/home/alice/.nixcfg")
        config.write_text("user edits")
        config.chmod(0o400)
        self.apply()
        self.assertEqual(config.read_text(), "user edits")
        self.assertEqual(config.stat().st_mode & 0o777, 0o400)
        result = self.run_isolated(["/bin/useradd", "--uid", "1001", "--user-group",
                                    "--create-home", "--skel", "/var/empty", "bob"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "data/homes/bob/.nixcfg/home.nix").read_text(), "generic skeleton")

    def test_hm_hook_preserves_retained_config_on_account_recreation(self):
        self.install_hm()
        self.apply()
        config = self.root / "data/homes/alice/.nixcfg/home.nix"
        config.write_text("retained config")
        config.chmod(0o400)
        users, groups = self.data["users"], self.data["groups"]
        self.data.update(users={}, groups={})
        self.apply()
        self.assertFalse((self.root / "opt/app/hm-user/alice").is_symlink())
        self.data.update(users=users, groups=groups)
        self.apply()
        self.assertEqual(config.read_text(), "retained config")
        self.assertEqual(config.stat().st_mode & 0o777, 0o400)
        self.assertTrue((self.root / "opt/app/hm-user/alice").is_symlink())

    def test_hm_hook_does_not_create_absent_or_nonstandard_home(self):
        self.install_hm()
        for name, options in (("alice", ["--no-create-home"]),
                              ("bob", ["--home-dir", "/var/empty", "--no-create-home"])):
            result = self.run_isolated(["/bin/useradd", "--user-group", *options, name])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((self.root / "data/homes" / name).exists())
            self.assertFalse((self.root / "opt/app/hm-user" / name).is_symlink())

    def test_hm_hook_refuses_symlinked_configuration(self):
        self.install_hm()
        home = self.root / "data/homes/alice"
        home.mkdir()
        (home / ".nixcfg").symlink_to("/opt/defaults/hm-user/alice")
        with self.assertRaisesRegex(RuntimeError, "refusing symlinked"):
            self.apply()
        factory = self.root / "opt/defaults/hm-user/alice/home.nix"
        self.assertEqual(factory.read_text(), "alice config")
        self.assertEqual(factory.stat().st_uid, 0)

    def test_startup_restores_links_without_reseeding_or_changing_permissions(self):
        self.install_hm()
        self.apply()
        config = self.root / "data/homes/alice/.nixcfg/home.nix"
        config.write_text("persistent edits")
        config.chmod(0o400)
        link = self.root / "opt/app/hm-user/alice"
        link.unlink()
        # Execute the production entrypoint's link restoration in the same
        # isolated filesystem, without bootstrapping Nix or starting PID 1.
        entrypoint = (SCRIPT.parents[4] / "lib/packages/entrypoint/entrypoint.sh").read_text()
        restore = entrypoint.split("# Restore the image's HM links", 1)[1].split("# exec preserves PID 1", 1)[0]
        restore = restore.split("\n", 1)[1]
        result = self.run_isolated(["/bin/bash", "-eu", "-c", 'ACCOUNT_DATA_DIR=/data/etc\n' + restore])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(os.readlink(link), "/home/alice/.nixcfg")
        self.assertEqual(config.read_text(), "persistent edits")
        self.assertEqual(config.stat().st_mode & 0o777, 0o400)
        self.assertFalse((self.root / "data/homes/manual/.nixcfg").exists())
        # An existing account with no config is left for explicit setup.
        config.unlink()
        link.unlink()
        result = self.run_isolated(["/bin/bash", "-eu", "-c", 'ACCOUNT_DATA_DIR=/data/etc\n' + restore])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(link.is_symlink())
        self.assertFalse(config.exists())


if __name__ == "__main__":
    unittest.main()
