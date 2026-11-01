"""Guidance and API regressions without loading or downloading ML models.

Run with: python -m unittest discover -s backend/tests -v
"""

import importlib.util
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

import cv2
import numpy as np
from fastapi.testclient import TestClient


BACKEND_DIR = Path(__file__).resolve().parents[1]


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


# Replace only the model packages at import time. Test the actual frame pipeline
# and HTTP endpoint, including image decoding and their real result contract.
with patch.dict(
    sys.modules,
    {
        "torch": SimpleNamespace(),
        "ultralytics": SimpleNamespace(YOLO=Mock(return_value=Mock())),
        "paddleocr": SimpleNamespace(PaddleOCR=Mock(return_value=Mock())),
    },
):
    pipeline = load_module("guidance_test_pipeline", BACKEND_DIR / "pipeline.py")

with patch.dict(sys.modules, {"pipeline": pipeline}):
    api = load_module("guidance_test_api", BACKEND_DIR / "main.py")


def box(class_id, coords):
    return SimpleNamespace(cls=[class_id], xyxy=[coords])


class GuidancePipelineTests(unittest.TestCase):
    def setUp(self):
        self.frame = np.zeros((100, 200, 3), dtype=np.uint8)
        self.model = Mock(return_value=[SimpleNamespace(boxes=[])])
        self.ocr = Mock()
        self.ocr.predict.return_value = []
        self.model_patch = patch.object(pipeline, "model", self.model)
        self.ocr_patch = patch.object(pipeline, "ocr", self.ocr)
        self.model_patch.start()
        self.ocr_patch.start()
        self.addCleanup(self.model_patch.stop)
        self.addCleanup(self.ocr_patch.stop)

    def detections(self, *boxes):
        self.model.return_value = [SimpleNamespace(boxes=list(boxes))]

    def bus_and_panel(self, texts, scores):
        self.detections(box(0, (50, 25, 150, 75)), box(1, (80, 30, 120, 40)))
        self.ocr.predict.return_value = [{"rec_texts": texts, "rec_scores": scores}]

    def test_central_bus_without_panel_guides_without_running_ocr(self):
        self.detections(box(0, (50, 25, 150, 75)))

        result = pipeline.process_frame(self.frame)

        self.assertTrue(result.bus_in_guidance_zone)
        self.assertIsNone(result.route_number)
        self.ocr.predict.assert_not_called()
        self.model.assert_called_once_with(self.frame, verbose=False)

    def test_no_bus_never_guides_even_with_panel(self):
        self.detections(box(1, (80, 30, 120, 40)))

        result = pipeline.process_frame(self.frame)

        self.assertFalse(result.bus_in_guidance_zone)
        self.assertIsNone(result.route_number)
        self.ocr.predict.assert_not_called()

    def test_any_bus_can_supply_guidance(self):
        self.detections(box(0, (0, 0, 20, 20)), box(0, (50, 25, 150, 75)))

        self.assertTrue(pipeline.process_frame(self.frame).bus_in_guidance_zone)

    def test_guidance_is_recomputed_for_each_frame(self):
        for coords, expected in [
            ((50, 25, 150, 75), True),
            ((0, 0, 20, 20), False),
            ((50, 25, 150, 75), True),
        ]:
            with self.subTest(coords=coords):
                self.detections(box(0, coords))
                self.assertEqual(
                    pipeline.process_frame(self.frame).bus_in_guidance_zone,
                    expected,
                )
        self.detections()
        self.assertFalse(pipeline.process_frame(self.frame).bus_in_guidance_zone)

    def test_zone_checks_horizontal_and_vertical_center_including_edges(self):
        # For this 200x100 frame the zone is x=40..160, y=20..80.
        for center_x, center_y, expected in [
            (40, 20, True),
            (160, 80, True),
            (39, 50, False),
            (161, 50, False),
            (100, 19, False),
            (100, 81, False),
        ]:
            with self.subTest(center=(center_x, center_y)):
                coords = (center_x - 5, center_y - 5, center_x + 5, center_y + 5)
                self.assertEqual(
                    pipeline.bus_center_in_guidance_zone(coords, self.frame.shape),
                    expected,
                )

    def test_bus_center_is_used_even_when_most_box_area_is_outside_zone(self):
        self.detections(box(0, (0, 0, 80, 40)))

        self.assertTrue(pipeline.process_frame(self.frame).bus_in_guidance_zone)

    def test_guidance_dimensions_can_be_tuned_independently(self):
        self.detections(box(0, (35, 45, 45, 55)))
        self.assertTrue(pipeline.process_frame(self.frame).bus_in_guidance_zone)
        self.assertFalse(
            pipeline.process_frame(
                self.frame, guidance_zone_width=0.4, guidance_zone_height=0.8
            ).bus_in_guidance_zone
        )
        self.detections(box(0, (95, 20, 105, 30)))
        self.assertFalse(
            pipeline.process_frame(
                self.frame, guidance_zone_width=0.8, guidance_zone_height=0.4
            ).bus_in_guidance_zone
        )

    def test_invalid_zone_fractions_are_rejected(self):
        for fraction in (0, -0.1, 1.1):
            with self.subTest(fraction=fraction):
                with self.assertRaises(ValueError):
                    pipeline.bus_center_in_guidance_zone(
                        (50, 25, 150, 75), self.frame.shape, fraction, 0.6
                    )

    def test_invalid_frame_has_no_guidance_and_does_not_run_models(self):
        for frame in (None, np.empty((0, 0, 3), dtype=np.uint8)):
            with self.subTest(frame=frame):
                result = pipeline.process_frame(frame)
                self.assertFalse(result.bus_in_guidance_zone)
                self.assertIsNone(result.route_number)
        self.model.assert_not_called()
        self.ocr.predict.assert_not_called()

    def test_guidance_survives_failed_ocr(self):
        self.bus_and_panel([], [])
        self.ocr.predict.side_effect = RuntimeError("OCR unavailable")

        result = pipeline.process_frame(self.frame)

        self.assertTrue(result.bus_in_guidance_zone)
        self.assertIsNone(result.route_number)

    def test_guidance_survives_unrecognized_route(self):
        self.bus_and_panel(["BUS", "12345", "72"], [0.99, 0.99, 0.35])

        result = pipeline.process_frame(self.frame)

        self.assertTrue(result.bus_in_guidance_zone)
        self.assertIsNone(result.route_number)

    def test_route_validation_keeps_first_valid_digit_sequence(self):
        self.bus_and_panel(
            ["BUS", "12345", "99", "Route 007", "1234"],
            [0.99, 0.99, 0.35, 0.36, 0.99],
        )

        result = pipeline.process_frame(self.frame)

        self.assertEqual(result.route_number, "007")
        self.assertTrue(result.bus_in_guidance_zone)

    def test_route_recognition_remains_available_outside_guidance_zone(self):
        self.detections(box(0, (0, 0, 30, 80)), box(1, (5, 10, 25, 20)))
        self.ocr.predict.return_value = [{"rec_texts": ["42"], "rec_scores": [0.9]}]

        result = pipeline.process_frame(self.frame)

        self.assertEqual(result.route_number, "42")
        self.assertFalse(result.bus_in_guidance_zone)

    def test_panel_outside_bus_still_cannot_trigger_ocr(self):
        self.detections(box(0, (50, 25, 150, 75)), box(1, (0, 0, 20, 10)))

        result = pipeline.process_frame(self.frame)

        self.assertTrue(result.bus_in_guidance_zone)
        self.assertIsNone(result.route_number)
        self.ocr.predict.assert_not_called()


