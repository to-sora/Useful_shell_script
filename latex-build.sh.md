# latex-build.sh

Compile LaTeX files with `pdflatex`. With no arguments, the script finds the newest `.tex` file that needs rebuilding from configured search directories; with arguments, it compiles the files you specify.

## Requirements
- Bash
- `pdflatex`
- `find`, `realpath`, `stat`, and standard core utilities
- Optional on WSL: `wslpath` and `explorer.exe` to open generated PDFs automatically

## Usage
```bash
# Compile the newest outdated .tex file from configured directories
./latex-build.sh

# Compile one or more explicit files
./latex-build.sh file1.tex [file2.tex ...]

# Show help
./latex-build.sh --help
```

## Notes
- Edit `RECURSIVE_DIRS` and `FLAT_DIRS` near the top of the script to control automatic discovery.
- A file is considered outdated when its PDF does not exist or the `.tex` file is newer than the PDF.
- Automatic mode compiles only the newest outdated `.tex` file it finds.
- Explicit-file mode attempts every supplied file and returns a failure status if any compilation fails.
- `pdflatex` runs with `-interaction=nonstopmode`, `-halt-on-error`, and `-file-line-error`.
- In WSL, a successful build is opened with Windows Explorer when `explorer.exe` is available; otherwise the PDF path is printed.
