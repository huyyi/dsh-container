# Agent B — warehouse WH-SH-03 localization planner

You own the private warehouse map and radar inventory below. Accept only requests for WH-SH-03.
The incoming document is supplied by headquarters; preserve all text except the bodies of
“房间布局” and “传感器调节”. Return the ENTIRE completed Markdown as a text Artifact, without
an enclosing code fence. Do not return only a path or summary. Do not delegate back to A.

Use the supplied last-known location only to prioritize search. Its age means it is not a current
position or a bounded reachable region. Plan multiple scan rounds if useful. Hardware actuation
is outside this demo. No actual radar observations are available.

## Coordinates and sensor model

The matrix is 16 columns by 12 rows, each cell is 1 m square. Origin (0,0) is the outer southwest
corner; +X east, +Y north. Matrix rows run north to south: matrix[row][col] has center
(col + 0.5, 12 - row - 0.5). # is an opaque wall/rack cell, . is a walkable cell.
Outer # cells represent perimeter walls; interior # cells are racks. Sensors are mounted on the
inner perimeter faces: x=1 or 15, y=1 or 11. They are not additional matrix cells.

Heading 0° is east, 90° north, 180° west, 270° south; increasing angles rotate counterclockwise.
fov is the FULL fixed sector opening, not the heading or half-angle. range is in meters.
rotation is a continuous mechanical interval in degrees (negative angles are valid).
All six sensors are available. Each can supply range and bearing of a detected target in this
demo's assumed device model; no measurements, accuracy bounds or identity classifier are supplied.
Geometric overlap identifies candidate jointly observable cells, not a robot detection. Real
localization also requires synchronized observations, calibrated transforms, uncertainty handling
and target association; radar alone cannot be assumed to distinguish AMR-017 from another object.

The checker treats walls and racks as fully opaque, including rays tangent to a rack corner.
It models cell centers in 2D, without penetration, multipath, elevation or detection probability.
Different rounds do not count as simultaneous dual coverage.

## Planning and validation

Create a plan JSON in your session workspace:
```json
{"warehouseId":"WH-SH-03","rounds":[{"name":"priority","headings":{"W1":0,"W2":0,"E1":180,"E2":180,"S1":90,"N1":270}}]}
```
This illustrates the schema, not a verified optimal plan. Every round must specify all six IDs.
Run (using the event's actual coordinates and radius):
```sh
python3 /demo/check_geometry.py --agents /home/dsh/AGENTS.md --plan plan.json --target 8.5 5.5 --radius 3 > geometry.json
```
Read the output and improve your headings/rounds if necessary. The checker rejects illegal
orientations; zero/partial coverage is reported, not falsely treated as success. Each round's
rotation is relative to the previous round (first round starts from the deployment headings).
Use the output's actual counts, dual-coverage pairs and blind cells in the document.
Include the complete plan JSON and concise check results inside the sensor-adjustment chapter,
so headquarters receives an inspectable plan. Explain uncovered priority cells and subsequent
search/manual inspection; do not claim full coverage if the checker does not establish it.

Fill the room chapter with the matrix, legend, coordinates and installation table. Fill the
adjustment chapter with priorities, round-by-round motions, overlaps, blind areas, check command
and results, and the requirements for using future real observations.

## Private deployment data

The following fenced JSON is the single source of truth read by the geometry checker.
Only B receives this file; disclose the layout in the returned document as requested.

```warehouse-json
{
  "warehouseId": "WH-SH-03",
  "cellSizeMeters": 1,
  "matrix": [
    "################",
    "#..............#",
    "#..............#",
    "#...##....##...#",
    "#...##....##...#",
    "#...##....##...#",
    "#...##....##...#",
    "#...##....##...#",
    "#...##....##...#",
    "#..............#",
    "#..............#",
    "################"
  ],
  "sensors": [
    {
      "id": "W1",
      "position": [
        1,
        3
      ],
      "heading": 0,
      "fov": 30,
      "range": 18,
      "rotation": [
        -80,
        80
      ],
      "available": true
    },
    {
      "id": "W2",
      "position": [
        1,
        9
      ],
      "heading": 0,
      "fov": 60,
      "range": 18,
      "rotation": [
        -80,
        80
      ],
      "available": true
    },
    {
      "id": "E1",
      "position": [
        15,
        3
      ],
      "heading": 180,
      "fov": 45,
      "range": 18,
      "rotation": [
        100,
        260
      ],
      "available": true
    },
    {
      "id": "E2",
      "position": [
        15,
        9
      ],
      "heading": 180,
      "fov": 90,
      "range": 18,
      "rotation": [
        100,
        260
      ],
      "available": true
    },
    {
      "id": "S1",
      "position": [
        8,
        1
      ],
      "heading": 90,
      "fov": 60,
      "range": 15,
      "rotation": [
        10,
        170
      ],
      "available": true
    },
    {
      "id": "N1",
      "position": [
        8,
        11
      ],
      "heading": 270,
      "fov": 90,
      "range": 15,
      "rotation": [
        190,
        350
      ],
      "available": true
    }
  ]
}
```
