# PDF tools in this image

Installed versions are listed in `/opt/paper-tools/MANIFEST`. Do not install anything yourself.

## Which tool for what
- `pdfinfo f.pdf`: page count, metadata, encryption.
- `pdftotext -layout f.pdf f.txt`: text, keeping the column layout.
- `pdfimages -list f.pdf`: list embedded images (figures, scans).
- `qpdf`: repair or decrypt (`qpdf --decrypt in.pdf out.pdf`; `qpdf --check f.pdf`).
- `ocrmypdf --output-type pdf --sidecar f.txt in.pdf ocr.pdf`: OCR for scans (uses `tesseract`, English). Never use `pdfa`.
- `grobid fulltext in.pdf out.xml`: sections and references as TEI XML.
  `grobid header in.pdf out.xml`: title, authors and abstract only.
  `grobid start | stop | status`: the service (127.0.0.1:8070, two requests at a time).

## Order for one paper
1. `pdftotext -layout`. If the text is empty or garbled, there is no text layer.
2. No text layer: `ocrmypdf`, then use `ocr.pdf` below.
3. `grobid fulltext` for sections and references.

## GROBID details
- Exit codes: 0 ok, 1 error, 2 no text layer (run `ocrmypdf` first).
- Memory: it holds about 4 GB while running (the JVM is capped by `-Xmx4g`).
  Run `grobid stop` after a batch.
- Offline: consolidation is always off. Env: `GROBID_JAVA_OPTS` (default `-Xmx4g`),
  `GROBID_START_TIMEOUT` (seconds, default 180).
- Log and pidfile: `${XDG_STATE_HOME:-$HOME/.local/state}/grobid`.

## Tables
No tables tool yet (Docling arrives in stage 2b). Use the built-in PDF reader for tables.
