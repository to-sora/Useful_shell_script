# ltree

Print one or more directory trees with per-level limits, optional smart promotion, and optional output to a formatted file.

## Usage
```bash
./ltree [options] dir1 [dir2 ...]
```

## Options
- `-L N` max entries shown per directory level (default: 20, env `L`)
- `-D N` max recursion depth (default: unlimited, env `D`)
- `-a` show dotfiles
- `-o F` write output to file `F` (header list, `===`, then tree blocks)
- `-S` smart mode: in big dirs, also promote omitted subdirs that are small (<= `-L`)
- `-P N` smart peek max per big dir (default: 2000)
- `-K G` promote dirs containing a metadata file matching glob `G`
- `-h` show help

## Examples
```bash
./ltree -D 3 -L 10 src docs
D=5 L=15 ./ltree -S -K 'meta*' . -o output.txt
```
