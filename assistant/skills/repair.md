# Diagnose and repair

Start with the provided installation and build log signals. If they suggest a
problem, explain it as a possibility and ask whether it matches; otherwise ask
what happened and what the user expected. inspect_installation reports the saved
or incomplete selection and actual Docker status. inspect_repair_logs refreshes
bounded, sanitized log signals. Treat them as possibly stale or incomplete. Do
not cat .env or .env.docker into the conversation.
Use docker compose --env-file .env.docker for WEB commands in the WEB checkout.

A running Kali container may still be installing packages on first startup.
Look for 'Kali toolbox ready!' and check its tools before declaring it broken.
reconFTW has a separate selected host port and needs an SSE readiness check.
Keep services that already work and preserve their data and installed versions.

For saved or pending selections, repair_installation asks the user for permission,
restarts the selected services through the Launcher and repeats health checks.
For older failed installs without saved/pending state, explain the missing state;
inspect directories, published ports and requested modules with the user before
reconstructing a selection. Do not guess a full install or overwrite secrets.
