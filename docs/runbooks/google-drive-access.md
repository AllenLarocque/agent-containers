# Runbook: read-only Google Drive access for the agent (service account)

**Human procedure.** You do the Google Cloud steps and handle the key. The agent must never do them.

## What this gives you

- The agent can **read** files and folders that you share with one robot account (a "service account").
- It sees **only what you share with that account**. It cannot see your own Drive.
- You can take it away at any time (see "Rotate or revoke").
- A plain personal Gmail account is enough. You do not need Google Workspace.

It works through the R package `reproducible`. You need the development version (3.2.1.9085 or newer)
from <https://predictiveecology.r-universe.dev>. `setupProject()` installs it from there. The CRAN
version 3.2.1 does not have this.

When you call `prepInputs(url = "<a Drive link>")`, `reproducible` tries these in order. It never
asks you to log in.

1. A Google login already loaded in the R session.
2. The option `gargle_oauth_email`.
3. The service-account key in `GOOGLEDRIVE_AUTH` (this runbook). It prints
   `Google Drive: trying option service-account JSON from $GOOGLEDRIVE_AUTH`.
4. No login at all, for files shared with "anyone with the link". It prints
   `Public Google Drive file; downloading without authentication`.

The Drive hosts are already in the base allowlist. You do not need to add any.

## One-time setup in Google Cloud

Google changes its menus now and then. The names below may differ slightly.

1. Open <https://console.cloud.google.com/> and sign in with your Gmail account.
2. Create a project. Use the project picker at the top, then **New project**. Any name will do,
   for example `agent-drive-read`.
3. Turn on the Drive API. Go to **APIs & Services → Library**, search for **Google Drive API**,
   and click **Enable**.
4. Create the service account. Go to **IAM & Admin → Service accounts → Create service account**.
   Give it a name. **Skip the optional "grant access" steps: give it no roles.** Click **Done**.
5. Open the new account, go to the **Keys** tab, then **Add key → Create new key → JSON**.
   Your browser downloads a `.json` file. This file is the secret.
6. Note the address in the file, or on the account page. It looks like
   `name@project-id.iam.gserviceaccount.com`. It is the `client_email` in the key.

## Put the key in place

On your host (not in the container). Replace `~/Downloads/key.json` with the real path of the file:

```bash
mkdir -p ~/.config/agent-containers/.shared
mv ~/Downloads/key.json ~/.config/agent-containers/.shared/google-drive-sa.json
chmod 600 ~/.config/agent-containers/.shared/google-drive-sa.json
```

- Why: the launcher reads the key from this path. The `chmod 600` is required: `agent-up`
  refuses a key that group or other users can read, and prints the `chmod` command to run.
- The file must be a **service-account key** (it has `"type": "service_account"` and a
  `client_email`). An OAuth client JSON will not do; `agent-up` refuses it.
- Key locations, in order:
  1. `~/.config/agent-containers/<project>/google-drive-sa.json` (this project only; wins), else
  2. `~/.config/agent-containers/.shared/google-drive-sa.json` (every builder project).
- The key is never put in a repo. Do not commit it, paste it in chat, or put it in `project.env`.

## Share data with it

For each Drive file or folder the agent should read:

1. In Google Drive, right-click it and choose **Share**.
2. Paste the service account's address (the `client_email`).
3. Set the role to **Viewer**. Never **Editor**.
4. Untick "Notify people" if you see it, and click **Share**.

Sharing a folder shares what is inside it.

Viewer is enough to read. A service account probably cannot upload anyway, because Google gives it
no Drive storage of its own (not verified). Use Viewer either way, so that a mistake cannot change
your data.

## Apply

Per project:

```bash
agent-up up <project>
```

Or for all projects:

```bash
agent-up update --all
```

`up` prints a line like this, so you can see it took effect:

```
agent-up: Google Drive: service account name@project-id.iam.gserviceaccount.com (shared key, read-only mount)
```

It says `project key` instead of `shared key` when the project has its own key.

Inside the container, the key is at `/run/secrets/google-drive-sa.json` (read-only), and the
environment variable `GOOGLEDRIVE_AUTH` holds that path.

## Check it works

Run this in R inside the container. Use a link to a file you shared with the service account:

```r
reproducible::prepInputs(
  url = "https://drive.google.com/file/d/<FILE_ID>/view?usp=sharing",
  destinationPath = tempdir(), fun = NA)
```

You should see `Google Drive: trying option service-account JSON from $GOOGLEDRIVE_AUTH`, then the
download. If you see `Public Google Drive file; downloading without authentication` instead, the
file is shared with "anyone with the link", so no key was needed.

## Per-project key or opt-out

- **A different key for one project:** put it at
  `~/.config/agent-containers/<project>/google-drive-sa.json` (`chmod 600`). It wins over the shared
  key. Then run `agent-up up <project>`.
- **No Drive key for one project:** add `GOOGLE_DRIVE=0` to
  `~/.config/agent-containers/<project>/project.conf`, then `agent-up up <project>`. Nothing is
  mounted, even if a key exists.
- The research container never gets the key.
- `GOOGLEDRIVE_AUTH`, `GARGLE_SERVICE_ACCOUNT` and `GOOGLE_DRIVE` are reserved names. `agent-up`
  refuses them in `project.env`.

## Rotate or revoke

1. In the Cloud console, open **IAM & Admin → Service accounts**, then the account, then **Keys**.
2. **Delete** the old key. It stops working at once.
3. To keep using Drive, make a new key (setup step 5), replace the file at the same path, keep
   `chmod 600`, and run `agent-up up <project>` (or `agent-up update --all`).
4. To stop for good, also delete the file from the host and remove the service account's access from
   your Drive folders (or delete the service account).

## What it does not protect

- Anyone who holds the key can read everything you shared with that account. Share only what the
  agent needs.
- The agent can read the key file inside its container, so treat the key as the agent's.
- The firewall allows Drive and googleapis hosts. Those accept uploads, so see "Upload-capable
  allowlisted domains" in `project-template/README.md` (Known residual risks). Viewer sharing and
  no roles keep the key read-only for your data.

## Optional: a private-file test in CI

CI can test a private file. It is off unless you add both items below.

1. Put a small file on your Drive. Share it **only** with the service account (Viewer). Copy its link.
2. In the GitHub repo, go to **Settings → Secrets and variables → Actions**.
3. On the **Secrets** tab, click **New repository secret**. Name: `GDRIVE_SA_KEY`. Value: the whole
   contents of the key JSON. Use a key you can delete later (a separate key is a good idea).
4. On the **Variables** tab, click **New repository variable**. Name: `GDRIVE_PRIVATE_TEST_URL`. Value:
   the file's link.

Without them, the acceptance test prints `Google Drive (service account): SKIPPED` and still passes.
