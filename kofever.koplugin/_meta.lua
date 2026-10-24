local _ = require("gettext")
-- Replaced with the release tag by .github/workflows/release.yml.
local version = "dev"
return {
    fullname = _("KOFever"),
    description = _([[Syncs unread articles from a FreshRSS server using the Fever or Google Reader API, for reading offline. Articles opened offline are marked read on the server at the next sync.]])
        .. "\n\n" .. _("Version:") .. " " .. version,
}
