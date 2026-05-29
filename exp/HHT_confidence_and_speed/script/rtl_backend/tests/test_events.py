import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_ROOT = Path(__file__).resolve().parents[2]
if str(SCRIPT_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPT_ROOT))


from rtl_backend.events import EventLog, EventRecord  # type: ignore


class EventsTest(unittest.TestCase):
    def test_jsonl_round_trip(self) -> None:
        log = EventLog()
        log.append(
            EventRecord(
                cycle=17,
                event="hbm_write",
                source="rtl",
                fields={
                    "addr_hex": "0x20000000",
                    "data_hex": "ab" * 32,
                    "req_id": 3,
                },
            )
        )

        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "events.jsonl"
            log.save(path)
            restored = EventLog.load(path)

            self.assertEqual(len(restored.records), 1)
            self.assertEqual(restored.records[0].event, "hbm_write")
            self.assertEqual(restored.records[0].fields["data_hex"], "ab" * 32)


if __name__ == "__main__":
    unittest.main()
