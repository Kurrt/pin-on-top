"""Tests for the commit message check, using real git in throwaway repos."""

import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "check_commits.py"
HOOK = ROOT / ".githooks" / "commit-msg"

spec = importlib.util.spec_from_file_location("check_commits", SCRIPT)
check_commits = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check_commits)

ZEROS = "0" * 40
SCISSORS = f"# {check_commits.SCISSORS}"
LONGEST = "fix: " + "y" * (check_commits.MAX_SUBJECT - 5)
# Hooks set GIT_DIR and friends, which would point these tests at the real repo.
CLEAN_ENV = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
CLEAN_ENV.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_SYSTEM=os.devnull)


class Subjects(unittest.TestCase):
    def test_good_subjects_pass(self):
        for subject in (
            "feat: add a thing",
            "fix(alerts): handle an empty config",
            "feat!: drop the old config",
            "refactor(data-limit)!: split the count",
            "docs: mention Docker and GitHub",
            'Revert "feat: add a thing"',
            'Reapply "feat: add a thing"',
            LONGEST,
        ):
            self.assertEqual(check_commits.subject_problems(subject), [], subject)

    def test_every_type_passes(self):
        for name in check_commits.TYPES:
            self.assertEqual(check_commits.subject_problems(f"{name}: do it"), [], name)

    def test_bad_subjects_fail(self):
        for subject in (
            "",
            "Add a thing",
            "feat add a thing",
            "feat:add a thing",
            "feat : add a thing",
            "feat: ",
            "Feat: add a thing",
            "FIX: add a thing",
            "wip: add a thing",
            "feat(): add a thing",
            "feat(Scope): add a thing",
            "feat(two words): add a thing",
            "feat!(alerts): add a thing",
            "feat: add a thing.",
            "feat(app.js): add a thing",
            "feat(data_guard): add a thing",
            "feat(src/app): add a thing",
            "fix(API): add a thing",
            "feat(-x): add a thing",
            LONGEST + "y",
            "feat: one\nfeat: two",
            'Revert "',
            'Reapply "',
            "Reapply feat: add a thing",
            'reapply "feat: add a thing"',
        ):
            self.assertNotEqual(check_commits.subject_problems(subject), [], repr(subject))

    def test_a_pull_request_number_at_the_end_is_ignored(self):
        for subject in (
            "feat: add a thing (#12)",
            'Revert "feat: add a thing (#3)" (#13)',
            'Reapply "feat: add a thing (#3)" (#13)',
            LONGEST + " (#12)",
        ):
            self.assertEqual(check_commits.subject_problems(subject), [], subject)

    def test_a_pull_request_number_hides_no_other_problem(self):
        for subject in (
            LONGEST + "y (#12)",
            "fix: a. (#12)",
            "Add a thing (#12)",
            "feat: (#12)",
            "(#12)",
            LONGEST + " (#1) (#2)",
            'Revert "feat: a" (#1) (#2)',
        ):
            self.assertNotEqual(check_commits.subject_problems(subject), [], subject)

    def test_the_limit_is_reported_without_the_pull_request_number(self):
        self.assertEqual(
            check_commits.subject_problems(LONGEST + "y (#12)"),
            ["the subject is 73 characters, the limit is 72"],
        )

    def test_the_error_names_the_scope_characters(self):
        for subject in ("fix(app.js): a", "test(data_guard): a", "Add a thing (#12)"):
            problems = check_commits.subject_problems(subject)
            self.assertIn("a-z, 0-9 and -", problems[0], subject)
            self.assertIn(subject, problems[0])

    def test_git_merge_and_fixup_subjects_fail_outside_the_hook(self):
        for subject in ("Merge branch 'main'", "fixup! feat: add a thing"):
            self.assertNotEqual(check_commits.subject_problems(subject), [], subject)

    def test_documented_types_match_the_check(self):
        text = (ROOT / "CONTRIBUTING.md").read_text(encoding="utf-8")
        documented = re.findall(r"^\| `([a-z]+)` \|", text, re.MULTILINE)
        self.assertEqual(sorted(documented), sorted(check_commits.TYPES))


