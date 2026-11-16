"""층 표시에서 머묾과 이동 설명이 다시 섞이지 않도록 하는 구성 회귀 시험."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class FloorLayoutTests(unittest.TestCase):
    def test_arrival_icon_belongs_to_explanation_not_stay(self):
        source = (ROOT / "ios/LocationLog/Views/TimelineScreen.swift").read_text()
        row = source.split("struct FloorRow: View {", 1)[1].split("struct SubRow: View {", 1)[0]
        self.assertIn('Label(v, systemImage: floor.viaSymbol', row)
        self.assertNotIn('Image(systemName: floor.via == nil', row)
        self.assertIn('Text("머묾")', row)
        self.assertLess(row.index('Label(v,'), row.index('Text("머묾")'))
        self.assertIn('ViewThatFits(in: .horizontal)', row)
        self.assertIn('LevelMenu(level: floor.level', row)


if __name__ == "__main__":
    unittest.main()
