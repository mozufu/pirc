import 'package:pirc_render/src/remote_content_gate.dart';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_mobile/live/common.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_document_styles.dart';
import 'package:pirc_mobile/theme.dart';

// Generated from the actual Chrome RGBA oracle; no images are injected.
const cases = [
  {
    "id": "conic-default-red-blue",
    "css": "conic-gradient(in srgb, red, blue)",
    "width": 120,
    "height": 120,
    "samples": [
      {
        "x": 57,
        "y": 11,
        "rgba": [2, 0, 253, 255],
      },
      {
        "x": 60,
        "y": 10,
        "rgba": [254, 0, 0, 255],
      },
      {
        "x": 63,
        "y": 11,
        "rgba": [253, 0, 3, 255],
      },
      {
        "x": 78,
        "y": 13,
        "rgba": [240, 0, 15, 255],
      },
      {
        "x": 95,
        "y": 25,
        "rgba": [223, 0, 33, 255],
      },
      {
        "x": 107,
        "y": 42,
        "rgba": [206, 0, 49, 255],
      },
      {
        "x": 110,
        "y": 60,
        "rgba": [190, 0, 64, 255],
      },
      {
        "x": 103,
        "y": 83,
        "rgba": [172, 0, 84, 255],
      },
      {
        "x": 86,
        "y": 101,
        "rgba": [151, 0, 105, 255],
      },
      {
        "x": 60,
        "y": 110,
        "rgba": [128, 0, 127, 255],
      },
      {
        "x": 36,
        "y": 103,
        "rgba": [108, 0, 148, 255],
      },
      {
        "x": 17,
        "y": 83,
        "rgba": [85, 0, 171, 255],
      },
      {
        "x": 10,
        "y": 60,
        "rgba": [64, 0, 190, 255],
      },
      {
        "x": 15,
        "y": 37,
        "rgba": [45, 0, 211, 255],
      },
      {
        "x": 31,
        "y": 19,
        "rgba": [25, 0, 231, 255],
      },
      {
        "x": 47,
        "y": 12,
        "rgba": [10, 0, 244, 255],
      },
    ],
  },
  {
    "id": "conic-from-angle-three-stops",
    "css": "conic-gradient(from 45deg in srgb, #f00, #0f0 34%, #00f)",
    "width": 140,
    "height": 140,
    "samples": [
      {
        "x": 70,
        "y": 12,
        "rgba": [0, 47, 207, 255],
      },
      {
        "x": 91,
        "y": 16,
        "rgba": [0, 25, 230, 255],
      },
      {
        "x": 110,
        "y": 30,
        "rgba": [253, 1, 0, 255],
      },
      {
        "x": 124,
        "y": 50,
        "rgba": [202, 52, 0, 255],
      },
      {
        "x": 127,
        "y": 72,
        "rgba": [156, 99, 0, 255],
      },
      {
        "x": 119,
        "y": 97,
        "rgba": [101, 155, 0, 255],
      },
      {
        "x": 101,
        "y": 116,
        "rgba": [45, 210, 0, 255],
      },
      {
        "x": 79,
        "y": 128,
        "rgba": [0, 251, 3, 255],
      },
      {
        "x": 56,
        "y": 125,
        "rgba": [0, 227, 28, 255],
      },
      {
        "x": 34,
        "y": 113,
        "rgba": [0, 199, 56, 255],
      },
      {
        "x": 17,
        "y": 92,
        "rgba": [0, 170, 85, 255],
      },
      {
        "x": 12,
        "y": 69,
        "rgba": [0, 144, 111, 255],
      },
      {
        "x": 18,
        "y": 46,
        "rgba": [0, 118, 136, 255],
      },
      {
        "x": 34,
        "y": 27,
        "rgba": [0, 91, 164, 255],
      },
      {
        "x": 52,
        "y": 16,
        "rgba": [0, 67, 187, 255],
      },
      {
        "x": 70,
        "y": 70,
        "rgba": [67, 187, 0, 255],
      },
    ],
  },
  {
    "id": "conic-offcenter-angle-units-and-outside-percent-stops",
    "css":
        "conic-gradient(from .25turn at 30% 65% in srgb, red -12%, orange 18%, lime 47%, blue 86%, white 118%)",
    "width": 160,
    "height": 120,
    "samples": [
      {
        "x": 48,
        "y": 12,
        "rgba": [0, 71, 183, 255],
      },
      {
        "x": 66,
        "y": 18,
        "rgba": [0, 40, 214, 255],
      },
      {
        "x": 82,
        "y": 34,
        "rgba": [0, 2, 253, 255],
      },
      {
        "x": 94,
        "y": 57,
        "rgba": [59, 59, 255, 255],
      },
      {
        "x": 90,
        "y": 82,
        "rgba": [255, 75, 0, 255],
      },
      {
        "x": 74,
        "y": 103,
        "rgba": [255, 133, 0, 255],
      },
      {
        "x": 51,
        "y": 112,
        "rgba": [207, 182, 0, 255],
      },
      {
        "x": 26,
        "y": 101,
        "rgba": [90, 223, 0, 255],
      },
      {
        "x": 10,
        "y": 82,
        "rgba": [0, 248, 7, 255],
      },
      {
        "x": 5,
        "y": 57,
        "rgba": [0, 189, 67, 255],
      },
      {
        "x": 9,
        "y": 35,
        "rgba": [0, 149, 107, 255],
      },
      {
        "x": 27,
        "y": 20,
        "rgba": [0, 107, 147, 255],
      },
      {
        "x": 48,
        "y": 58,
        "rgba": [0, 69, 185, 255],
      },
      {
        "x": 69,
        "y": 68,
        "rgba": [59, 59, 255, 255],
      },
      {
        "x": 43,
        "y": 90,
        "rgba": [145, 204, 0, 255],
      },
    ],
  },
  {
    "id": "conic-double-stops-hard-edges",
    "css":
        "conic-gradient(at 50% 50% in srgb, red 0deg 72deg, blue 72deg 181deg, lime 181deg 270deg, black 360deg)",
    "width": 120,
    "height": 120,
    "samples": [
      {
        "x": 61,
        "y": 12,
        "rgba": [255, 0, 0, 255],
      },
      {
        "x": 64,
        "y": 13,
        "rgba": [255, 0, 0, 255],
      },
      {
        "x": 65,
        "y": 14,
        "rgba": [255, 0, 0, 255],
      },
      {
        "x": 105,
        "y": 44,
        "rgba": [255, 0, 0, 255],
      },
      {
        "x": 106,
        "y": 47,
        "rgba": [0, 0, 255, 255],
      },
      {
        "x": 61,
        "y": 108,
        "rgba": [0, 0, 255, 255],
      },
      {
        "x": 58,
        "y": 108,
        "rgba": [0, 255, 0, 255],
      },
      {
        "x": 12,
        "y": 58,
        "rgba": [0, 250, 0, 255],
      },
      {
        "x": 12,
        "y": 62,
        "rgba": [0, 255, 0, 255],
      },
      {
        "x": 85,
        "y": 102,
        "rgba": [0, 0, 255, 255],
      },
      {
        "x": 80,
        "y": 103,
        "rgba": [0, 0, 255, 255],
      },
      {
        "x": 17,
        "y": 62,
        "rgba": [0, 255, 0, 255],
      },
      {
        "x": 17,
        "y": 57,
        "rgba": [0, 246, 0, 255],
      },
      {
        "x": 35,
        "y": 24,
        "rgba": [0, 98, 0, 255],
      },
      {
        "x": 52,
        "y": 21,
        "rgba": [0, 31, 0, 255],
      },
      {
        "x": 60,
        "y": 60,
        "rgba": [0, 0, 255, 255],
      },
    ],
  },
  {
    "id": "conic-negative-and-over-one-turn-stops",
    "css":
        "conic-gradient(from -35deg at 62% 43% in srgb, red -90deg, yellow 15deg, blue 390deg, lime 540deg)",
    "width": 150,
    "height": 120,
    "samples": [
      {
        "x": 93,
        "y": 8,
        "rgba": [241, 241, 14, 255],
      },
      {
        "x": 113,
        "y": 13,
        "rgba": [222, 222, 33, 255],
      },
      {
        "x": 133,
        "y": 33,
        "rgba": [197, 197, 59, 255],
      },
      {
        "x": 143,
        "y": 52,
        "rgba": [179, 179, 75, 255],
      },
      {
        "x": 139,
        "y": 78,
        "rgba": [160, 160, 95, 255],
      },
      {
        "x": 118,
        "y": 101,
        "rgba": [138, 138, 118, 255],
      },
      {
        "x": 93,
        "y": 111,
        "rgba": [120, 120, 136, 255],
      },
      {
        "x": 68,
        "y": 96,
        "rgba": [99, 99, 155, 255],
      },
      {
        "x": 50,
        "y": 76,
        "rgba": [78, 78, 176, 255],
      },
      {
        "x": 49,
        "y": 49,
        "rgba": [56, 56, 199, 255],
      },
      {
        "x": 61,
        "y": 28,
        "rgba": [33, 33, 222, 255],
      },
      {
        "x": 78,
        "y": 16,
        "rgba": [255, 249, 0, 255],
      },
      {
        "x": 93,
        "y": 51,
        "rgba": [188, 188, 68, 255],
      },
      {
        "x": 114,
        "y": 66,
        "rgba": [156, 156, 98, 255],
      },
    ],
  },
  {
    "id": "conic-transparent-alpha-interpolation",
    "css":
        "conic-gradient(from 17deg at 40% 60% in srgb, rgba(255, 0, 0, 0) -10deg, rgba(0, 200, 255, .8) 120deg, rgba(255, 255, 0, .35) 250deg, white 1turn)",
    "width": 140,
    "height": 120,
    "samples": [
      {
        "x": 56,
        "y": 7,
        "rgba": [255, 255, 241, 230],
      },
      {
        "x": 77,
        "y": 11,
        "rgba": [0, 204, 255, 20],
      },
      {
        "x": 99,
        "y": 25,
        "rgba": [0, 201, 255, 57],
      },
      {
        "x": 116,
        "y": 46,
        "rgba": [0, 201, 255, 94],
      },
      {
        "x": 119,
        "y": 69,
        "rgba": [0, 201, 255, 127],
      },
      {
        "x": 111,
        "y": 93,
        "rgba": [0, 202, 255, 163],
      },
      {
        "x": 91,
        "y": 110,
        "rgba": [0, 200, 254, 204],
      },
      {
        "x": 66,
        "y": 115,
        "rgba": [29, 206, 226, 178],
      },
      {
        "x": 43,
        "y": 108,
        "rgba": [72, 216, 183, 149],
      },
      {
        "x": 22,
        "y": 90,
        "rgba": [162, 235, 91, 112],
      },
      {
        "x": 14,
        "y": 66,
        "rgba": [255, 255, 58, 105],
      },
      {
        "x": 22,
        "y": 42,
        "rgba": [255, 255, 168, 156],
      },
      {
        "x": 42,
        "y": 23,
        "rgba": [255, 255, 223, 206],
      },
      {
        "x": 56,
        "y": 71,
        "rgba": [0, 200, 255, 60],
      },
    ],
  },
  {
    "id": "repeating-conic-nondivisor-period",
    "css":
        "repeating-conic-gradient(from 13deg at center in srgb, red 0deg, blue 83deg, lime 157deg)",
    "width": 120,
    "height": 120,
    "samples": [
      {
        "x": 69,
        "y": 13,
        "rgba": [118, 0, 137, 255],
      },
      {
        "x": 72,
        "y": 14,
        "rgba": [247, 0, 7, 255],
      },
      {
        "x": 99,
        "y": 30,
        "rgba": [131, 0, 124, 255],
      },
      {
        "x": 108,
        "y": 52,
        "rgba": [45, 0, 209, 255],
      },
      {
        "x": 104,
        "y": 75,
        "rgba": [0, 46, 210, 255],
      },
      {
        "x": 91,
        "y": 96,
        "rgba": [0, 149, 106, 255],
      },
      {
        "x": 70,
        "y": 107,
        "rgba": [0, 247, 9, 255],
      },
      {
        "x": 67,
        "y": 108,
        "rgba": [251, 0, 4, 255],
      },
      {
        "x": 47,
        "y": 103,
        "rgba": [176, 0, 80, 255],
      },
      {
        "x": 25,
        "y": 89,
        "rgba": [73, 0, 183, 255],
      },
      {
        "x": 12,
        "y": 65,
        "rgba": [0, 36, 219, 255],
      },
      {
        "x": 17,
        "y": 41,
        "rgba": [0, 140, 116, 255],
      },
      {
        "x": 32,
        "y": 21,
        "rgba": [0, 246, 9, 255],
      },
      {
        "x": 35,
        "y": 21,
        "rgba": [254, 0, 2, 255],
      },
      {
        "x": 60,
        "y": 42,
        "rgba": [148, 0, 106, 255],
      },
      {
        "x": 80,
        "y": 69,
        "rgba": [0, 65, 190, 255],
      },
      {
        "x": 42,
        "y": 83,
        "rgba": [112, 0, 144, 255],
      },
    ],
  },
  {
    "id": "repeating-conic-negative-start-offcenter",
    "css":
        "repeating-conic-gradient(from -20deg at 58% 47% in srgb, red -35deg, yellow 27deg, blue 72deg)",
    "width": 150,
    "height": 120,
    "samples": [
      {
        "x": 87,
        "y": 9,
        "rgba": [255, 229, 0, 255],
      },
      {
        "x": 108,
        "y": 13,
        "rgba": [144, 144, 111, 255],
      },
      {
        "x": 127,
        "y": 29,
        "rgba": [255, 18, 0, 255],
      },
      {
        "x": 139,
        "y": 53,
        "rgba": [255, 144, 0, 255],
      },
      {
        "x": 133,
        "y": 78,
        "rgba": [247, 247, 8, 255],
      },
      {
        "x": 116,
        "y": 99,
        "rgba": [76, 76, 179, 255],
      },
      {
        "x": 91,
        "y": 109,
        "rgba": [255, 67, 0, 255],
      },
      {
        "x": 67,
        "y": 99,
        "rgba": [255, 187, 0, 255],
      },
      {
        "x": 50,
        "y": 78,
        "rgba": [154, 154, 101, 255],
      },
      {
        "x": 48,
        "y": 53,
        "rgba": [255, 34, 0, 255],
      },
      {
        "x": 58,
        "y": 30,
        "rgba": [255, 190, 0, 255],
      },
      {
        "x": 74,
        "y": 16,
        "rgba": [255, 154, 0, 255],
      },
      {
        "x": 92,
        "y": 48,
        "rgba": [97, 97, 157, 255],
      },
      {
        "x": 114,
        "y": 64,
        "rgba": [255, 223, 0, 255],
      },
      {
        "x": 69,
        "y": 68,
        "rgba": [174, 174, 81, 255],
      },
    ],
  },
  {
    "id": "repeating-linear-pixel-period",
    "css": "repeating-linear-gradient(90deg in srgb, red 0px, blue 26px)",
    "width": 144,
    "height": 48,
    "samples": [
      {
        "x": 4,
        "y": 24,
        "rgba": [210, 0, 44, 255],
      },
      {
        "x": 13,
        "y": 24,
        "rgba": [122, 0, 132, 255],
      },
      {
        "x": 25,
        "y": 24,
        "rgba": [5, 0, 250, 255],
      },
      {
        "x": 29,
        "y": 24,
        "rgba": [220, 0, 34, 255],
      },
      {
        "x": 39,
        "y": 24,
        "rgba": [122, 0, 132, 255],
      },
      {
        "x": 51,
        "y": 24,
        "rgba": [5, 0, 250, 255],
      },
      {
        "x": 55,
        "y": 24,
        "rgba": [221, 0, 34, 255],
      },
      {
        "x": 65,
        "y": 24,
        "rgba": [122, 0, 132, 255],
      },
      {
        "x": 77,
        "y": 24,
        "rgba": [5, 0, 250, 255],
      },
      {
        "x": 81,
        "y": 24,
        "rgba": [220, 0, 34, 255],
      },
      {
        "x": 91,
        "y": 24,
        "rgba": [122, 0, 132, 255],
      },
      {
        "x": 103,
        "y": 24,
        "rgba": [5, 0, 250, 255],
      },
      {
        "x": 107,
        "y": 24,
        "rgba": [220, 0, 34, 255],
      },
      {
        "x": 117,
        "y": 24,
        "rgba": [122, 0, 132, 255],
      },
      {
        "x": 129,
        "y": 24,
        "rgba": [5, 0, 250, 255],
      },
      {
        "x": 139,
        "y": 24,
        "rgba": [162, 0, 93, 255],
      },
    ],
  },
  {
    "id": "repeating-linear-hard-stops-oblique",
    "css":
        "repeating-linear-gradient(45deg in srgb, red 0px 12px, blue 12px 27px)",
    "width": 140,
    "height": 100,
    "samples": [
      {
        "x": 5,
        "y": 8,
        "rgba": [0, 0, 255, 255],
      },
      {
        "x": 18,
        "y": 8,
        "rgba": [0, 0, 255, 255],
      },
      {
        "x": 31,
        "y": 18,
        "rgba": [0, 0, 255, 255],
      },
      {
        "x": 44,
        "y": 18,
        "rgba": [255, 0, 0, 255],
      },
      {
        "x": 57,
        "y": 28,
        "rgba": [255, 0, 0, 255],
      },
      {
        "x": 70,
        "y": 28,
        "rgba": [0, 0, 255, 255],
      },
      {
        "x": 83,
        "y": 38,
        "rgba": [0, 0, 255, 255],
      },
      {
        "x": 96,
        "y": 38,
        "rgba": [255, 0, 0, 255],
      },
      {
        "x": 109,
        "y": 48,
        "rgba": [255, 0, 0, 255],
      },
      {
        "x": 122,
        "y": 48,
        "rgba": [0, 0, 255, 255],
      },
      {
        "x": 24,
        "y": 79,
        "rgba": [255, 0, 0, 255],
      },
      {
        "x": 84,
        "y": 79,
        "rgba": [0, 0, 255, 255],
      },
      {
        "x": 134,
        "y": 89,
        "rgba": [0, 0, 255, 255],
      },
      {
        "x": 70,
        "y": 50,
        "rgba": [255, 0, 0, 255],
      },
    ],
  },
  {
    "id": "repeating-linear-percent-stops",
    "css":
        "repeating-linear-gradient(to right in srgb, red 0%, yellow 20%, blue 45%)",
    "width": 160,
    "height": 56,
    "samples": [
      {
        "x": 3,
        "y": 28,
        "rgba": [255, 28, 0, 255],
      },
      {
        "x": 14,
        "y": 28,
        "rgba": [255, 115, 0, 255],
      },
      {
        "x": 29,
        "y": 28,
        "rgba": [255, 235, 0, 255],
      },
      {
        "x": 36,
        "y": 28,
        "rgba": [226, 226, 28, 255],
      },
      {
        "x": 48,
        "y": 28,
        "rgba": [149, 149, 105, 255],
      },
      {
        "x": 62,
        "y": 28,
        "rgba": [60, 60, 194, 255],
      },
      {
        "x": 70,
        "y": 28,
        "rgba": [9, 9, 245, 255],
      },
      {
        "x": 83,
        "y": 28,
        "rgba": [255, 91, 0, 255],
      },
      {
        "x": 98,
        "y": 28,
        "rgba": [255, 211, 0, 255],
      },
      {
        "x": 108,
        "y": 28,
        "rgba": [226, 226, 28, 255],
      },
      {
        "x": 121,
        "y": 28,
        "rgba": [143, 143, 111, 255],
      },
      {
        "x": 136,
        "y": 28,
        "rgba": [47, 47, 207, 255],
      },
      {
        "x": 147,
        "y": 28,
        "rgba": [255, 28, 0, 255],
      },
      {
        "x": 157,
        "y": 28,
        "rgba": [255, 107, 0, 255],
      },
    ],
  },
  {
    "id": "repeating-linear-negative-pixel-start",
    "css":
        "repeating-linear-gradient(0deg in srgb, red -15px, yellow 5px, blue 35px)",
    "width": 100,
    "height": 100,
    "samples": [
      {
        "x": 50,
        "y": 4,
        "rgba": [255, 133, 0, 255],
      },
      {
        "x": 50,
        "y": 11,
        "rgba": [255, 45, 0, 255],
      },
      {
        "x": 50,
        "y": 21,
        "rgba": [55, 55, 200, 255],
      },
      {
        "x": 50,
        "y": 31,
        "rgba": [140, 140, 115, 255],
      },
      {
        "x": 50,
        "y": 39,
        "rgba": [208, 208, 47, 255],
      },
      {
        "x": 50,
        "y": 46,
        "rgba": [255, 236, 0, 255],
      },
      {
        "x": 50,
        "y": 56,
        "rgba": [255, 108, 0, 255],
      },
      {
        "x": 50,
        "y": 66,
        "rgba": [12, 12, 242, 255],
      },
      {
        "x": 50,
        "y": 74,
        "rgba": [80, 80, 174, 255],
      },
      {
        "x": 50,
        "y": 81,
        "rgba": [140, 140, 115, 255],
      },
      {
        "x": 50,
        "y": 91,
        "rgba": [225, 225, 30, 255],
      },
      {
        "x": 50,
        "y": 97,
        "rgba": [255, 223, 0, 255],
      },
      {
        "x": 20,
        "y": 30,
        "rgba": [131, 131, 123, 255],
      },
      {
        "x": 80,
        "y": 70,
        "rgba": [46, 46, 208, 255],
      },
    ],
  },
  {
    "id": "repeating-linear-zero-period",
    "css": "repeating-linear-gradient(90deg in srgb, red 20px, blue 20px)",
    "width": 120,
    "height": 40,
    "samples": [
      {
        "x": 4,
        "y": 20,
        "rgba": [0, 0, 255, 255],
      },
      {
        "x": 13,
        "y": 20,
        "rgba": [0, 0, 255, 255],
      },
      {
        "x": 25,
        "y": 20,
        "rgba": [0, 0, 255, 255],
      },
      {
        "x": 36,
        "y": 20,
        "rgba": [0, 0, 255, 255],
      },
      {
        "x": 48,
        "y": 20,
        "rgba": [0, 0, 255, 255],
      },
      {
        "x": 59,
        "y": 20,
        "rgba": [0, 0, 255, 255],
      },
      {
        "x": 71,
        "y": 20,
        "rgba": [0, 0, 255, 255],
      },
      {
        "x": 82,
        "y": 20,
        "rgba": [0, 0, 255, 255],
      },
      {
        "x": 94,
        "y": 20,
        "rgba": [0, 0, 255, 255],
      },
      {
        "x": 106,
        "y": 20,
        "rgba": [0, 0, 255, 255],
      },
      {
        "x": 115,
        "y": 20,
        "rgba": [0, 0, 255, 255],
      },
      {
        "x": 60,
        "y": 4,
        "rgba": [0, 0, 255, 255],
      },
    ],
  },
  {
    "id": "repeating-radial-circle-pixel-period",
    "css":
        "repeating-radial-gradient(circle 13px at center in srgb, red 0px, blue 13px)",
    "width": 120,
    "height": 100,
    "samples": [
      {
        "x": 60,
        "y": 50,
        "rgba": [241, 0, 14, 255],
      },
      {
        "x": 63,
        "y": 50,
        "rgba": [186, 0, 69, 255],
      },
      {
        "x": 68,
        "y": 50,
        "rgba": [88, 0, 167, 255],
      },
      {
        "x": 72,
        "y": 50,
        "rgba": [9, 0, 245, 255],
      },
      {
        "x": 74,
        "y": 50,
        "rgba": [225, 0, 29, 255],
      },
      {
        "x": 77,
        "y": 50,
        "rgba": [166, 0, 88, 255],
      },
      {
        "x": 82,
        "y": 50,
        "rgba": [68, 0, 186, 255],
      },
      {
        "x": 85,
        "y": 50,
        "rgba": [10, 0, 245, 255],
      },
      {
        "x": 87,
        "y": 50,
        "rgba": [225, 0, 29, 255],
      },
      {
        "x": 91,
        "y": 50,
        "rgba": [147, 0, 108, 255],
      },
      {
        "x": 96,
        "y": 50,
        "rgba": [49, 0, 206, 255],
      },
      {
        "x": 60,
        "y": 54,
        "rgba": [166, 0, 88, 255],
      },
      {
        "x": 60,
        "y": 62,
        "rgba": [9, 0, 245, 255],
      },
      {
        "x": 60,
        "y": 64,
        "rgba": [225, 0, 29, 255],
      },
      {
        "x": 60,
        "y": 68,
        "rgba": [147, 0, 108, 255],
      },
      {
        "x": 60,
        "y": 75,
        "rgba": [10, 0, 245, 255],
      },
      {
        "x": 60,
        "y": 77,
        "rgba": [226, 0, 30, 255],
      },
      {
        "x": 60,
        "y": 84,
        "rgba": [88, 0, 166, 255],
      },
      {
        "x": 60,
        "y": 93,
        "rgba": [167, 0, 88, 255],
      },
    ],
  },
  {
    "id": "repeating-radial-ellipse-percent-period",
    "css":
        "repeating-radial-gradient(ellipse 48px 24px at center in srgb, #ff3300 0%, #0044ff 100%)",
    "width": 140,
    "height": 100,
    "samples": [
      {
        "x": 70,
        "y": 50,
        "rgba": [249, 51, 6, 255],
      },
      {
        "x": 77,
        "y": 50,
        "rgba": [215, 54, 40, 255],
      },
      {
        "x": 86,
        "y": 50,
        "rgba": [167, 57, 88, 255],
      },
      {
        "x": 95,
        "y": 50,
        "rgba": [119, 60, 136, 255],
      },
      {
        "x": 103,
        "y": 50,
        "rgba": [77, 63, 178, 255],
      },
      {
        "x": 111,
        "y": 50,
        "rgba": [34, 66, 220, 255],
      },
      {
        "x": 116,
        "y": 50,
        "rgba": [8, 67, 247, 255],
      },
      {
        "x": 70,
        "y": 54,
        "rgba": [207, 54, 48, 255],
      },
      {
        "x": 70,
        "y": 61,
        "rgba": [133, 59, 122, 255],
      },
      {
        "x": 70,
        "y": 68,
        "rgba": [58, 64, 196, 255],
      },
      {
        "x": 70,
        "y": 74,
        "rgba": [249, 51, 5, 255],
      },
      {
        "x": 70,
        "y": 79,
        "rgba": [197, 55, 59, 255],
      },
      {
        "x": 87,
        "y": 62,
        "rgba": [93, 62, 162, 255],
      },
      {
        "x": 99,
        "y": 39,
        "rgba": [63, 64, 193, 255],
      },
      {
        "x": 42,
        "y": 63,
        "rgba": [50, 65, 205, 255],
      },
    ],
  },
  {
    "id": "repeating-radial-ellipse-offcenter-alpha",
    "css":
        "repeating-radial-gradient(ellipse 34px 22px at 28% 60% in srgb, rgba(255, 0, 0, .2) 0px, lime 17px, rgba(0, 0, 255, .65) 43px)",
    "width": 150,
    "height": 120,
    "samples": [
      {
        "x": 42,
        "y": 18,
        "rgba": [0, 46, 209, 177],
      },
      {
        "x": 50,
        "y": 23,
        "rgba": [0, 131, 125, 202],
      },
      {
        "x": 59,
        "y": 34,
        "rgba": [0, 252, 3, 253],
      },
      {
        "x": 66,
        "y": 48,
        "rgba": [201, 50, 0, 61],
      },
      {
        "x": 68,
        "y": 72,
        "rgba": [0, 185, 69, 222],
      },
      {
        "x": 59,
        "y": 90,
        "rgba": [0, 120, 135, 198],
      },
      {
        "x": 44,
        "y": 101,
        "rgba": [132, 123, 0, 83],
      },
      {
        "x": 27,
        "y": 96,
        "rgba": [0, 35, 220, 174],
      },
      {
        "x": 17,
        "y": 78,
        "rgba": [0, 185, 69, 223],
      },
      {
        "x": 16,
        "y": 55,
        "rgba": [0, 91, 164, 190],
      },
      {
        "x": 23,
        "y": 35,
        "rgba": [2, 254, 0, 247],
      },
      {
        "x": 42,
        "y": 61,
        "rgba": [2, 253, 0, 246],
      },
      {
        "x": 52,
        "y": 60,
        "rgba": [0, 230, 24, 243],
      },
      {
        "x": 38,
        "y": 73,
        "rgba": [96, 159, 0, 101],
      },
      {
        "x": 79,
        "y": 62,
        "rgba": [0, 39, 217, 175],
      },
    ],
  },
  {
    "id": "repeating-radial-circle-negative-start",
    "css":
        "repeating-radial-gradient(circle 38px at 72% 42% in srgb, red -9px, yellow 0px, blue 17px)",
    "width": 150,
    "height": 120,
    "samples": [
      {
        "x": 108,
        "y": 7,
        "rgba": [2, 2, 254, 255],
      },
      {
        "x": 119,
        "y": 13,
        "rgba": [66, 66, 190, 255],
      },
      {
        "x": 132,
        "y": 25,
        "rgba": [121, 121, 134, 255],
      },
      {
        "x": 141,
        "y": 43,
        "rgba": [132, 132, 123, 255],
      },
      {
        "x": 139,
        "y": 63,
        "rgba": [134, 134, 122, 255],
      },
      {
        "x": 128,
        "y": 83,
        "rgba": [61, 61, 194, 255],
      },
      {
        "x": 111,
        "y": 98,
        "rgba": [255, 148, 0, 255],
      },
      {
        "x": 91,
        "y": 91,
        "rgba": [255, 37, 0, 255],
      },
      {
        "x": 78,
        "y": 74,
        "rgba": [73, 73, 181, 255],
      },
      {
        "x": 77,
        "y": 53,
        "rgba": [185, 185, 70, 255],
      },
      {
        "x": 85,
        "y": 32,
        "rgba": [213, 213, 41, 255],
      },
      {
        "x": 98,
        "y": 20,
        "rgba": [174, 174, 80, 255],
      },
      {
        "x": 109,
        "y": 49,
        "rgba": [229, 229, 27, 255],
      },
      {
        "x": 124,
        "y": 55,
        "rgba": [255, 8, 0, 255],
      },
    ],
  },
  {
    "id": "repeating-radial-zero-period",
    "css": "repeating-radial-gradient(circle in srgb, red 10px, blue 10px)",
    "width": 120,
    "height": 90,
    "samples": [
      {
        "x": 60,
        "y": 45,
        "rgba": [0, 0, 255, 255],
      },
      {
        "x": 63,
        "y": 45,
        "rgba": [0, 0, 255, 255],
      },
      {
        "x": 72,
        "y": 45,
        "rgba": [0, 0, 255, 255],
      },
      {
        "x": 84,
        "y": 45,
        "rgba": [0, 0, 255, 255],
      },
      {
        "x": 96,
        "y": 45,
        "rgba": [0, 0, 255, 255],
      },
      {
        "x": 108,
        "y": 45,
        "rgba": [0, 0, 255, 255],
      },
      {
        "x": 60,
        "y": 49,
        "rgba": [0, 0, 255, 255],
      },
      {
        "x": 60,
        "y": 58,
        "rgba": [0, 0, 255, 255],
      },
      {
        "x": 60,
        "y": 69,
        "rgba": [0, 0, 255, 255],
      },
      {
        "x": 60,
        "y": 81,
        "rgba": [0, 0, 255, 255],
      },
      {
        "x": 25,
        "y": 25,
        "rgba": [0, 0, 255, 255],
      },
      {
        "x": 100,
        "y": 20,
        "rgba": [0, 0, 255, 255],
      },
    ],
  },
  {
    "id": "conic-default-red-blue-implicit-interpolation",
    "css": "conic-gradient(red, blue)",
    "width": 120,
    "height": 120,
    "samples": [
      {
        "x": 57,
        "y": 11,
        "rgba": [2, 0, 253, 255],
      },
      {
        "x": 60,
        "y": 10,
        "rgba": [254, 0, 0, 255],
      },
      {
        "x": 63,
        "y": 11,
        "rgba": [253, 0, 3, 255],
      },
      {
        "x": 78,
        "y": 13,
        "rgba": [240, 0, 15, 255],
      },
      {
        "x": 95,
        "y": 25,
        "rgba": [223, 0, 33, 255],
      },
      {
        "x": 107,
        "y": 42,
        "rgba": [206, 0, 49, 255],
      },
      {
        "x": 110,
        "y": 60,
        "rgba": [190, 0, 64, 255],
      },
      {
        "x": 103,
        "y": 83,
        "rgba": [172, 0, 84, 255],
      },
      {
        "x": 86,
        "y": 101,
        "rgba": [151, 0, 105, 255],
      },
      {
        "x": 60,
        "y": 110,
        "rgba": [128, 0, 127, 255],
      },
      {
        "x": 36,
        "y": 103,
        "rgba": [108, 0, 148, 255],
      },
      {
        "x": 17,
        "y": 83,
        "rgba": [85, 0, 171, 255],
      },
      {
        "x": 10,
        "y": 60,
        "rgba": [64, 0, 190, 255],
      },
      {
        "x": 15,
        "y": 37,
        "rgba": [45, 0, 211, 255],
      },
      {
        "x": 31,
        "y": 19,
        "rgba": [25, 0, 231, 255],
      },
      {
        "x": 47,
        "y": 12,
        "rgba": [10, 0, 244, 255],
      },
    ],
  },
  {
    "id": "repeating-conic-nondivisor-period-implicit-interpolation",
    "css":
        "repeating-conic-gradient(from 13deg at center, red 0deg, blue 83deg, lime 157deg)",
    "width": 120,
    "height": 120,
    "samples": [
      {
        "x": 69,
        "y": 13,
        "rgba": [118, 0, 137, 255],
      },
      {
        "x": 72,
        "y": 14,
        "rgba": [247, 0, 7, 255],
      },
      {
        "x": 99,
        "y": 30,
        "rgba": [131, 0, 124, 255],
      },
      {
        "x": 108,
        "y": 52,
        "rgba": [45, 0, 209, 255],
      },
      {
        "x": 104,
        "y": 75,
        "rgba": [0, 46, 210, 255],
      },
      {
        "x": 91,
        "y": 96,
        "rgba": [0, 149, 106, 255],
      },
      {
        "x": 70,
        "y": 107,
        "rgba": [0, 247, 9, 255],
      },
      {
        "x": 67,
        "y": 108,
        "rgba": [251, 0, 4, 255],
      },
      {
        "x": 47,
        "y": 103,
        "rgba": [176, 0, 80, 255],
      },
      {
        "x": 25,
        "y": 89,
        "rgba": [73, 0, 183, 255],
      },
      {
        "x": 12,
        "y": 65,
        "rgba": [0, 36, 219, 255],
      },
      {
        "x": 17,
        "y": 41,
        "rgba": [0, 140, 116, 255],
      },
      {
        "x": 32,
        "y": 21,
        "rgba": [0, 246, 9, 255],
      },
      {
        "x": 35,
        "y": 21,
        "rgba": [254, 0, 2, 255],
      },
      {
        "x": 60,
        "y": 42,
        "rgba": [148, 0, 106, 255],
      },
      {
        "x": 80,
        "y": 69,
        "rgba": [0, 65, 190, 255],
      },
      {
        "x": 42,
        "y": 83,
        "rgba": [112, 0, 144, 255],
      },
    ],
  },
  {
    "id": "repeating-conic-positive-start-period-over-one-turn",
    "css": "repeating-conic-gradient(red .4turn, blue 1.9turn)",
    "width": 120,
    "height": 120,
    "samples": [
      {
        "x": 60,
        "y": 10,
        "rgba": [67, 0, 187, 255],
      },
      {
        "x": 78,
        "y": 13,
        "rgba": [58, 0, 197, 255],
      },
      {
        "x": 95,
        "y": 25,
        "rgba": [47, 0, 209, 255],
      },
      {
        "x": 107,
        "y": 42,
        "rgba": [35, 0, 220, 255],
      },
      {
        "x": 110,
        "y": 60,
        "rgba": [25, 0, 229, 255],
      },
      {
        "x": 103,
        "y": 83,
        "rgba": [13, 0, 243, 255],
      },
      {
        "x": 86,
        "y": 101,
        "rgba": [253, 0, 2, 255],
      },
      {
        "x": 60,
        "y": 110,
        "rgba": [238, 0, 16, 255],
      },
      {
        "x": 36,
        "y": 103,
        "rgba": [225, 0, 31, 255],
      },
      {
        "x": 17,
        "y": 83,
        "rgba": [210, 0, 46, 255],
      },
      {
        "x": 10,
        "y": 60,
        "rgba": [195, 0, 59, 255],
      },
      {
        "x": 15,
        "y": 37,
        "rgba": [183, 0, 73, 255],
      },
      {
        "x": 31,
        "y": 19,
        "rgba": [170, 0, 86, 255],
      },
      {
        "x": 47,
        "y": 12,
        "rgba": [160, 0, 95, 255],
      },
      {
        "x": 60,
        "y": 60,
        "rgba": [4, 0, 250, 255],
      },
    ],
  },
  {
    "id": "semi-transparent-conic-over-repeating-linear",
    "css":
        "conic-gradient(from 31deg at 38% 54% in srgb, rgba(255, 0, 0, 0.05) 0deg, rgba(255, 0, 0, .65) 135deg, rgba(0, 80, 255, .3) 1turn), repeating-linear-gradient(45deg in srgb, rgba(0, 180, 90, .7) 0px 12px, rgba(0, 0, 0, .25) 12px 29px)",
    "width": 120,
    "height": 100,
    "samples": [
      {
        "x": 10,
        "y": 10,
        "rgba": [92, 29, 95, 142],
      },
      {
        "x": 25,
        "y": 10,
        "rgba": [76, 33, 107, 138],
      },
      {
        "x": 40,
        "y": 10,
        "rgba": [33, 124, 129, 206],
      },
      {
        "x": 55,
        "y": 10,
        "rgba": [26, 44, 143, 127],
      },
      {
        "x": 70,
        "y": 10,
        "rgba": [2, 50, 159, 122],
      },
      {
        "x": 85,
        "y": 10,
        "rgba": [35, 154, 78, 187],
      },
      {
        "x": 100,
        "y": 10,
        "rgba": [101, 0, 0, 91],
      },
      {
        "x": 115,
        "y": 10,
        "rgba": [116, 0, 0, 97],
      },
      {
        "x": 10,
        "y": 35,
        "rgba": [118, 24, 77, 149],
      },
      {
        "x": 35,
        "y": 35,
        "rgba": [81, 33, 105, 139],
      },
      {
        "x": 60,
        "y": 35,
        "rgba": [30, 159, 80, 186],
      },
      {
        "x": 85,
        "y": 35,
        "rgba": [129, 0, 0, 103],
      },
      {
        "x": 110,
        "y": 35,
        "rgba": [80, 124, 62, 197],
      },
      {
        "x": 10,
        "y": 75,
        "rgba": [173, 12, 38, 167],
      },
      {
        "x": 60,
        "y": 75,
        "rgba": [165, 65, 32, 221],
      },
      {
        "x": 110,
        "y": 75,
        "rgba": [123, 94, 46, 209],
      },
    ],
  },
  {
    "id": "repeating-radial-over-conic",
    "css":
        "repeating-radial-gradient(ellipse 42px 25px at 32% 56% in srgb, rgba(255, 170, 0, .45) 0px, rgba(0, 110, 255, .35) 17px, rgba(0, 110, 255, .2) 43px), conic-gradient(from 27deg at 70% 40% in srgb, rgba(180, 0, 255, .4) 0deg, rgba(0, 255, 100, .55) 150deg, rgba(255, 40, 60, .25) 1turn)",
    "width": 150,
    "height": 120,
    "samples": [
      {
        "x": 10,
        "y": 10,
        "rgba": [45, 139, 177, 154],
      },
      {
        "x": 35,
        "y": 10,
        "rgba": [111, 152, 116, 158],
      },
      {
        "x": 60,
        "y": 10,
        "rgba": [116, 144, 114, 156],
      },
      {
        "x": 85,
        "y": 10,
        "rgba": [62, 120, 181, 144],
      },
      {
        "x": 110,
        "y": 10,
        "rgba": [84, 95, 177, 124],
      },
      {
        "x": 140,
        "y": 10,
        "rgba": [189, 114, 111, 170],
      },
      {
        "x": 10,
        "y": 40,
        "rgba": [47, 148, 167, 159],
      },
      {
        "x": 35,
        "y": 40,
        "rgba": [163, 171, 59, 169],
      },
      {
        "x": 60,
        "y": 40,
        "rgba": [164, 170, 58, 168],
      },
      {
        "x": 85,
        "y": 40,
        "rgba": [54, 141, 168, 155],
      },
      {
        "x": 110,
        "y": 40,
        "rgba": [90, 59, 248, 142],
      },
      {
        "x": 140,
        "y": 40,
        "rgba": [48, 107, 222, 164],
      },
      {
        "x": 10,
        "y": 75,
        "rgba": [34, 173, 155, 143],
      },
      {
        "x": 35,
        "y": 75,
        "rgba": [24, 159, 179, 162],
      },
      {
        "x": 60,
        "y": 75,
        "rgba": [20, 163, 179, 164],
      },
      {
        "x": 85,
        "y": 75,
        "rgba": [17, 192, 154, 154],
      },
      {
        "x": 110,
        "y": 75,
        "rgba": [4, 181, 177, 176],
      },
      {
        "x": 140,
        "y": 75,
        "rgba": [110, 164, 116, 180],
      },
      {
        "x": 10,
        "y": 110,
        "rgba": [24, 178, 154, 149],
      },
      {
        "x": 60,
        "y": 110,
        "rgba": [13, 181, 163, 161],
      },
      {
        "x": 110,
        "y": 110,
        "rgba": [67, 191, 118, 184],
      },
      {
        "x": 140,
        "y": 110,
        "rgba": [14, 175, 176, 165],
      },
    ],
  },
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // These suites exercise the image/media loaders themselves, not the hold-back.
  setUpAll(() => NativeRemoteContentPolicy.debugOpenForTests = true);
  tearDownAll(() => NativeRemoteContentPolicy.debugOpenForTests = false);
  testWidgets('Android normal HTML conic and repeating gradients match Chrome', (
    t,
  ) async {
    final theme = await PircTheme.load();
    for (final input in cases) {
      for (final normalized in [false, true]) {
        for (final brightness in Brightness.values) {
          {
            final width = (input['width'] as num).toDouble(),
                height = (input['height'] as num).toDouble();
            final g = Gateway();
            final materialTheme = theme.build(brightness);
            final background = materialTheme.scaffoldBackgroundColor.toARGB32();
            var source =
                '<div id="gradient" style="width:${width}px;height:${height}px;background-image:${input['css']}"></div>';
            if (normalized) {
              final document = html.parse(source);
              final result = NativeDocumentStyleEngine(
                stylesheets: [],
                viewportWidth: 390,
                dark: brightness == Brightness.dark,
              ).apply(document);
              expect(result.diagnostics, isEmpty);
              source = document.querySelector('#gradient')!.outerHtml;
            }
            await t.pumpWidget(
              MaterialApp(
                theme: materialTheme,
                home: Scaffold(
                  body: RepaintBoundary(
                    key: const ValueKey('gradient-capture'),
                    child: SizedBox(
                      width: width,
                      height: height,
                      child: ColoredBox(
                        color: materialTheme.scaffoldBackgroundColor,
                        child: RichTextBody(source, gateway: g),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await t.pumpAndSettle();
            final pixels = await t.runAsync(() async {
              final image = await t
                  .renderObject<RenderRepaintBoundary>(
                    find.byKey(const ValueKey('gradient-capture')),
                  )
                  .toImage(pixelRatio: 1);
              try {
                final bytes = (await image.toByteData(
                  format: ui.ImageByteFormat.rawRgba,
                ))!.buffer.asUint8List();
                return [
                  for (final p in input['samples'] as List)
                    _rgba(
                      bytes,
                      ((p['y'] as int) * image.width + (p['x'] as int)) * 4,
                    ),
                ];
              } finally {
                image.dispose();
              }
            });
            final samples = input['samples'] as List;
            for (var i = 0; i < samples.length; i++) {
              final rgba = samples[i]['rgba'] as List;
              // Compare what the user sees over the actual App background.
              // Low-alpha unpremultiplication amplifies a one-byte GPU rounding
              // difference; opaque/composited channels retain the same 4-level gate.
              final alpha = (rgba[3] as int) / 255;
              final expected = [
                for (var channel = 0; channel < 3; channel++)
                  ((rgba[channel] as int) * alpha +
                          ((background >> (16 - channel * 8)) & 255) *
                              (1 - alpha))
                      .round(),
                255,
              ];
              for (var channel = 0; channel < 4; channel++) {
                expect(
                  (pixels![i][channel] - expected[channel]).abs(),
                  lessThanOrEqualTo(4),
                  reason:
                      '${input['id']} point $i channel $channel: ${pixels[i]} vs $expected',
                );
              }
            }
            expect(t.takeException(), isNull);
            await t.pumpWidget(const SizedBox());
          }
        }
      }
    }
  });
}

List<int> _rgba(List<int> bytes, int offset) {
  final alpha = bytes[offset + 3];
  if (alpha == 0) return [0, 0, 0, 0];
  return [
    for (var i = 0; i < 3; i++)
      ((bytes[offset + i] * 255 + alpha / 2) / alpha).round().clamp(0, 255),
    alpha,
  ];
}