class Messages(unittest.TestCase):
    def test_body_needs_a_blank_line(self):
        self.assertEqual(check_commits.message_problems("feat: a\n\nbody"), [])
        self.assertNotEqual(check_commits.message_problems("feat: a\nbody"), [])

    def test_empty_message_fails(self):
        self.assertNotEqual(check_commits.message_problems("  \n"), [])

    def test_trailers_and_long_bodies_are_left_alone(self):
        self.assertEqual(
            check_commits.message_problems("fix: a\n\n" + "b" * 200 + "\n\nRefs: #1\n"), []
        )


class MessageFiles(unittest.TestCase):
    def check(self, text, **options):
        return check_commits.message_file_problems(text, **options)

    def test_comments_are_ignored(self):
        self.assertEqual(self.check("# note\n\nfeat: a\n\n# Please enter\n"), [])
        self.assertNotEqual(self.check("# note\nAdd a thing\n"), [])

    def test_below_the_scissors_is_ignored(self):
        self.assertEqual(self.check(f"feat: a\n{SCISSORS}\ndiff --git a b\nNot a rule\n"), [])

    def test_empty_message_is_left_for_git_to_refuse(self):
        self.assertEqual(self.check("# only a comment\n\n"), [])
        self.assertEqual(self.check(f"{SCISSORS}\nAdd a thing\n"), [])

    def test_git_written_messages_pass_in_the_hook(self):
        for message in ("Merge branch 'main'", "fixup! feat: a", "squash! feat: a", "amend! feat: a"):
            self.assertEqual(self.check(message + "\n"), [], message)

    def test_bad_message_fails(self):
        self.assertNotEqual(self.check("Add a thing\n"), [])

    def test_the_comment_prefix_can_change(self):
        self.assertEqual(self.check("; note\n\nfeat: a\n\n; Please enter\n", comment=";"), [])
        self.assertEqual(self.check("; only a comment\n", comment=";"), [])
        self.assertEqual(
            self.check(f"feat: a\n; {check_commits.SCISSORS}\nNot a rule\n", comment=";"), []
        )
        self.assertNotEqual(self.check("#123 broken\n\nfeat: a\n", comment=";"), [])
        self.assertNotEqual(self.check(f"feat: a\n{SCISSORS}\nNot a rule\n", comment=";"), [])

    def test_without_an_editor_the_text_is_checked_as_written(self):
        for text in (
            "#42 Add a thing\n",
            "# Add a thing\n",
            "# note\n\nfeat: a\n",
            "feat: a\n# note\n\nbody\n",
            f"feat: a\n{SCISSORS}\nNot a rule\n",
        ):
            self.assertNotEqual(self.check(text, editor_used=False), [], text)
        self.assertEqual(self.check("feat: a\n\n#42 is the issue\n", editor_used=False), [])

    def test_without_an_editor_an_empty_message_fails(self):
        for text in ("", "\n", "  \n\n"):
            self.assertEqual(self.check(text, editor_used=False), ["the message is empty"], repr(text))

    def test_without_an_editor_git_written_messages_still_pass(self):
        for message in ("Merge branch 'main'", "fixup! feat: a", "squash! feat: a", "amend! feat: a"):
            self.assertEqual(self.check(message + "\n", editor_used=False), [], message)

    def test_whitespace_at_the_end_of_a_line_is_removed(self):
        for options in ({}, {"editor_used": False}):
            self.assertNotEqual(self.check("feat: a.  \n\nbody\n", **options), [])
            self.assertEqual(self.check(LONGEST + "  \n\nbody\n", **options), [])
            self.assertEqual(self.check('Revert "a"\t\n\nbody\n', **options), [])
            self.assertEqual(self.check("feat: a\r\n \t\r\nbody  \r\n", **options), [])


