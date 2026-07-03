"""test_findings.py — unit tests for the findings stream emit helper.

Covers:
  - Schema validation (required fields, enum values, sub_method nullity,
    accepted boolean, ts shape).
  - emit() appends a conforming record to the correct monthly JSONL file.
  - emit() creates the output directory and file on first write.
  - emit_many() batches records into per-month files.
  - CLI smoke-test (--record flag and individual-field flags).
  - validate_telemetry.check_findings_quality() coverage:
      - empty stream → info, no fails
      - clean records → pass
      - missing required field → fail
      - bad method enum → fail
      - sub_method / method mismatch → fail
      - bad finding_type → fail
      - accepted non-boolean → fail
"""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from io import StringIO
from pathlib import Path
from contextlib import redirect_stderr

# Make sure both modules are importable from the scripts directory.
sys.path.insert(0, str(Path(__file__).parent))
sys.path.insert(0, str(Path(__file__).parent / "drain"))

import findings as f_mod  # noqa: E402
import validate_telemetry as vt  # noqa: E402

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_TS = "2026-06-13T10:00:00Z"
_MONTH = "2026-06"


def _good_record(**overrides) -> dict:
    """Return a minimal valid v2 findings record, with optional overrides."""
    base = {
        "schema_version": "2",
        "ts": _TS,
        "session_id": "abc123",
        "project": "foundation",
        "method": "drain-lexicon",
        "sub_method": "Lesson:",
        "finding_type": "decision",
        "finding_ref": "Decisions/foundation - Foo.md",
        "accepted": True,
        "subject_model": "claude-opus-4-8",
        "analyst_model": "claude-opus-4-8",
    }
    base.update(overrides)
    return base


def _good_v1_record(**overrides) -> dict:
    """Return a minimal valid *legacy v1* findings record (no model fields)."""
    base = {
        "schema_version": "1",
        "ts": _TS,
        "session_id": "abc123",
        "project": "foundation",
        "method": "drain-lexicon",
        "sub_method": "Lesson:",
        "finding_type": "decision",
        "finding_ref": "Decisions/foundation - Foo.md",
        "accepted": True,
    }
    base.update(overrides)
    return base


# ---------------------------------------------------------------------------
# Validation tests
# ---------------------------------------------------------------------------


class TestValidateRecord(unittest.TestCase):

    def test_valid_lexicon_record_passes(self):
        f_mod.validate_record(_good_record())

    def test_valid_model_skim_record_passes(self):
        f_mod.validate_record(
            _good_record(method="drain-model-skim", sub_method=None)
        )

    def test_missing_required_field_raises(self):
        for field in f_mod._REQUIRED_FIELDS:
            with self.subTest(field=field):
                bad = _good_record()
                del bad[field]
                with self.assertRaises(f_mod.FindingsValidationError):
                    f_mod.validate_record(bad)

    def test_bad_schema_version_raises(self):
        with self.assertRaises(f_mod.FindingsValidationError):
            f_mod.validate_record(_good_record(schema_version="3"))

    # --- v2 model-provenance fields ------------------------------------

    def test_v1_legacy_record_passes(self):
        """A legacy v1 record (no model fields) still validates."""
        f_mod.validate_record(_good_v1_record())

    def test_v2_with_null_models_passes(self):
        """v2 model fields may be null (unknown model)."""
        f_mod.validate_record(
            _good_record(subject_model=None, analyst_model=None)
        )

    def test_v2_missing_subject_model_raises(self):
        bad = _good_record()
        del bad["subject_model"]
        with self.assertRaises(f_mod.FindingsValidationError):
            f_mod.validate_record(bad)

    def test_v2_missing_analyst_model_raises(self):
        bad = _good_record()
        del bad["analyst_model"]
        with self.assertRaises(f_mod.FindingsValidationError):
            f_mod.validate_record(bad)

    def test_v2_non_string_model_raises(self):
        with self.assertRaises(f_mod.FindingsValidationError):
            f_mod.validate_record(_good_record(subject_model=123))

    def test_v1_with_model_field_raises(self):
        """A v1 record must not carry the v2 model fields."""
        with self.assertRaises(f_mod.FindingsValidationError):
            f_mod.validate_record(
                _good_v1_record(subject_model="claude-opus-4-8")
            )

    def test_bad_method_raises(self):
        with self.assertRaises(f_mod.FindingsValidationError):
            f_mod.validate_record(_good_record(method="unknown-method"))

    def test_model_skim_with_sub_method_raises(self):
        with self.assertRaises(f_mod.FindingsValidationError):
            f_mod.validate_record(
                _good_record(method="drain-model-skim", sub_method="some-tell")
            )

    def test_lexicon_with_null_sub_method_raises(self):
        with self.assertRaises(f_mod.FindingsValidationError):
            f_mod.validate_record(_good_record(method="drain-lexicon", sub_method=None))

    def test_bad_finding_type_raises(self):
        with self.assertRaises(f_mod.FindingsValidationError):
            f_mod.validate_record(_good_record(finding_type="unknown-type"))

    def test_empty_finding_ref_raises(self):
        with self.assertRaises(f_mod.FindingsValidationError):
            f_mod.validate_record(_good_record(finding_ref=""))

    def test_accepted_non_bool_raises(self):
        with self.assertRaises(f_mod.FindingsValidationError):
            f_mod.validate_record(_good_record(accepted="true"))

    def test_bad_ts_raises(self):
        with self.assertRaises(f_mod.FindingsValidationError):
            f_mod.validate_record(_good_record(ts="not-a-timestamp"))

    def test_all_finding_types_valid(self):
        for ft in f_mod._VALID_FINDING_TYPES:
            with self.subTest(finding_type=ft):
                f_mod.validate_record(_good_record(finding_type=ft))


