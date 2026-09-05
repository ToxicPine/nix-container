"""Exercise boot generation selection without starting a container."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


BOOT_SCRIPT = (
    Path(__file__).resolve().parents[1] / "lib/pkgs/supervision/boot/boot.sh"
)


class BootGenerationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="system-image-boot-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.calls = self.root / "calls"
        self.profile = self.root / "profile"
        self.factory = self.root / "factory"
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.write_executable(self.tools / "nix-supervise-tree-wait", "exit 0")

        # Relocate only the image's fixed paths; execute the production script.
        source = BOOT_SCRIPT.read_text()
        for name, original, replacement in [
            ("runtime_directory", "/run/nix-supervise/system", self.root / "runtime"),
            ("profile", "/nix/var/nix/profiles/system", self.profile),
            ("factory_generation", "/opt/defaults/system-generation", self.factory),
            ("environment_dump", "/run/s6-linux-init-env", self.root / "environment"),
        ]:
            declaration = f'{name}="{original}"'
            self.assertEqual(source.count(declaration), 1)
            source = source.replace(declaration, f'{name}="{replacement}"')
        self.script = self.root / "boot.sh"
        self.script.write_text(source)

    @staticmethod
    def write_executable(path, body):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"#!/usr/bin/env bash\n{body}\n")
        path.chmod(0o755)

    def generation(self, path, name, status=0):
        self.write_executable(
            path / "bin/apply",
            f'echo {name} >> "$BOOT_TEST_CALLS"\nexit {status}',
        )

    def run_boot(self):
        return subprocess.run(
            ["bash", str(self.script)],
            env={
                **os.environ,
                "PATH": f"{self.tools}:{os.environ['PATH']}",
                "BOOT_TEST_CALLS": str(self.calls),
            },
            capture_output=True,
            text=True,
            timeout=10,
        )

    def test_selected_generation_is_applied_once(self):
        selected = self.root / "selected"
        self.generation(selected, "selected")
        self.profile.symlink_to(selected)
        self.generation(self.factory, "factory")
        result = self.run_boot()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls.read_text(), "selected\n")

    def test_failed_selected_transition_never_applies_factory(self):
        selected = self.root / "selected"
        self.generation(selected, "selected", status=42)
        self.profile.symlink_to(selected)
        self.generation(self.factory, "factory")
        result = self.run_boot()
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertEqual(self.calls.read_text(), "selected\n")

    def test_unavailable_profile_uses_factory(self):
        self.generation(self.factory, "factory")
        for dangling_profile in (False, True):
            with self.subTest(dangling_profile=dangling_profile):
                if dangling_profile:
                    self.profile.symlink_to(self.root / "missing-generation")
                result = self.run_boot()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.calls.read_text(), "factory\n")
                self.calls.unlink()

    def test_factory_failure_is_reported(self):
        self.generation(self.factory, "factory", status=43)
        result = self.run_boot()
        self.assertEqual(result.returncode, 43, result.stderr)
        self.assertEqual(self.calls.read_text(), "factory\n")

    def test_missing_generations_fail(self):
        self.assertEqual(self.run_boot().returncode, 1)
        self.assertFalse(self.calls.exists())

    def test_unready_tree_does_not_apply_a_generation(self):
        self.generation(self.factory, "factory")
        self.write_executable(self.tools / "nix-supervise-tree-wait", "exit 1")
        self.assertEqual(self.run_boot().returncode, 1)
        self.assertFalse(self.calls.exists())


if __name__ == "__main__":
    unittest.main()