class Command(unittest.TestCase):
    def run_script(self, *args, cwd=None, env=CLEAN_ENV):
        return subprocess.run(
            [sys.executable, "-I", str(SCRIPT), *args],
            cwd=cwd, env=env, capture_output=True, text=True,
        )

    def test_subject(self):
        self.assertEqual(self.run_script("--subject=fix: a").returncode, 0)
        result = self.run_script("--subject=Add a thing")
        self.assertEqual(result.returncode, 1)
        self.assertIn("CONTRIBUTING.md", result.stderr)

    def test_subject_that_looks_like_an_option_is_only_a_bad_subject(self):
        self.assertEqual(self.run_script("--subject=--range=x..y").returncode, 1)

    def test_missing_message_file_cannot_check(self):
        with tempfile.TemporaryDirectory() as folder:
            missing = os.path.join(folder, "missing")
            self.assertEqual(self.run_script(f"--message-file={missing}").returncode, 2)

    def test_git_editor_decides_how_a_message_file_is_read(self):
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "message")
            Path(path).write_text("#42 Add a thing\n", encoding="utf-8")
            for editor, expected in ((None, 0), (":", 1), ("true", 0)):
                env = CLEAN_ENV if editor is None else {**CLEAN_ENV, "GIT_EDITOR": editor}
                result = self.run_script(f"--message-file={path}", cwd=folder, env=env)
                self.assertEqual(result.returncode, expected, editor)

    def test_needs_exactly_one_mode(self):
        self.assertEqual(self.run_script().returncode, 2)
        self.assertEqual(self.run_script("--subject=fix: a", "--range=a..b").returncode, 2)