# ---------------------------------------------------------------------------
# Emit tests
# ---------------------------------------------------------------------------


class TestEmit(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.raw_dir = Path(self.tmp.name) / "raw"

    def tearDown(self):
        self.tmp.cleanup()

    def test_emit_creates_directory_and_file(self):
        """emit() creates the raw dir and monthly file on first write."""
        self.assertFalse(self.raw_dir.exists())
        path = f_mod.emit(_good_record(), self.raw_dir)
        self.assertTrue(path.exists())
        self.assertEqual(path.name, f"findings-{_MONTH}.jsonl")

    def test_emit_writes_conforming_record(self):
        """emit() writes exactly one line; the record round-trips through JSON."""
        path = f_mod.emit(_good_record(), self.raw_dir)
        lines = [l for l in path.read_text(encoding="utf-8").splitlines() if l.strip()]
        self.assertEqual(len(lines), 1)
        loaded = json.loads(lines[0])
        self.assertEqual(loaded["schema_version"], "2")
        self.assertEqual(loaded["subject_model"], "claude-opus-4-8")
        self.assertEqual(loaded["analyst_model"], "claude-opus-4-8")
        self.assertEqual(loaded["session_id"], "abc123")
        self.assertEqual(loaded["project"], "foundation")
        self.assertEqual(loaded["method"], "drain-lexicon")
        self.assertEqual(loaded["sub_method"], "Lesson:")
        self.assertEqual(loaded["finding_type"], "decision")
        self.assertEqual(loaded["finding_ref"], "Decisions/foundation - Foo.md")
        self.assertIs(loaded["accepted"], True)

    def test_emit_appends_multiple_records(self):
        """Multiple emit() calls append; each call adds exactly one line."""
        for i in range(3):
            f_mod.emit(
                _good_record(session_id=f"sess-{i}", finding_ref=f"Decisions/f - {i}.md"),
                self.raw_dir,
            )
        lines = [
            l
            for l in (self.raw_dir / f"findings-{_MONTH}.jsonl")
            .read_text(encoding="utf-8")
            .splitlines()
            if l.strip()
        ]
        self.assertEqual(len(lines), 3)

    def test_emit_defaults_schema_version_and_ts(self):
        """emit() fills in schema_version (v2) and ts when absent."""
        record = _good_record()
        del record["schema_version"]
        del record["ts"]
        path = f_mod.emit(record, self.raw_dir)
        loaded = json.loads(
            next(
                l for l in path.read_text(encoding="utf-8").splitlines() if l.strip()
            )
        )
        self.assertEqual(loaded["schema_version"], "2")
        self.assertTrue(loaded["ts"])  # non-empty auto-filled timestamp

    def test_emit_defaults_model_fields_to_null(self):
        """emit() defaults missing v2 model fields to null so v2 stays valid."""
        record = _good_record()
        del record["subject_model"]
        del record["analyst_model"]
        path = f_mod.emit(record, self.raw_dir)
        loaded = json.loads(
            next(
                l for l in path.read_text(encoding="utf-8").splitlines() if l.strip()
            )
        )
        self.assertIsNone(loaded["subject_model"])
        self.assertIsNone(loaded["analyst_model"])

    def test_emit_raises_on_invalid_record(self):
        """emit() raises FindingsValidationError for schema violations."""
        with self.assertRaises(f_mod.FindingsValidationError):
            f_mod.emit(_good_record(method="bad-method"), self.raw_dir)

    def test_emit_many_batches_by_month(self):
        """emit_many() writes each month's records to the correct file."""
        records = [
            _good_record(ts="2026-05-31T23:59:59Z", session_id="may-sess",
                         finding_ref="Decisions/f - may.md"),
            _good_record(ts="2026-06-01T00:00:01Z", session_id="jun-sess",
                         finding_ref="Decisions/f - jun.md"),
        ]
        paths = f_mod.emit_many(records, self.raw_dir)
        self.assertEqual(len(paths), 2)
        may_path = self.raw_dir / "findings-2026-05.jsonl"
        jun_path = self.raw_dir / "findings-2026-06.jsonl"
        self.assertTrue(may_path.exists())
        self.assertTrue(jun_path.exists())
        may_records = [
            json.loads(l)
            for l in may_path.read_text().splitlines()
            if l.strip()
        ]
        self.assertEqual(len(may_records), 1)
        self.assertEqual(may_records[0]["session_id"], "may-sess")


# ---------------------------------------------------------------------------
# CLI tests
# ---------------------------------------------------------------------------


class TestCLI(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.raw_dir = Path(self.tmp.name) / "raw"

    def tearDown(self):
        self.tmp.cleanup()

    def _run(self, argv):
        stderr_buf = StringIO()
        with redirect_stderr(stderr_buf):
            rc = f_mod.main(argv)
        return rc, stderr_buf.getvalue()

    def test_cli_record_flag(self):
        """--record flag accepts a full JSON record and appends it."""
        record = json.dumps(_good_record())
        rc, _ = self._run(["--record", record, "--raw-dir", str(self.raw_dir)])
        self.assertEqual(rc, 0)
        path = self.raw_dir / f"findings-{_MONTH}.jsonl"
        self.assertTrue(path.exists())

    def test_cli_individual_flags(self):
        """Individual-field flags build and emit a valid record."""
        rc, _ = self._run([
            "--session-id", "sess-cli",
            "--project", "foundation",
            "--method", "drain-model-skim",
            # sub-method must be absent / null for drain-model-skim
            "--finding-type", "friction",
            "--finding-ref", "friction-ledger.md",
            "--accepted",
            "--raw-dir", str(self.raw_dir),
        ])
        self.assertEqual(rc, 0)

    def test_cli_model_flags(self):
        """--subject-model / --analyst-model land on the emitted v2 record."""
        rc, _ = self._run([
            "--session-id", "sess-cli",
            "--project", "foundation",
            "--method", "drain-model-skim",
            "--finding-type", "friction",
            "--finding-ref", "friction-ledger.md",
            "--accepted",
            "--subject-model", "claude-sonnet-4-5",
            "--analyst-model", "claude-opus-4-8",
            # Pin the timestamp so the record lands in the asserted _MONTH file
            # regardless of the wall clock. Without this the CLI defaults ts to
            # datetime.now(UTC), which at a month boundary in UTC (e.g. CI running
            # 2026-07-01 UTC while local is 2026-06-30) writes findings-2026-07.jsonl
            # and this read of findings-2026-06.jsonl raises FileNotFoundError (#677).
            "--ts", _TS,
            "--raw-dir", str(self.raw_dir),
        ])
        self.assertEqual(rc, 0)
        path = self.raw_dir / f"findings-{_MONTH}.jsonl"
        loaded = json.loads(
            next(l for l in path.read_text().splitlines() if l.strip())
        )
        self.assertEqual(loaded["schema_version"], "2")
        self.assertEqual(loaded["subject_model"], "claude-sonnet-4-5")
        self.assertEqual(loaded["analyst_model"], "claude-opus-4-8")

    def test_cli_bad_json_returns_1(self):
        """--record with invalid JSON returns exit code 1."""
        rc, stderr = self._run(["--record", "{bad json}", "--raw-dir", str(self.raw_dir)])
        self.assertEqual(rc, 1)
        self.assertIn("not valid JSON", stderr)

    def test_cli_invalid_record_returns_1(self):
        """--record with a schema-violating record returns exit code 1."""
        bad = json.dumps(_good_record(method="bad-method"))
        rc, stderr = self._run(["--record", bad, "--raw-dir", str(self.raw_dir)])
        self.assertEqual(rc, 1)
        self.assertIn("validation", stderr)


# ---------------------------------------------------------------------------
# validate_telemetry coverage tests
# ---------------------------------------------------------------------------


class TestCheckFindingsQuality(unittest.TestCase):

    def test_empty_stream_is_ok(self):
        fails, info = vt.check_findings_quality([])
        self.assertEqual(fails, [])
        self.assertTrue(any("0 records" in i for i in info))

    def test_clean_records_pass(self):
        records = [
            _good_record(),
            _good_record(
                method="drain-model-skim",
                sub_method=None,
                finding_type="friction",
                finding_ref="ledger.md",
                accepted=False,
            ),
        ]
        fails, info = vt.check_findings_quality(records)
        self.assertEqual(fails, [], f"unexpected failures: {fails}")
        self.assertTrue(any("2 records" in i for i in info))

    def test_missing_required_field_detected(self):
        record = _good_record()
        del record["session_id"]
        fails, _ = vt.check_findings_quality([record])
        self.assertTrue(
            any("session_id" in f for f in fails),
            f"expected session_id failure, got: {fails}",
        )

    def test_bad_method_detected(self):
        record = _good_record(method="bogus-method")
        fails, _ = vt.check_findings_quality([record])
        self.assertTrue(any("method" in f for f in fails))

    def test_bad_sub_method_model_skim_detected(self):
        record = _good_record(method="drain-model-skim", sub_method="oops")
        fails, _ = vt.check_findings_quality([record])
        self.assertTrue(any("sub_method" in f for f in fails))

    def test_bad_finding_type_detected(self):
        record = _good_record(finding_type="invented-type")
        fails, _ = vt.check_findings_quality([record])
        self.assertTrue(any("finding_type" in f for f in fails))

    def test_bad_accepted_type_detected(self):
        record = _good_record(accepted="yes")
        fails, _ = vt.check_findings_quality([record])
        self.assertTrue(any("accepted" in f for f in fails))

    def test_v1_and_v2_records_both_pass(self):
        """The stream check accepts a mix of legacy v1 and current v2 records."""
        records = [
            _good_v1_record(),
            _good_record(subject_model=None, analyst_model=None),
        ]
        fails, _ = vt.check_findings_quality(records)
        self.assertEqual(fails, [], f"unexpected failures: {fails}")

    def test_v2_missing_model_field_detected(self):
        record = _good_record()
        del record["subject_model"]
        fails, _ = vt.check_findings_quality([record])
        self.assertTrue(
            any("subject_model" in f for f in fails),
            f"expected subject_model failure, got: {fails}",
        )

    def test_v2_non_string_model_detected(self):
        record = _good_record(analyst_model=99)
        fails, _ = vt.check_findings_quality([record])
        self.assertTrue(any("analyst_model" in f for f in fails))

    def test_v1_with_model_field_detected(self):
        record = _good_v1_record(subject_model="claude-opus-4-8")
        fails, _ = vt.check_findings_quality([record])
        self.assertTrue(
            any("subject_model" in f and "v2 field" in f for f in fails),
            f"expected v1+model-field failure, got: {fails}",
        )

    def test_bad_schema_version_three_detected(self):
        record = _good_record(schema_version="3")
        fails, _ = vt.check_findings_quality([record])
        self.assertTrue(any("schema_version" in f for f in fails))

    def test_accepted_and_rejected_counts_in_info(self):
        records = [
            _good_record(accepted=True),
            _good_record(accepted=False, finding_ref="Decisions/f - b.md"),
        ]
        _, info = vt.check_findings_quality(records)
        self.assertTrue(
            any("accepted" in i and "rejected" in i for i in info),
            f"expected accept/reject counts in info, got: {info}",
        )


if __name__ == "__main__":
    unittest.main()
