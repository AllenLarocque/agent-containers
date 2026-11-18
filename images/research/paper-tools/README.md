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
- Memory: one paper measured ~3.8 GB peak. Worst case is roughly 8 GB with two big papers in
  flight (the JVM plus up to two pdfalto processes at <=2 GB each). Run `grobid stop` after a batch.
- Offline: consolidation is always off. Env: `GROBID_JAVA_OPTS` (default `-Xmx4g`),
  `GROBID_START_TIMEOUT` (seconds, default 180).
- Log and pidfile: `${XDG_STATE_HOME:-$HOME/.local/state}/grobid`.

## Tables
No tables tool yet (Docling arrives in stage 2b). Use the built-in PDF reader for tables.

## Finding papers: the `paper-search` MCP server (Claude Code only)
- What it is for: searching many legal sources at once (`search_papers`, or one source such as
  `search_arxiv`, `search_openalex`, `search_crossref`, `search_core`, `search_europepmc`), citation
  links (`get_citing_papers`, `get_referenced_papers`), and open-access PDFs (`download_<source>`).
- Sci-Hub is off: its tools (`download_scihub`, and `download_with_fallback`, which can fall back to
  Sci-Hub) are denied. Do not try to reach Sci-Hub or any other shadow library another way.
- Downloads: always pass `save_path` as the paper's own folder,
  `/research/<project>/downloads/papers/<one folder per paper>/` (or `/research/_general/papers/...`),
  then write its `metadata.md` there as for any other paper. Without `save_path` the file lands in a
  scratch folder, not in the papers store.
- Unpaywall and OpenAlex get `$RESEARCH_CONTACT_EMAIL` when it is set; unset, Unpaywall is skipped.
- Google Scholar often refuses automated queries; move on to the other sources when it does.
- If no `paper-search` tools are listed, the server did not start: search the services by hand and say so.
