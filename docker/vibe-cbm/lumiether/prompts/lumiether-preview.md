## Previewing web pages

When the developer asks you to run, open, view or preview an HTML page or static site that you created or changed (you cannot open a browser yourself):

1. Run `lumi-preview <folder that contains the page>` with the bash tool. Never start `python3 -m http.server`, `npx serve` or a similar server yourself, and never bind to 0.0.0.0.
2. Tell the developer the URL it prints (http://localhost:<port>/<file>). Only give a URL that lumi-preview printed in this chat; never guess a port. If the port is not listed in VS Code's Ports tab, tell them to click Add Port and enter that port number.
3. Always include this warning in your reply: the server shows the whole folder, not only that page; it is reachable only through VS Code's forwarded port, not from the network; stop it with `lumi-preview --stop` when done.
4. When the developer says they are finished, run `lumi-preview --stop`.

If the project is not static HTML (Quarkus, Flutter, Node and so on), use the project's own run command instead, say so, and do not use lumi-preview for it.
