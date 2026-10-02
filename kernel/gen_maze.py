#!/usr/bin/env python3
"""Generate a small maze map + agent file for the low-level search kernel.

Output formats are the "my benchmark" formats that Instance.cpp already reads:
  map : first line "rows,cols", then one line per row ('@' wall, '.' free)
  scen: first line K, then K lines "start_row,start_col,goal_row,goal_col,"

Maze layout mimics MovingAI maze-N-N-W: an n x n grid of cells, corridors W wide,
walls 1 thick. Total side = n*(W+1)+1. `--loops` removes extra walls so the maze is
not a tree (agents can route around each other, like the real maps).
"""
import argparse
import random


def build_maze(n, width, loops, rng):
    side = n * (width + 1) + 1
    grid = [["@"] * side for _ in range(side)]

    def origin(ci, cj):
        return 1 + ci * (width + 1), 1 + cj * (width + 1)

    def carve_cell(ci, cj):
        r0, c0 = origin(ci, cj)
        for r in range(r0, r0 + width):
            for c in range(c0, c0 + width):
                grid[r][c] = "."

    def carve_wall(ci, cj, di, dj):
        # open the wall between cell (ci,cj) and its neighbour (ci+di,cj+dj)
        r0, c0 = origin(ci, cj)
        if di == 1:
            for c in range(c0, c0 + width):
                grid[r0 + width][c] = "."
        elif di == -1:
            for c in range(c0, c0 + width):
                grid[r0 - 1][c] = "."
        elif dj == 1:
            for r in range(r0, r0 + width):
                grid[r][c0 + width] = "."
        else:
            for r in range(r0, r0 + width):
                grid[r][c0 - 1] = "."

    for ci in range(n):
        for cj in range(n):
            carve_cell(ci, cj)
    # cells start fully carved but isolated by walls only if width walls are kept;
    # carve_cell fills only the cell interior, walls between cells remain '@'.

    visited = [[False] * n for _ in range(n)]
    stack = [(0, 0)]
    visited[0][0] = True
    dirs = [(1, 0), (-1, 0), (0, 1), (0, -1)]
    while stack:
        ci, cj = stack[-1]
        nbrs = [(ci + di, cj + dj, di, dj) for di, dj in dirs
                if 0 <= ci + di < n and 0 <= cj + dj < n and not visited[ci + di][cj + dj]]
        if not nbrs:
            stack.pop()
            continue
        ni, nj, di, dj = rng.choice(nbrs)
        carve_wall(ci, cj, di, dj)
        visited[ni][nj] = True
        stack.append((ni, nj))

    # extra openings -> loops
    all_walls = [(ci, cj, di, dj) for ci in range(n) for cj in range(n)
                 for di, dj in ((1, 0), (0, 1)) if ci + di < n and cj + dj < n]
    rng.shuffle(all_walls)
    for ci, cj, di, dj in all_walls[: int(loops * len(all_walls))]:
        carve_wall(ci, cj, di, dj)
    return grid


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cells", type=int, default=10, help="maze is cells x cells")
    ap.add_argument("--width", type=int, default=2, help="corridor width")
    ap.add_argument("--loops", type=float, default=0.1, help="fraction of extra walls removed")
    ap.add_argument("--agents", type=int, default=50)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out", default="kernel_maze", help="writes <out>.map and <out>.scen")
    a = ap.parse_args()

    rng = random.Random(a.seed)
    grid = build_maze(a.cells, a.width, a.loops, rng)
    side = len(grid)
    free = [(r, c) for r in range(side) for c in range(side) if grid[r][c] == "."]
    if a.agents > len(free):
        raise SystemExit("more agents than free cells")
    starts = rng.sample(free, a.agents)
    goals = rng.sample(free, a.agents)  # unique goals: SpaceTimeAStar asserts on shared goals

    with open(a.out + ".map", "w") as f:
        f.write("%d,%d\n" % (side, side))
        for row in grid:
            f.write("".join(row) + "\n")
    with open(a.out + ".scen", "w") as f:
        f.write("%d\n" % a.agents)
        for (sr, sc), (gr, gc) in zip(starts, goals):
            f.write("%d,%d,%d,%d,\n" % (sr, sc, gr, gc))
    print("wrote %s.map (%dx%d, %d free cells) and %s.scen (%d agents)"
          % (a.out, side, side, len(free), a.out, a.agents))


if __name__ == "__main__":
    main()
