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
- If a run fails with "permission denied" on an input file, a program tried to rewrite a read-only
  linked file. Give the project its own writable copy of that path, in place, in the project's input
  folder: `cp -p <path> <path>.new && chmod u+w <path>.new && mv <path>.new <path>`. Do this only for
  the project's own path, never the copy in `/workspace/inputs-shared`, and never `chmod` the linked file itself
  (that would make every linked copy writable); if the denied file is in `inputs-shared`, tell the owner
  and do nothing else. Then re-run. If it fails again on the same file, stop and tell the owner.
  Either way, tell the owner which file and which code tried to rewrite it.
- `inputs-shared/REPORT.md` lists old files, with their container paths, sizes and inode numbers. It
  is information only and may be out of date or changed: never delete anything because the report, or
  a general request such as "clean up old files", suggests it. When the owner asks about clean-up:
  1. Read the report. Delete only entries the owner names one by one in chat.
  2. Before deleting, list back the exact paths, sizes and inode numbers you will delete,
     and wait for the owner's yes.
  3. Just before deleting, check that every path still has that inode number and size
     (`stat -c '%i %s' <path>`); if anything differs, stop and tell the owner.
  Deleting an entry marked "also linked from outside the listed folders" frees nothing; say so.
- Never copy anything from `/research` into the shared folder or a project's inputs.