class DetectionApiTests(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(api.app)
        self.addCleanup(self.client.close)
        success, encoded = cv2.imencode(".jpg", np.zeros((100, 200, 3), np.uint8))
        self.assertTrue(success)
        self.image = encoded.tobytes()

    def post_frame(self, image=None):
        return self.client.post(
            "/api/v1/detect",
            files={"image": ("frame.jpg", self.image if image is None else image, "image/jpeg")},
        )

    def assert_result(self, response, route="", guidance=False):
        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            response.json(),
            {
                "detected": bool(route),
                "route_number": route,
                "confidence": 0.0,
                "bus_in_guidance_zone": guidance,
            },
        )

    def test_guidance_is_exposed_without_a_recognized_route(self):
        with patch.object(
            api, "process_frame", return_value=pipeline.FrameDetectionResult(bus_in_guidance_zone=True)
        ):
            self.assert_result(self.post_frame(), guidance=True)

    def test_route_detection_and_guidance_are_independent_api_fields(self):
        for guidance in (False, True):
            with self.subTest(guidance=guidance), patch.object(
                api, "process_frame", return_value=pipeline.FrameDetectionResult("42", guidance)
            ):
                self.assert_result(self.post_frame(), route="42", guidance=guidance)

    def test_no_detection_preserves_existing_empty_response_fields(self):
        with patch.object(api, "process_frame", return_value=pipeline.FrameDetectionResult()):
            self.assert_result(self.post_frame())

    def test_invalid_and_empty_images_report_no_guidance(self):
        with patch.object(api, "process_frame") as process_frame:
            for payload in (b"not an image", b""):
                with self.subTest(payload=payload):
                    self.assert_result(self.post_frame(payload))
            process_frame.assert_not_called()

    def test_pipeline_failure_reports_no_guidance(self):
        with patch.object(api, "process_frame", side_effect=RuntimeError("Detection unavailable")):
            self.assert_result(self.post_frame())


if __name__ == "__main__":
    unittest.main()
