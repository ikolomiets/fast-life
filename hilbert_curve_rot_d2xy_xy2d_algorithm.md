## Overview

The **classic `rot + d2xy / xy2d` algorithm** generates or indexes points on a 2-dimensional **Hilbert space-filling curve** of order `k`.
The curve traverses every cell of a `2^k × 2^k` grid exactly once while maintaining strong spatial locality.

Two transformations are defined:

1. **`d2xy`** — converts a **Hilbert index** `d` into coordinates `(x, y)`.
2. **`xy2d`** — converts coordinates `(x, y)` back into the Hilbert index `d`.

Both operations run in **O(k)** time where `k` is the order of the curve.

---

# 1. Geometry of a Hilbert Curve

For a curve of order `k`:

```
grid_size n = 2^k
points     = n² = 4^k
```

Example orders:

| Order | Grid size | Points    |
| ----- | --------- | --------- |
| 1     | 2×2       | 4         |
| 2     | 4×4       | 16        |
| 3     | 8×8       | 64        |
| 10    | 1024×1024 | 1,048,576 |

Each step of the curve moves to a **neighboring cell**.

The Hilbert curve is built recursively:

```
Level k
 ├─ quadrant 0
 ├─ quadrant 1
 ├─ quadrant 2
 └─ quadrant 3
```

Each quadrant contains a **smaller Hilbert curve of order `k-1`**, but its **orientation depends on the quadrant**.

Handling these rotations/reflections is the core purpose of the `rot` function.

---

# 2. Bit Interpretation of the Hilbert Index

A Hilbert index `d` contains **two bits per recursion level**:

```
d = b_(2k-1) b_(2k-2) ... b1 b0
```

Each pair of bits selects one of four quadrants:

```
00 → quadrant 0
01 → quadrant 1
10 → quadrant 2
11 → quadrant 3
```

During traversal the algorithm processes the index **from least significant bits upward**.

At level `i` (square size `2^i`) the algorithm extracts:

```
rx = bit controlling x quadrant
ry = bit controlling y quadrant
```

These determine where the next sub-square lies.

---

# 3. Role of the `rot` Transformation

The Hilbert curve requires specific **rotations and reflections** so that the curve remains continuous between quadrants.

The transformation depends on `(rx, ry)`.

### Cases

| rx | ry | action           |
| -- | -- | ---------------- |
| 0  | 0  | rotate 90°       |
| 0  | 1  | no rotation      |
| 1  | 0  | rotate + reflect |
| 1  | 1  | no rotation      |

In practice the algorithm simplifies this to:

```
if ry == 0
    if rx == 1
        reflect
    swap x and y
```

This operation maintains the correct Hilbert orientation.

---

# 4. Pseudocode: Rotation Function

```
procedure ROT(size, x, y, rx, ry)

    if ry == 0 then
        if rx == 1 then
            x ← size - 1 - x
            y ← size - 1 - y
        end if

        swap(x, y)
    end if

    return (x, y)

end procedure
```

### Meaning of parameters

```
size = current quadrant size
x,y  = coordinates within current square
rx   = x-direction quadrant bit
ry   = y-direction quadrant bit
```

---

# 5. Hilbert Index → Coordinates (`d2xy`)

This algorithm walks through the Hilbert index **level by level**, expanding coordinates from small squares to larger squares.

### Pseudocode

```
procedure D2XY(n, d)

    x ← 0
    y ← 0

    t ← d
    size ← 1

    while size < n do

        rx ← (t div 2) AND 1
        ry ← (t XOR rx) AND 1

        (x, y) ← ROT(size, x, y, rx, ry)

        x ← x + size * rx
        y ← y + size * ry

        t ← t div 4
        size ← size * 2

    end while

    return (x, y)

end procedure
```

---

## Step-by-step intuition

At each level:

1. **Extract quadrant bits**

```
rx = (t // 2) & 1
ry = (t ^ rx) & 1
```

These represent which of the four sub-squares the curve enters.

2. **Rotate current coordinate system**

```
(x, y) = ROT(...)
```

Ensures continuity of the curve orientation.

3. **Move into the chosen quadrant**

```
x += size * rx
y += size * ry
```

4. **Advance to next level**

```
t = t // 4
size *= 2
```

---

# 6. Coordinates → Hilbert Index (`xy2d`)

The inverse transformation determines **which quadrant the coordinate lies in at each scale**.

### Pseudocode

```
procedure XY2D(n, x, y)

    d ← 0
    size ← n / 2

    while size > 0 do

        if (x AND size) > 0
            rx ← 1
        else
            rx ← 0
        end if

        if (y AND size) > 0
            ry ← 1
        else
            ry ← 0
        end if

        d ← d + size * size * ((3 * rx) XOR ry)

        (x, y) ← ROT(size, x, y, rx, ry)

        size ← size / 2

    end while

    return d

end procedure
```

---

# 7. Why the Formula `(3*rx) XOR ry` Works

This expression converts quadrant bits into the Hilbert index order.

Mapping:

| rx | ry | index |
| -- | -- | ----- |
| 0  | 0  | 0     |
| 0  | 1  | 1     |
| 1  | 1  | 2     |
| 1  | 0  | 3     |

Which corresponds to the Hilbert traversal ordering.

---

# 8. Example (Order 2)

Grid:

```
4 × 4
```

Hilbert traversal order:

```
 0  1 14 15
 3  2 13 12
 4  7  8 11
 5  6  9 10
```

Example:

```
d = 5
```

Algorithm steps:

```
level 0:
rx = 0
ry = 1
→ position inside first quadrant

level 1:
rx = 1
ry = 0
→ move to next quadrant with rotation
```

Final coordinate:

```
(x, y) = (0,3)
```

---

# 9. Generating the Entire Hilbert Curve

To produce the curve sequence:

```
procedure GENERATE_HILBERT(order)

    n ← 2^order
    total ← n * n

    for d from 0 to total-1 do
        (x,y) ← D2XY(n, d)
        output (x,y)
    end for

end procedure
```

For order 10:

```
n = 1024
points = 1,048,576
```

This loop generates the entire curve.

---

# 10. Performance Characteristics

| Property        | Value                  |
| --------------- | ---------------------- |
| Time complexity | `O(order)` per point   |
| Memory          | `O(1)`                 |
| Arithmetic      | integer bit operations |
| Branching       | minimal                |

For order 10:

```
10 iterations per point
≈ 10 million operations total
```

This is extremely fast even in interpreted languages.

---

# 11. Advantages of the `rot + d2xy` Method

1. **No recursion**
2. **Constant memory**
3. **Works for arbitrary orders**
4. **Direct random access**
5. **Easy inverse transform**

Because of these properties it is commonly used in:

* spatial databases
* image processing
* GPU tiling
* cache-efficient indexing
* geospatial indexing
* multidimensional data structures

---

# 12. Conceptual Summary

The algorithm constructs the Hilbert curve by repeatedly:

1. Decoding **two index bits** → selecting a quadrant.
2. **Rotating/reflection** of the coordinate system.
3. **Adding offsets** to place the point within the expanding square.

This iterative expansion from small squares to larger squares recreates the recursive structure of the Hilbert curve without recursion.

---

If you'd like, I can also show:

* a **bit-level derivation** of why `ry = (t XOR rx) & 1`
* a **visual explanation of quadrant rotations**
* or the **Skilling Hilbert transform**, which computes the same mapping using a different bit-manipulation strategy.

