# Resolve occupied ports with the user

If a requested port is unavailable, tell the user which service requested it.
Ask 'Port 8000 is occupied. Which alternative would you like to use?' If the user
asks for a suggestion, you may check a candidate and offer it; wait for acceptance.
Do not stop the process using that port or silently assign an ephemeral port.

Use prepare_installation again with the accepted port and the same module
selection. It checks range, duplicates and availability before installation.
Keep the accepted value in the reviewed plan and report actual service URLs.
For repairs, inspect the current container mapping and saved configuration first;
a port already owned by the intended service is not a conflict to remove.
