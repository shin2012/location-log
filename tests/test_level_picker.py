"""층 선택이 일시적인 시스템 메뉴로 되돌아가지 않는 구성 회귀 시험.
실제 스크롤·손 뗌·선택 동작은 ios/UITests/LevelPickerTests.swift에서 검증한다.
"""
from pathlib import Path
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "ios/LocationLog/Views/TimelineScreen.swift"


class LevelPickerTests(unittest.TestCase):
    def test_scrollable_levels_have_independent_presentation(self):
        source = SOURCE.read_text()
        menu = source.split("struct LevelMenu: View {", 1)[1].split("struct FloorRow: View {", 1)[0]
        self.assertNotIn("Menu {", menu)
        self.assertIn(".sheet(isPresented:", menu)
        self.assertIn('accessibilityIdentifier("level-picker-list")', menu)
        self.assertIn('accessibilityIdentifier("level-option-\\(lv)")', menu)
        self.assertIn(".disabled(busy)", menu)


if __name__ == "__main__":
    unittest.main()
