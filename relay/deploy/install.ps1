# ghoztty-agent installer - RETIRED (T1175). This is now a signpost, on
# purpose, and it must stay one.
#
# HOSTED COPY: this file is served by the relay VM as /dl/install.ps1 (Caddy
# `handle_path /dl/*` -> /var/www/ghoztty-dl), uploaded by
# relay/deploy/publish-agent.sh. Old docs, old chat logs and old runbooks
# still carry `irm https://<relay>/dl/install.ps1 | iex`, and a URL that
# 404s teaches nobody anything - so the one-liner keeps answering and says
# where the product went. Do not delete the file; do not let it install
# anything.
#
# WHY THERE IS NOTHING TO INSTALL ANY MORE. Windows used to ship two
# installers: Ghoztty's MSI and a standalone Remote Agent MSI served from
# here. `ghoztty-agent.exe` has been a required sibling of `ghoztty.exe` in
# the Ghoztty install since T89h, so the second installer added nothing to a
# box that had Ghoztty - while letting a new user install half a product,
# which fails with no window and no dialog. One installer is now the only
# supported Windows install path (see
# docs/design/one-installer-agent-consolidation.md).

$ErrorActionPreference = 'Stop'

$site = 'https://dzearing.github.io/ghoztty/#download'

Write-Host ''
Write-Host '  Ghoztty Remote Agent - nothing to install here.' -ForegroundColor Cyan
Write-Host ''
Write-Host '  The agent ships inside Ghoztty itself. Install Ghoztty on this'
Write-Host '  machine and it is already there:'
Write-Host ''
Write-Host "    $site" -ForegroundColor Green
Write-Host ''
Write-Host '  Then, in Ghoztty on this machine:'
Write-Host '    1. Press Ctrl+Shift+N to open the machine chooser.'
Write-Host '    2. Sign in with Google.'
Write-Host '    3. Turn on "Share this machine".'
Write-Host ''
Write-Host '  Your credential at %LOCALAPPDATA%\ghoztty\relay.env is kept and'
Write-Host '  reused, so a machine that was already enrolled stays enrolled.'
Write-Host ''

# Exit 0 deliberately: `irm ... | iex` in someone's terminal is a person
# asking a question, not a script gating on us. Printing the answer IS the
# success case.
