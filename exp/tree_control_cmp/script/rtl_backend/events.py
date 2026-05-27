import json
from pathlib import Path
from typing import Any, Dict, List

from rtl_backend.compat import dataclass, field

@dataclass
class EventRecord:
    cycle: int
    event: str
    source: str = "rtl"
    fields: Dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> Dict[str, Any]:
        payload = {
            "cycle": self.cycle,
            "event": self.event,
            "source": self.source,
        }
        payload.update(self.fields)
        return payload

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "EventRecord":
        fields = dict(data)
        cycle = int(fields.pop("cycle"))
        event = str(fields.pop("event"))
        source = str(fields.pop("source", "rtl"))
        return cls(cycle=cycle, event=event, source=source, fields=fields)


@dataclass
class EventLog:
    records: List[EventRecord] = field(default_factory=list)

    def append(self, record: EventRecord) -> None:
        self.records.append(record)

    def save(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        lines = [json.dumps(record.to_dict(), ensure_ascii=False) for record in self.records]
        path.write_text(
            ("\n".join(lines) + ("\n" if lines else "")),
            encoding="utf-8",
        )

    @classmethod
    def load(cls, path: Path) -> "EventLog":
        records = []
        if not path.exists():
            return cls(records=records)
        for line in path.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if not stripped:
                continue
            records.append(EventRecord.from_dict(json.loads(stripped)))
        return cls(records=records)