class Repo(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.repo = folder.name
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.invalid")

    def git(self, *args):
        return subprocess.run(
            ["git", *args], cwd=self.repo, env=CLEAN_ENV, capture_output=True, text=True, check=True
        ).stdout.strip()

    def commit(self, message):
        self.git("commit", "-q", "--allow-empty", "-m", message)
        return self.git("rev-parse", "HEAD")

    def check_range(self, value):
        return subprocess.run(
            [sys.executable, "-I", str(SCRIPT), f"--range={value}"],
            cwd=self.repo, env=CLEAN_ENV, capture_output=True, text=True,
        )


class Ranges(Repo):
    def test_only_commits_after_before_are_checked(self):
        self.commit("Old message from before the rule")
        before = self.commit("feat: a")
        after = self.commit("fix: b")
        result = self.check_range(f"{before}..{after}")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Checked 1 commit(s)", result.stdout)

    def test_every_commit_in_the_range_is_checked(self):
        before = self.commit("feat: a")
        bad = self.commit("Add a thing")
        after = self.commit("fix: b")
        result = self.check_range(f"{before}..{after}")
        self.assertEqual(result.returncode, 1)
        self.assertIn(bad[:12], result.stderr)
        self.assertIn("Checked 2 commit(s)", result.stdout)

    def test_blank_line_rule_applies_to_commits(self):
        before = self.commit("feat: a")
        after = self.commit("fix: b\nno blank line")
        self.assertEqual(self.check_range(f"{before}..{after}").returncode, 1)

    def test_merge_commits_are_skipped_but_their_branch_commits_are_not(self):
        before = self.commit("feat: a")
        self.git("checkout", "-q", "-b", "side")
        self.commit("fix: b")
        self.git("checkout", "-q", "main")
        self.commit("fix: c")
        self.git("merge", "-q", "--no-ff", "-m", "Merge branch 'side'", "side")
        after = self.git("rev-parse", "HEAD")
        result = self.check_range(f"{before}..{after}")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Checked 2 commit(s)", result.stdout)

    def test_squash_merge_subjects_pass_in_a_range(self):
        before = self.commit("feat: a")
        self.commit("feat: b (#12)")
        self.commit(LONGEST + " (#13)")
        after = self.commit('Revert "feat: b (#12)" (#14)')
        result = self.check_range(f"{before}..{after}")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Checked 3 commit(s)", result.stdout)

    def test_a_too_long_squash_merge_subject_fails_in_a_range(self):
        before = self.commit("feat: a")
        after = self.commit(LONGEST + "y (#12)")
        self.assertEqual(self.check_range(f"{before}..{after}").returncode, 1)

    def test_git_reverting_a_revert_passes_in_a_range(self):
        before = self.commit("feat: a")
        (Path(self.repo) / "file").write_text("text\n", encoding="utf-8")
        self.git("add", "file")
        self.commit("feat: add a file")
        self.git("revert", "--no-edit", "HEAD")
        self.git("revert", "--no-edit", "HEAD")
        result = self.check_range(f"{before}..HEAD")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Checked 3 commit(s)", result.stdout)

    def test_fixup_commits_fail_in_a_range(self):
        before = self.commit("feat: a")
        after = self.commit("fixup! feat: a")
        self.assertEqual(self.check_range(f"{before}..{after}").returncode, 1)

    def test_first_push_checks_only_the_newest_commit(self):
        self.commit("Old message from before the rule")
        good = self.commit("feat: a")
        self.assertEqual(self.check_range(f"{ZEROS}..{good}").returncode, 0)
        bad = self.commit("Add a thing")
        self.assertEqual(self.check_range(f"{ZEROS}..{bad}").returncode, 1)

    def test_before_missing_after_a_force_push_checks_only_the_newest_commit(self):
        self.commit("Old message from before the rule")
        good = self.commit("feat: a")
        self.assertEqual(self.check_range(f"{'a' * 40}..{good}").returncode, 0)

    def test_an_unknown_before_is_named_on_stderr(self):
        self.commit("feat: a")
        self.commit("Add a thing")
        good = self.commit("fix: b")
        for before in ("orgin/main", ZEROS, "a" * 40):
            result = self.check_range(f"{before}..{good}")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Checked 1 commit(s)", result.stdout)
            self.assertIn(f"'{before}'", result.stderr)
            self.assertIn("only the newest commit was checked", result.stderr)

    def test_an_unknown_before_keeps_the_failure_of_the_newest_commit(self):
        self.commit("feat: a")
        bad = self.commit("Add a thing")
        result = self.check_range(f"orgin/main..{bad}")
        self.assertEqual(result.returncode, 1)
        self.assertIn("only the newest commit was checked", result.stderr)
        self.assertIn("Commit rule", result.stderr)

    def test_a_known_before_adds_nothing_on_stderr(self):
        before = self.commit("feat: a")
        after = self.commit("fix: b")
        self.assertEqual(self.check_range(f"{before}..{after}").stderr, "")

    def test_root_commit_on_its_own(self):
        root = self.commit("feat: a")
        self.assertEqual(self.check_range(f"{ZEROS}..{root}").returncode, 0)

    def test_nothing_new_passes(self):
        head = self.commit("feat: a")
        result = self.check_range(f"{head}..{head}")
        self.assertEqual(result.returncode, 0)
        self.assertIn("Checked 0 commit(s)", result.stdout)

    def test_unknown_after_cannot_check(self):
        before = self.commit("feat: a")
        self.assertEqual(self.check_range(f"{before}..{'a' * 40}").returncode, 2)

    def test_badly_formed_range_cannot_check(self):
        head = self.commit("feat: a")
        for value in (head, f"{head}..", f"{head}...{head}"):
            self.assertEqual(self.check_range(value).returncode, 2, value)

    def test_outside_a_repo_cannot_check(self):
        with tempfile.TemporaryDirectory() as folder:
            result = subprocess.run(
                [sys.executable, "-I", str(SCRIPT), f"--range={ZEROS}..HEAD"],
                cwd=folder, env=CLEAN_ENV, capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 2)


class CommentPrefix(Repo):
    def check_file(self, text):
        path = Path(self.repo) / ".git" / "typed-message"
        path.write_text(text, encoding="utf-8")
        return subprocess.run(
            [sys.executable, "-I", str(SCRIPT), f"--message-file={path}"],
            cwd=self.repo, env=CLEAN_ENV, capture_output=True, text=True,
        ).returncode

    def test_the_default_is_a_hash(self):
        self.assertEqual(self.check_file("# note\n\nfeat: a\n"), 0)
        self.assertEqual(self.check_file("; note\n\nfeat: a\n"), 1)

    def test_comment_char(self):
        self.git("config", "core.commentChar", ";")
        self.assertEqual(self.check_file("; note\n\nfeat: a\n"), 0)
        self.assertEqual(self.check_file("# note\n\nfeat: a\n"), 1)

    def test_comment_string_is_read_first(self):
        self.git("config", "core.commentChar", ";")
        self.git("config", "core.commentString", "//")
        self.assertEqual(self.check_file("// note\n\nfeat: a\n"), 0)
        self.assertEqual(self.check_file("; note\n\nfeat: a\n"), 1)

    def test_auto_counts_as_a_hash(self):
        self.git("config", "core.commentChar", "auto")
        self.assertEqual(self.check_file("# note\n\nfeat: a\n"), 0)
        self.assertEqual(self.check_file("automatic note\n\nfeat: a\n"), 1)


class Hook(Repo):
    def setUp(self):
        super().setUp()
        (Path(self.repo) / "scripts").mkdir()
        shutil.copy2(SCRIPT, Path(self.repo) / "scripts")
        (Path(self.repo) / ".githooks").mkdir()
        shutil.copy2(HOOK, Path(self.repo) / ".githooks")
        self.git("config", "core.hooksPath", ".githooks")

    def try_commit(self, message):
        return subprocess.run(
            ["git", "commit", "--allow-empty", "-m", message],
            cwd=self.repo, env=CLEAN_ENV, capture_output=True, text=True,
        )

    def run_git(self, *args, editor=None):
        env = CLEAN_ENV if editor is None else {**CLEAN_ENV, "GIT_EDITOR": editor}
        return subprocess.run(
            ["git", *args], cwd=self.repo, env=env, capture_output=True, text=True
        )

    def edit_commit(self, typed, *flags):
        """Commit through a real editor session that types this above git's own text."""
        path = Path(self.repo) / ".git" / "typed-message"
        path.write_text(typed, encoding="utf-8")
        editor = f"""sh -c 'cat "$0" "$1" > "$1.new" && mv "$1.new" "$1"' '{path}'"""
        return self.run_git("commit", "--allow-empty", *flags, editor=editor)

    def subject(self):
        return self.git("log", "-1", "--format=%s")

    def assert_refused(self, result, label=None):
        self.assertNotEqual(result.returncode, 0, label)
        self.assertIn("Commit rule", result.stderr, label)

    def assert_no_commit(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.git("rev-parse", "--verify", "HEAD")

    def test_hook_file_is_executable(self):
        self.assertTrue(os.access(HOOK, os.X_OK))

    def test_missing_python_warns_and_lets_the_commit_through(self):
        with tempfile.TemporaryDirectory() as empty:
            result = subprocess.run(
                ["/bin/sh", str(HOOK), "unused"],
                cwd=self.repo, env={"PATH": empty}, capture_output=True, text=True,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("skipping", result.stderr)

    def test_good_message_commits(self):
        result = self.try_commit("feat: a")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_bad_message_is_refused(self):
        result = self.try_commit("Add a thing")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Commit rule", result.stderr)
        with self.assertRaises(subprocess.CalledProcessError):
            self.git("rev-parse", "--verify", "HEAD")

    def test_with_m_comment_lines_are_checked(self):
        for message in (
            "#42 Add a thing",
            "# Add a thing",
            "# note\n\nfeat: a",
            "feat: a\n# note\n\nbody",
            f"feat: a\n{SCISSORS}\nNot a rule",
        ):
            self.assert_refused(self.try_commit(message), message)
        self.assert_no_commit()

    def test_with_m_a_hash_in_the_body_is_kept(self):
        result = self.try_commit("feat: a\n\n#42 is the issue")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("#42 is the issue", self.git("log", "-1", "--format=%B"))

    def test_with_a_file_comment_lines_are_checked(self):
        path = Path(self.repo) / ".git" / "typed-message"
        path.write_text("#42 Add a thing\n", encoding="utf-8")
        self.assert_refused(self.run_git("commit", "--allow-empty", "-F", str(path)))
        self.assert_no_commit()

    def test_with_no_editor_an_empty_message_is_refused(self):
        result = self.run_git("commit", "--allow-empty", "--allow-empty-message", "-m", "")
        self.assert_refused(result)
        self.assertIn("the message is empty", result.stderr)
        self.assert_no_commit()

    def test_amend_with_no_edit_and_reuse_check_the_text_as_written(self):
        self.git("commit", "-q", "--allow-empty", "--no-verify", "-m", "#42 Add a thing")
        self.assert_refused(self.run_git("commit", "--allow-empty", "--amend", "--no-edit"))
        self.assert_refused(self.run_git("commit", "--allow-empty", "-C", "HEAD"))
        self.git("commit", "-q", "--allow-empty", "--no-verify", "--amend", "-m", "feat: a")
        result = self.run_git("commit", "--allow-empty", "--amend", "--no-edit")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_with_m_in_progress_subjects_still_get_through(self):
        for message in ("feat: a", "Merge sort added", "squash! feat: a", "amend! feat: a"):
            result = self.try_commit(message)
            self.assertEqual(result.returncode, 0, result.stderr)
        result = self.run_git("commit", "--allow-empty", "--fixup=HEAD")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_in_an_editor_comments_are_removed(self):
        result = self.edit_commit("# note\n\nfeat: a\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.subject(), "feat: a")

    def test_in_an_editor_a_bad_message_is_refused(self):
        self.assert_refused(self.edit_commit("Add a thing\n"))
        self.assert_no_commit()

    def test_in_an_editor_git_refuses_an_empty_message_itself(self):
        for typed in ("", "#42 Add a thing\n"):
            result = self.edit_commit(typed)
            self.assertNotEqual(result.returncode, 0, typed)
            self.assertNotIn("Commit rule", result.stderr, typed)
        self.assert_no_commit()

    def test_in_an_editor_whitespace_at_the_end_of_a_line_is_removed(self):
        self.assert_refused(self.edit_commit("feat: a.  \n\nbody\n"))
        result = self.edit_commit(LONGEST + "  \n\nbody\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.subject(), LONGEST)
        result = self.edit_commit('Revert "a"  \n\nbody\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.subject(), 'Revert "a"')

    def test_comment_char_from_git_config(self):
        self.git("config", "core.commentChar", ";")
        self.assert_refused(self.edit_commit("#123 broken\n\nfeat: a\n"))
        result = self.edit_commit("; note\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Commit rule", result.stderr)
        self.assert_no_commit()
        result = self.edit_commit("; note\n\nfeat: a\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.subject(), "feat: a")

    def test_comment_char_with_verbose(self):
        self.git("config", "core.commentChar", ";")
        (Path(self.repo) / "file").write_text("Not a rule\n", encoding="utf-8")
        self.git("add", "file")
        result = self.edit_commit("", "-v")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Commit rule", result.stderr)
        result = self.edit_commit("feat: a\n", "-v")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git("log", "-1", "--format=%B"), "feat: a")

    def test_merge_commit_gets_through(self):
        self.try_commit("feat: a")
        self.git("checkout", "-q", "-b", "side")
        self.try_commit("fix: b")
        self.git("checkout", "-q", "main")
        self.try_commit("fix: c")
        result = subprocess.run(
            ["git", "merge", "--no-ff", "--no-edit", "side"],
            cwd=self.repo, env=CLEAN_ENV, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
