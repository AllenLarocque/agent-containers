## Shared inputs

This container has one shared download folder, switched on by the owner. These rules apply to it.

- `/workspace/inputs-shared` holds one copy of every downloaded input for all projects in this
  container. The container points `reproducible` at it: `reproducible.inputPaths` and
  `reproducible.tempPath` are set for you, unless a script has already set them.
- Leave `inputPath` and the `reproducible` shared-folder and temp-path options at their defaults in
  `global.R`. Setting them brings back duplicate copies. A project that sets the option itself keeps
  its own folder; do not change that without asking the owner.
- Files get there only through `reproducible` and module code that uses the shared-folder option (some
  modules deliberately keep one copy of a large computed table there), never by hand.
  Never edit, overwrite, rename or delete anything in it on your own; the clean-up the owner names in chat (below) is the one exception.
  Also never open a file there for in-place update. If a file looks wrong, tell the owner.
- Files in project input folders may be hard links shared with other projects (the weekly job makes
  them, and makes them read-only). Never edit an input file in place; write a new file instead.
  If a run fails with "permission denied" on an input file, delete that path (the one in the project's own input folder, never the copy in `/workspace/inputs-shared`;
  if the denied file is in `inputs-shared`, tell the owner instead of deleting it) and re-run (the file is
  rebuilt or downloaded as a new file), and tell the owner which file and which code tried to rewrite
  it.
  Never make such a file writable again.
- `inputs-shared/REPORT.md` lists old files, with their container paths. When the owner asks about
  clean-up, read it. Delete only what the owner names in chat, and
  delete every path the report lists for that file.
- Never copy anything from `/research` into the shared folder or a project's inputs.
