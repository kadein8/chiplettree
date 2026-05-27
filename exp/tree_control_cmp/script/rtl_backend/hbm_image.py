import json
from pathlib import Path
from typing import Any, Dict, Tuple

from rtl_backend.compat import dataclass, field
from rtl_backend.formats import (
    HBM_BEAT_BYTES,
    HbmLayout,
    build_default_hbm_layout,
    normalize_hex,
    read_json,
    write_json,
)


@dataclass
class HbmBeat:
    addr: int
    data_hex: str
    note: str = ""

    def to_dict(self) -> Dict[str, Any]:
        payload = {
            "addr": f"0x{self.addr:08x}",
            "data_hex": self.data_hex,
        }
        if self.note:
            payload["note"] = self.note
        return payload

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "HbmBeat":
        return cls(
            addr=int(str(data["addr"]), 16),
            data_hex=str(data["data_hex"]),
            note=str(data.get("note", "")),
        )


@dataclass
class HbmImage:
    layout: HbmLayout
    regions: Dict[str, Dict[int, HbmBeat]] = field(default_factory=dict)

    @classmethod
    def default(cls) -> "HbmImage":
        layout = build_default_hbm_layout()
        return cls(layout=layout, regions={region.name: {} for region in layout.regions})

    @classmethod
    def load(cls, root: Path) -> "HbmImage":
        layout = HbmLayout.from_dict(read_json(root / "manifest.json"))
        image = cls(layout=layout, regions={region.name: {} for region in layout.regions})
        regions_dir = root / "regions"
        for region in layout.regions:
            region_path = regions_dir / f"{region.name}.jsonl"
            if not region_path.exists():
                continue
            for line in region_path.read_text(encoding="utf-8").splitlines():
                stripped = line.strip()
                if not stripped:
                    continue
                beat = HbmBeat.from_dict(json.loads(stripped))
                image.regions[region.name][beat.addr] = beat
        return image

    def save(self, root: Path) -> None:
        root.mkdir(parents=True, exist_ok=True)
        regions_dir = root / "regions"
        regions_dir.mkdir(parents=True, exist_ok=True)
        write_json(root / "manifest.json", self.layout.to_dict())
        for region in self.layout.regions:
            region_path = regions_dir / f"{region.name}.jsonl"
            beats = self.regions.get(region.name, {})
            lines = [
                json.dumps(beats[addr].to_dict(), ensure_ascii=False)
                for addr in sorted(beats)
            ]
            region_path.write_text(
                ("\n".join(lines) + ("\n" if lines else "")),
                encoding="utf-8",
            )

    def write_region_hex(self, region_name: str, offset: int, data_hex: str, note: str = "") -> None:
        region = self.layout.region_by_name(region_name)
        if offset % self.layout.beat_bytes != 0:
            raise ValueError(f"offset {offset} is not aligned to beat size {self.layout.beat_bytes}")
        if offset < 0 or offset >= region.size:
            raise ValueError(f"offset {offset} is outside region {region_name}")
        addr = region.base + offset
        self.regions.setdefault(region_name, {})[addr] = HbmBeat(
            addr=addr,
            data_hex=normalize_hex(data_hex, self.layout.beat_bytes),
            note=note,
        )

    def write_absolute_hex(self, addr: int, data_hex: str, note: str = "") -> None:
        region_name, offset = self.resolve_region(addr)
        self.write_region_hex(region_name, offset, data_hex, note=note)

    def read_hex(self, region_name: str, offset: int) -> str:
        region = self.layout.region_by_name(region_name)
        addr = region.base + offset
        beat = self.regions.get(region_name, {}).get(addr)
        if beat is None:
            raise KeyError(f"no beat at region={region_name} offset={offset}")
        return beat.data_hex

    def resolve_region(self, addr: int) -> Tuple[str, int]:
        for region in self.layout.regions:
            if region.base <= addr < region.base + region.size:
                return region.name, addr - region.base
        raise KeyError(f"address 0x{addr:08x} is outside default HBM layout")

    def write_meta_text(self, text: str) -> None:
        encoded = text.encode("utf-8")
        chunks = [
            encoded[index : index + HBM_BEAT_BYTES]
            for index in range(0, len(encoded), HBM_BEAT_BYTES)
        ]
        if not chunks:
            chunks = [b""]
        for index, chunk in enumerate(chunks):
            self.write_region_hex(
                "META",
                index * HBM_BEAT_BYTES,
                chunk.hex(),
                note="utf8 meta chunk",
            )
